import XCTest
@testable import Oatmeal

private final class Locked<Value> {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func access<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private final class FakeConnection: DeepgramConnection {
    private struct State {
        var onOpen: (() -> Void)?
        var onMessage: ((String) -> Void)?
        var onClose: (() -> Void)?
        var completions: [(Error?) -> Void] = []
        var messages: [URLSessionWebSocketTask.Message] = []
        var cancels = 0
    }
    private let state = Locked(State())
    var onOpen: (() -> Void)? {
        get { state.access { $0.onOpen } }
        set { state.access { $0.onOpen = newValue } }
    }
    var onMessage: ((String) -> Void)? {
        get { state.access { $0.onMessage } }
        set { state.access { $0.onMessage = newValue } }
    }
    var onClose: (() -> Void)? {
        get { state.access { $0.onClose } }
        set { state.access { $0.onClose = newValue } }
    }
    var onStart: (() -> Void)?
    var didSend: ((URLSessionWebSocketTask.Message) -> Void)?
    var autoComplete = false
    var messages: [URLSessionWebSocketTask.Message] { state.access { $0.messages } }
    var cancels: Int { state.access { $0.cancels } }
    func start() { onStart?() }
    func cancel() { state.access { $0.cancels += 1 } }
    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping (Error?) -> Void) {
        state.access { state in
            state.messages.append(message)
            if !autoComplete { state.completions.append(completion) }
        }
        didSend?(message)
        if autoComplete { completion(nil) }
    }
    func completeNext(_ error: Error? = nil) {
        let completion = state.access { $0.completions.removeFirst() }
        completion(error)
    }
    func result(_ text: String, start: Double = 0) {
        onMessage?("""
        {"type":"Results","channel_index":[1,2],"start":\(start),"duration":0.1,"is_final":true,"channel":{"alternatives":[{"transcript":"\(text)","words":[{"speaker":0}]}]}}
        """)
    }
}

final class DeepgramStreamerTests: XCTestCase {
    private func chunk(_ byte: UInt8) -> Data { Data(repeating: byte, count: 6_400) }

    func testBacklogPrecedesNewAudioAndCloseStreamWaitsForLastSend() async {
        let socket = FakeConnection()
        let first = expectation(description: "first chunk")
        let second = expectation(description: "second chunk")
        let third = expectation(description: "new chunk")
        let closed = expectation(description: "CloseStream")
        let final = expectation(description: "final result")
        socket.onStart = { socket.onOpen?() }
        socket.didSend = { message in
            switch message {
            case .data(let data):
                switch data.first {
                case 1: first.fulfill()
                case 2: second.fulfill()
                case 3: third.fulfill()
                default: XCTFail("unexpected audio")
                }
            case .string(let text):
                XCTAssertTrue(text.contains("CloseStream"))
                socket.result("trailing words")
                socket.onClose?()
                closed.fulfill()
            @unknown default: XCTFail("unknown message")
            }
        }
        let streamer = DeepgramStreamer(apiKey: "test", recordingStart: Date(), makeConnection: { _ in socket })
        streamer.onSegment = { segment in
            XCTAssertEqual(segment.text, "trailing words")
            final.fulfill()
        }
        streamer.send(chunk(1))
        streamer.send(chunk(2))
        streamer.connect()
        await fulfillment(of: [first], timeout: 2)
        streamer.send(chunk(3))
        XCTAssertEqual(socket.messages.count, 1)
        socket.completeNext()
        await fulfillment(of: [second], timeout: 2)
        socket.completeNext()
        await fulfillment(of: [third], timeout: 2)
        let finish = Task { await streamer.finish() }
        // No CloseStream can overtake the third audio send.
        XCTAssertEqual(socket.messages.count, 3)
        socket.completeNext()
        await finish.value
        await fulfillment(of: [closed, final], timeout: 2)
        streamer.send(chunk(4))
        await streamer.finish() // idempotent queue barrier
        XCTAssertEqual(socket.messages.count, 4)
    }

    func testOldConnectionCallbacksCannotDisconnectOrContaminateReplacement() async {
        let old = FakeConnection(), replacement = FakeConnection()
        let started = expectation(description: "old opened")
        let reconnected = expectation(description: "replacement opened")
        let oldSent = expectation(description: "old audio send")
        let resent = expectation(description: "audio resent")
        let result = expectation(description: "new connection result")
        let factoryCalls = Locked(0)
        old.onStart = { old.onOpen?(); started.fulfill() }
        old.didSend = { _ in oldSent.fulfill() }
        replacement.autoComplete = true
        replacement.onStart = { replacement.onOpen?(); reconnected.fulfill() }
        replacement.didSend = { message in
            if case .data = message { resent.fulfill() }
            if case .string(let text) = message, text.contains("CloseStream") { replacement.onClose?() }
        }
        let streamer = DeepgramStreamer(apiKey: "test", recordingStart: Date(), makeConnection: { _ in
            factoryCalls.access { count in count += 1; return count == 1 ? old : replacement }
        }, reconnectDelay: { _ in 0 })
        streamer.onSegment = { segment in
            XCTAssertEqual(segment.text, "valid")
            result.fulfill()
        }
        streamer.connect()
        await fulfillment(of: [started], timeout: 2)
        streamer.send(chunk(1))
        await fulfillment(of: [oldSent], timeout: 2)
        old.completeNext(TestFailure.unavailable)
        await fulfillment(of: [reconnected, resent], timeout: 2)
        old.onOpen?()
        old.onClose?()
        old.result("stale")
        replacement.result("valid")
        await fulfillment(of: [result], timeout: 2)
        await streamer.finish()
        XCTAssertEqual(factoryCalls.access { $0 }, 2)
        XCTAssertEqual(replacement.cancels, 1) // only normal finish cancelled it
    }

    func testOfflineBufferOffsetUsesAudioFramesRatherThanConnectionWallClock() async {
        let socket = FakeConnection()
        socket.autoComplete = true
        socket.onStart = { socket.onOpen?() }
        let audioSent = expectation(description: "first retained audio")
        let result = expectation(description: "offset result")
        let firstSent = Locked(false)
        socket.didSend = { message in
            if case .data = message {
                let isFirst = firstSent.access { sent in defer { sent = true }; return !sent }
                if isFirst {
                    socket.result("buffered", start: 1)
                    audioSent.fulfill()
                }
            }
            if case .string(let text) = message, text.contains("CloseStream") { socket.onClose?() }
        }
        let streamer = DeepgramStreamer(apiKey: "test", recordingStart: Date().addingTimeInterval(-999),
                                        makeConnection: { _ in socket })
        streamer.onSegment = { segment in
            XCTAssertEqual(segment.start, 1.5, accuracy: 0.0001) // oldest five 100ms chunks were dropped
            result.fulfill()
        }
        for _ in 0..<605 { streamer.send(chunk(1)) }
        streamer.connect()
        await fulfillment(of: [audioSent, result], timeout: 2)
        await streamer.finish()
    }

    func testFinishBeforeOpenAndLateCallbacksAreHarmless() async {
        let socket = FakeConnection()
        let started = expectation(description: "connection started but not open")
        socket.onStart = { started.fulfill() }
        let streamer = DeepgramStreamer(apiKey: "test", recordingStart: Date(),
                                        makeConnection: { _ in socket }, finishTimeout: 0.02)
        streamer.onSegment = { _ in XCTFail("late result after finish") }
        streamer.connect()
        await fulfillment(of: [started], timeout: 2)
        await streamer.finish()
        socket.onOpen?()
        socket.result("late")
        socket.onClose?()
        await streamer.finish()
        XCTAssertTrue(socket.messages.isEmpty)
        XCTAssertEqual(socket.cancels, 1)
    }
}
