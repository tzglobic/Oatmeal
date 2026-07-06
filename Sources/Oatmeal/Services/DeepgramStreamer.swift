import Foundation

/// Live-streaming WebSocket connection to Deepgram (nova-3, multichannel).
/// Channel 0 = mic ("me"), channel 1 = system audio ("them").
/// Handles keepalives, reconnects with backoff, and buffers audio while offline.
final class DeepgramStreamer: NSObject, URLSessionWebSocketDelegate {
    struct Segment {
        let channel: Int
        /// Diarized speaker index within the channel (majority vote over words).
        let speakerIndex: Int?
        let text: String
        let start: Double   // seconds since recording start
        let end: Double
        let isFinal: Bool
    }

    enum Status: Equatable {
        case connecting, connected, reconnecting, stopped
    }

    var onSegment: ((Segment) -> Void)?
    var onStatus: ((Status) -> Void)?

    private let apiKey: String
    private let recordingStart: Date
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var task: URLSessionWebSocketTask?
    private var keepAlive: DispatchSourceTimer?

    private let lock = NSLock()
    private var connected = false
    private var stopped = false
    private var pending: [Data] = []
    private var reconnectAttempt = 0
    /// Deepgram timestamps restart at 0 on every connection; this offset maps
    /// them back onto the recording's timeline.
    private var connectionOffset: Double = 0

    private let maxPendingChunks = 600 // ~60s of audio buffered while disconnected

    init(apiKey: String, recordingStart: Date) {
        self.apiKey = apiKey
        self.recordingStart = recordingStart
    }

    // MARK: - Lifecycle

    func connect() {
        lock.lock()
        let isStopped = stopped
        lock.unlock()
        guard !isStopped else { return }

        onStatus?(reconnectAttempt == 0 ? .connecting : .reconnecting)

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
            // Split multiple remote speakers within the system-audio channel.
            .init(name: "diarize", value: "true"),
            .init(name: "diarize_model", value: "latest"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveLoop(on: task)
    }

    func stop() {
        lock.lock()
        stopped = true
        let task = self.task
        lock.unlock()

        keepAlive?.cancel()
        keepAlive = nil

        // Ask Deepgram to flush and close gracefully; force-close shortly after.
        task?.send(.string(#"{"type":"CloseStream"}"#)) { _ in }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
            task?.cancel(with: .normalClosure, reason: nil)
            self?.session.finishTasksAndInvalidate()
        }
        onStatus?(.stopped)
    }

    // MARK: - Sending

    func send(_ data: Data) {
        lock.lock()
        if connected {
            lock.unlock()
            sendRaw(data)
        } else {
            pending.append(data)
            if pending.count > maxPendingChunks { pending.removeFirst() }
            lock.unlock()
        }
    }

    private func sendRaw(_ data: Data) {
        task?.send(.data(data)) { [weak self] error in
            if error != nil { self?.handleDisconnect() }
        }
    }

    // MARK: - Receiving

    private func receiveLoop(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.handleDisconnect()
            case .success(let message):
                if case .string(let text) = message { self.handleMessage(text) }
                self.receiveLoop(on: task)
            }
        }
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

        let segment = Segment(
            channel: channel,
            speakerIndex: speakerIndex,
            text: alternative.transcript.trimmingCharacters(in: .whitespaces),
            start: connectionOffset + start,
            end: connectionOffset + start + (response.duration ?? 0),
            isFinal: response.is_final ?? false)
        onSegment?(segment)
    }

    // MARK: - Connection state

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        lock.lock()
        connected = true
        reconnectAttempt = 0
        connectionOffset = Date().timeIntervalSince(recordingStart)
        let queued = pending
        pending.removeAll()
        lock.unlock()

        onStatus?(.connected)
        queued.forEach(sendRaw)
        startKeepAlive()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        handleDisconnect()
    }

    private func handleDisconnect() {
        lock.lock()
        guard task != nil else {
            lock.unlock()
            return
        }
        connected = false
        task?.cancel()
        task = nil
        let isStopped = stopped
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        lock.unlock()

        keepAlive?.cancel()
        keepAlive = nil
        guard !isStopped else { return }

        onStatus?(.reconnecting)
        let delay = min(10.0, pow(2.0, Double(attempt - 1))) // 1, 2, 4, 8, 10, 10…
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    /// Deepgram drops the connection after ~10s without audio; keepalives must
    /// be TEXT frames. Harmless while audio is flowing.
    private func startKeepAlive() {
        keepAlive?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            self?.task?.send(.string(#"{"type":"KeepAlive"}"#)) { _ in }
        }
        t.resume()
        keepAlive = t
    }
}
