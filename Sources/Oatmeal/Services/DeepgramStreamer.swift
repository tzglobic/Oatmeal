import Foundation

/// One connection. Callbacks may arrive on any thread, including after cancel().
protocol DeepgramConnection: AnyObject {
    var onOpen: (() -> Void)? { get set }
    var onMessage: ((String) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    func start()
    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping (Error?) -> Void)
    func cancel()
}

private final class WebSocketConnection: NSObject, DeepgramConnection, URLSessionWebSocketDelegate {
    var onOpen: (() -> Void)?
    var onMessage: ((String) -> Void)?
    var onClose: (() -> Void)?
    private let request: URLRequest
    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    init(request: URLRequest) { self.request = request }
    func start() {
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receive(on: task)
    }
    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping (Error?) -> Void) {
        guard let task else { completion(URLError(.cancelled)); return }
        task.send(message, completionHandler: completion)
    }
    func cancel() {
        task?.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message { self.onMessage?(text) }
                self.receive(on: task)
            case .failure: self.onClose?()
            }
        }
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) { onOpen?() }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { onClose?() }
}

/// All connection state and sends belong to one serial queue. Only one audio
/// send is in flight; new samples join the same FIFO as the reconnect backlog.
final class DeepgramStreamer: @unchecked Sendable {
    struct Segment {
        let channel: Int
        let speakerIndex: Int?
        let text: String
        let start: Double
        let end: Double
        let isFinal: Bool
    }
    enum Status: Equatable { case connecting, connected, reconnecting, stopped }
    // Callback access also belongs to the queue, so changing a handler cannot
    // race incoming results. Handlers execute on this queue and must not block it.
    private var segmentHandler: ((Segment) -> Void)?
    private var statusHandler: ((Status) -> Void)?
    var onSegment: ((Segment) -> Void)? {
        get { queue.sync { segmentHandler } }
        set { queue.sync { segmentHandler = newValue } }
    }
    var onStatus: ((Status) -> Void)? {
        get { queue.sync { statusHandler } }
        set { queue.sync { statusHandler = newValue } }
    }

    private struct Chunk {
        let data: Data
        let start: Double
    }
    private let apiKey: String
    private let makeConnection: (URLRequest) -> DeepgramConnection
    private let queue = DispatchQueue(label: "oatmeal.deepgram")
    private let reconnectDelay: (Int) -> TimeInterval
    private let finishTimeout: TimeInterval
    private var connection: DeepgramConnection?
    private var generation = UUID()
    private var connected = false
    private var finishing = false
    private var stopped = false
    private var sending = false
    private var closeSent = false
    private var pending: [Chunk] = []
    private var nextFrame: Int64 = 0
    private var connectionOffset: Double?
    private var reconnectAttempt = 0
    private var keepAlive: DispatchSourceTimer?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private let maxPendingChunks = 600

    init(apiKey: String, recordingStart: Date,
         makeConnection: @escaping (URLRequest) -> DeepgramConnection = { WebSocketConnection(request: $0) },
         reconnectDelay: @escaping (Int) -> TimeInterval = { min(10, pow(2, Double($0 - 1))) },
         finishTimeout: TimeInterval = 3) {
        self.apiKey = apiKey
        self.makeConnection = makeConnection
        self.reconnectDelay = reconnectDelay
        self.finishTimeout = finishTimeout
    }

    func connect() { queue.async { self.openConnection() } }

    private func openConnection() {
        guard !stopped, !finishing, connection == nil else { return }
        statusHandler?(reconnectAttempt == 0 ? .connecting : .reconnecting)
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        components.queryItems = [
            .init(name: "model", value: "nova-3"),
            .init(name: "encoding", value: "linear16"),
            .init(name: "sample_rate", value: "16000"),
            .init(name: "channels", value: "2"),
            .init(name: "multichannel", value: "true"),
            .init(name: "interim_results", value: "true"),
            .init(name: "smart_format", value: "true"),
            .init(name: "endpointing", value: "300"),
            .init(name: "diarize", value: "true"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        let socket = makeConnection(request)
        let id = UUID()
        generation = id
        connection = socket
        connectionOffset = nil
        socket.onOpen = { [weak self] in
            self?.queue.async { [weak self] in self?.opened(id: id) }
        }
        socket.onMessage = { [weak self] text in
            self?.queue.async { [weak self] in
                guard let self, self.generation == id, !self.stopped else { return }
                self.handleMessage(text)
            }
        }
        socket.onClose = { [weak self] in
            self?.queue.async { [weak self] in self?.disconnected(id: id) }
        }
        socket.start()
    }

    func send(_ data: Data) {
        queue.async {
            guard !self.finishing, !self.stopped else { return }
            let chunk = Chunk(data: data, start: Double(self.nextFrame) / 16_000)
            self.nextFrame += Int64(data.count / 4) // stereo Int16
            self.pending.append(chunk)
            if self.pending.count > self.maxPendingChunks {
                // A gap requires a new stream clock. Keep the newest minute;
                // the complete recording remains available for batch recovery.
                if self.connection != nil { self.disconnected(id: self.generation) }
                self.pending.removeFirst(self.pending.count - self.maxPendingChunks)
            }
            self.pump()
        }
    }

    private func opened(id: UUID) {
        guard id == generation, !stopped else { return }
        connected = true
        reconnectAttempt = 0
        statusHandler?(.connected)
        if !finishing { startKeepAlive(id: id) }
        pump()
    }

    private func pump() {
        guard connected, !sending, !stopped, let connection else { return }
        if pending.isEmpty {
            if finishing && !closeSent {
                closeSent = true
                let id = generation
                connection.send(.string(#"{"type":"CloseStream"}"#)) { [weak self] error in
                    if error != nil {
                        self?.queue.async { [weak self] in self?.disconnected(id: id) }
                    }
                }
            }
            return
        }
        sending = true
        let chunk = pending[0]
        if connectionOffset == nil { connectionOffset = chunk.start }
        let id = generation
        connection.send(.data(chunk.data)) { [weak self] error in
            self?.queue.async { [weak self] in
                guard let self, self.generation == id, !self.stopped else { return }
                self.sending = false
                if error != nil {
                    self.disconnected(id: id)
                } else {
                    self.pending.removeFirst()
                    self.pump()
                }
            }
        }
    }

    private func disconnected(id: UUID) {
        guard id == generation, connection != nil, !stopped else { return }
        generation = UUID() // invalidate every callback from the old socket
        connection?.cancel()
        connection = nil
        connected = false
        sending = false
        keepAlive?.cancel()
        keepAlive = nil
        if finishing { completeFinish(); return }
        reconnectAttempt += 1
        statusHandler?(.reconnecting)
        let ticket = generation
        queue.asyncAfter(deadline: .now() + reconnectDelay(reconnectAttempt)) { [weak self] in
            guard let self, self.generation == ticket else { return }
            self.openConnection()
        }
    }

    /// Stop accepting samples, flush queued audio, then wait for trailing results
    /// and the server close. The timeout also bounds shutdown while offline.
    func finish() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.stopped { continuation.resume(); return }
                self.finishWaiters.append(continuation)
                guard !self.finishing else { return }
                self.finishing = true
                self.keepAlive?.cancel()
                self.keepAlive = nil
                guard self.connection != nil else { self.completeFinish(); return }
                self.pump()
                self.queue.asyncAfter(deadline: .now() + self.finishTimeout) { [weak self] in
                    self?.completeFinish()
                }
            }
        }
    }

    private func completeFinish() {
        guard !stopped else { return }
        stopped = true
        generation = UUID()
        connection?.cancel()
        connection = nil
        pending.removeAll()
        statusHandler?(.stopped)
        let waiters = finishWaiters
        finishWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func startKeepAlive(id: UUID) {
        keepAlive?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, self.generation == id, !self.finishing, !self.sending,
                  self.pending.isEmpty else { return }
            self.connection?.send(.string(#"{"type":"KeepAlive"}"#)) { _ in }
        }
        timer.resume()
        keepAlive = timer
    }

    private struct DGResponse: Decodable {
        struct Channel: Decodable {
            struct Word: Decodable { let speaker: Int? }
            struct Alternative: Decodable {
                let transcript: String
                let words: [Word]?
            }
            let alternatives: [Alternative]
        }
        let type: String?
        let channel_index: [Int]?
        let start: Double?
        let duration: Double?
        let is_final: Bool?
        let channel: Channel?
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let response = try? JSONDecoder().decode(DGResponse.self, from: data),
              response.type == "Results",
              let alternative = response.channel?.alternatives.first,
              let channel = response.channel_index?.first,
              let start = response.start else { return }

        // Majority vote over word-level diarization for this result.
        let speakers = (alternative.words ?? []).compactMap(\.speaker)
        let speakerIndex = Dictionary(grouping: speakers, by: { $0 })
            .max { $0.value.count < $1.value.count }?.key

        let offset = connectionOffset ?? 0

        let segment = Segment(
            channel: channel,
            speakerIndex: speakerIndex,
            text: alternative.transcript.trimmingCharacters(in: .whitespaces),
            start: offset + start,
            end: offset + start + (response.duration ?? 0),
            isFinal: response.is_final ?? false)
        segmentHandler?(segment)
    }

}
