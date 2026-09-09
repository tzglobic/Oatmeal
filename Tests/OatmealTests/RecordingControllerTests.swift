import XCTest
import GRDB
@testable import Oatmeal

actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

enum TestFailure: Error { case diskFull, unavailable }

final class FakePipeline: RecordingPipeline {
    var onChunk: ((Data) -> Void)?
    var onLevels: ((Float, Float) -> Void)?
    var onError: ((Error) -> Void)?
    var startError: Error?
    var stopError: Error?
    var starts = 0
    var stops = 0
    var didStop: (() -> Void)?
    func appendMic(_ samples: [Int16]) {}
    func appendSystem(_ samples: [Int16]) {}
    func start(recordingURL: URL) throws {
        starts += 1
        if let startError { throw startError }
    }
    @discardableResult func stop() -> Error? {
        stops += 1
        didStop?()
        return stopError
    }
    func setPaused(_ paused: Bool) {}
}

final class FakeMic: MicrophoneCapturing {
    var onSamples: (([Int16]) -> Void)?
    var error: Error?
    var starts = 0
    var stops = 0
    func start() throws { starts += 1; if let error { throw error } }
    func stop() { stops += 1 }
}

final class FakeSystem: SystemCapturing {
    var onSamples: (([Int16]) -> Void)?
    var onStop: ((Error?) -> Void)?
    var error: Error?
    var starts = 0
    var stops = 0
    var startAction: () async -> Void = {}
    func start() async throws {
        starts += 1
        await startAction()
        if let error { throw error }
    }
    func stop() async { stops += 1 }
}

final class FakeStreamer: TranscriptStreaming {
    var onSegment: ((DeepgramStreamer.Segment) -> Void)?
    var onStatus: ((DeepgramStreamer.Status) -> Void)?
    var connections = 0
    var finishes = 0
    var finishAction: () async -> Void = {}
    var didSend: ((Data) -> Void)?
    func connect() { connections += 1 }
    func send(_ data: Data) { didSend?(data) }
    func finish() async { finishes += 1; await finishAction() }
}

@MainActor
final class RecordingFixture {
    let store: Store
    let pipeline = FakePipeline()
    let mic = FakeMic()
    let system = FakeSystem()
    let streamer = FakeStreamer()
    let directory: URL
    var dependencies: RecordingDependencies

    init() throws {
        store = try Store(dbQueue: DatabaseQueue())
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dependencies = RecordingDependencies()
        dependencies.apiKey = { "test-key-never-sent" }
        dependencies.microphonePermission = { true }
        dependencies.screenPermission = { true }
        dependencies.currentMeeting = { nil }
        let directory = directory
        dependencies.recordingsDirectory = { directory }
        let pipeline = pipeline, mic = mic, system = system, streamer = streamer
        dependencies.makePipeline = { pipeline }
        dependencies.makeMic = { mic }
        dependencies.makeSystem = { system }
        dependencies.makeStreamer = { _, _ in streamer }
    }

    func controller(postProcess: @escaping (Meeting) async -> Void = { _ in }) -> RecordingController {
        RecordingController(store: store, dependencies: dependencies,
                            endDetector: MeetingEndDetector(enabled: { false }, usesTimers: false,
                                                           notify: { _, _ in }, withdraw: {}),
                            postProcess: postProcess)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

final class RecordingControllerTests: XCTestCase {
    @MainActor func testDoubleStartWhilePermissionPendingCreatesOneMeeting() async throws {
        let f = try RecordingFixture()
        defer { f.cleanup() }
        let gate = Gate()
        let entered = expectation(description: "permission requested")
        f.dependencies.microphonePermission = { entered.fulfill(); await gate.wait(); return true }
        let recorder = f.controller()
        let first = Task { await recorder.start() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(recorder.state, .starting)
        await recorder.start()
        XCTAssertEqual(f.pipeline.starts, 0)
        await gate.release()
        await first.value
        XCTAssertEqual(try f.store.allMeetings().count, 1)
        XCTAssertEqual(f.mic.starts, 1)
        await recorder.start()
        XCTAssertEqual(f.mic.starts, 1)
        await recorder.stop()
    }

    @MainActor func testPipelineFailureAbortsBeforeStartingAudioSources() async throws {
        let f = try RecordingFixture()
        defer { f.cleanup() }
        f.pipeline.startError = TestFailure.diskFull
        let recorder = f.controller()
        await recorder.start()
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(f.mic.starts, 0)
        XCTAssertEqual(f.system.starts, 0)
        XCTAssertEqual(f.streamer.connections, 0)
        XCTAssertTrue(try f.store.allMeetings().isEmpty)
        XCTAssertTrue(recorder.lastError?.contains("Couldn't create the audio") == true)
    }

    @MainActor func testNoSourcesRollsBackAndClosesPipeline() async throws {
        let f = try RecordingFixture()
        defer { f.cleanup() }
        f.mic.error = TestFailure.unavailable
        f.system.error = TestFailure.unavailable
        let recorder = f.controller()
        await recorder.start()
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(f.pipeline.stops, 1)
        XCTAssertEqual(f.streamer.connections, 0)
        XCTAssertTrue(try f.store.allMeetings().isEmpty)
    }

    @MainActor func testStopPreservesEditsDrainsFinalWordsAndEnhancesWithoutAView() async throws {
        let f = try RecordingFixture()
        defer { f.cleanup() }
        let processed = expectation(description: "headless post-processing")
        let recorder = f.controller { meeting in
            XCTAssertEqual(meeting.title, "Manual title")
            XCTAssertEqual(meeting.template, "standup")
            XCTAssertEqual(try? f.store.segments(for: meeting.id).last?.text, "last words")
            processed.fulfill()
        }
        await recorder.start()
        let id = try XCTUnwrap(recorder.activeMeeting?.id)
        try f.store.updateTitle(meetingId: id, title: "Manual title")
        try f.store.updateTemplate(meetingId: id, template: "standup")
        try f.store.updateSpeakerName(meetingId: id, key: "them0", name: "Alice")
        var sentTail = false
        f.pipeline.didStop = { f.pipeline.onChunk?(Data([1, 2, 3, 4])) }
        f.streamer.didSend = { _ in sentTail = true }
        f.streamer.finishAction = {
            XCTAssertTrue(sentTail)
            f.streamer.onSegment?(.init(channel: 1, speakerIndex: 0, text: "last words",
                                       start: 1, end: 2, isFinal: true))
        }
        await recorder.stop()
        await fulfillment(of: [processed], timeout: 2)
        let saved = try XCTUnwrap(f.store.meeting(id: id))
        XCTAssertNotNil(saved.endedAt)
        XCTAssertEqual(saved.title, "Manual title")
        XCTAssertEqual(saved.template, "standup")
        XCTAssertEqual(saved.speakerNameMap["them0"], "Alice")
        XCTAssertEqual(try f.store.segments(for: id).count, 1)
        XCTAssertEqual(recorder.state, .idle)
        await recorder.stop()
        XCTAssertEqual(f.streamer.finishes, 1)
    }

    @MainActor func testQuitWaitsForCaptureAndLeavesEnhancementPendingForNextLaunch() async throws {
        let f = try RecordingFixture()
        defer { f.cleanup() }
        let finishGate = Gate()
        let finishing = expectation(description: "finishing audio")
        f.streamer.finishAction = { finishing.fulfill(); await finishGate.wait() }
        let recorder = f.controller { _ in XCTFail("Quit must not wait for a remote AI request") }
        await recorder.start()
        let stopTask = Task { await recorder.stop() }
        await fulfillment(of: [finishing], timeout: 2)
        var quitCompleted = false
        let quitTask = Task { await recorder.shutdown(); quitCompleted = true }
        await Task.yield()
        await recorder.start()
        XCTAssertEqual(f.pipeline.starts, 1)
        XCTAssertFalse(quitCompleted)
        await finishGate.release()
        await stopTask.value
        await quitTask.value
        XCTAssertTrue(quitCompleted)
        XCTAssertEqual(f.streamer.finishes, 1)
        XCTAssertEqual(try f.store.pendingEnhancements().count, 1)
        await recorder.start()
        XCTAssertEqual(f.pipeline.starts, 1)

        let resumed = expectation(description: "pending job resumed without a view")
        let nextLaunch = f.controller { meeting in
            try? f.store.completeEnhancement(meetingId: meeting.id)
            resumed.fulfill()
        }
        nextLaunch.resumePendingEnhancements()
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertTrue(try f.store.pendingEnhancements().isEmpty)
    }

    @MainActor func testQuitDuringPermissionPromptDoesNotStartCapture() async throws {
        let f = try RecordingFixture()
        defer { f.cleanup() }
        let gate = Gate()
        let entered = expectation(description: "permission")
        f.dependencies.microphonePermission = { entered.fulfill(); await gate.wait(); return true }
        let recorder = f.controller()
        let startTask = Task { await recorder.start() }
        await fulfillment(of: [entered], timeout: 2)
        let quitting = Task { await recorder.shutdown() }
        await Task.yield()
        await gate.release()
        await startTask.value
        _ = await quitting.value
        XCTAssertEqual(f.pipeline.starts, 0)
        XCTAssertTrue(try f.store.allMeetings().isEmpty)
    }

    @MainActor func testAudioAndTranscriptWriteFailuresAreVisible() async throws {
        let f = try RecordingFixture()
        defer { f.cleanup() }
        let recorder = f.controller()
        await recorder.start()
        try await f.store.dbQueue.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_segment BEFORE INSERT ON transcript_segments BEGIN SELECT RAISE(FAIL, 'disk full'); END")
        }
        f.streamer.finishAction = {
            f.streamer.onSegment?(.init(channel: 0, speakerIndex: nil, text: "retained in memory",
                                       start: 0, end: 1, isFinal: true))
        }
        await recorder.stop()
        XCTAssertTrue(recorder.lastError?.contains("Transcript could not be saved") == true)
        XCTAssertEqual(recorder.liveSegments.last?.text, "retained in memory")

        f.pipeline.stopError = TestFailure.diskFull
        f.streamer.finishAction = {}
        await recorder.start()
        await recorder.stop()
        XCTAssertTrue(recorder.lastError?.contains("Audio could not be saved") == true)
    }
    @MainActor func testFailedMeetingFinalizationPreventsQuitAndCanBeRetried() async throws {
        let f = try RecordingFixture()
        defer { f.cleanup() }
        let recorder = f.controller()
        await recorder.start()
        try await f.store.dbQueue.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_finish BEFORE UPDATE OF endedAt ON meetings BEGIN SELECT RAISE(FAIL, 'disk full'); END")
        }
        await recorder.stop()
        XCTAssertTrue(recorder.lastError?.contains("Couldn't save the meeting end time") == true)
        let firstQuit = await recorder.shutdown()
        XCTAssertFalse(firstQuit)
        try await f.store.dbQueue.write { db in try db.execute(sql: "DROP TRIGGER fail_finish") }
        let secondQuit = await recorder.shutdown()
        XCTAssertTrue(secondQuit)
        XCTAssertNotNil(try f.store.allMeetings().first?.endedAt)
        XCTAssertEqual(try f.store.pendingEnhancements().count, 1)
    }

    @MainActor func testFailedNoteSavePreventsQuitAndSurvivesClosingTheEditor() async throws {
        let f = try RecordingFixture()
        defer { f.cleanup() }
        let meeting = Meeting.new(title: "Manual meeting")
        try f.store.save(meeting)
        try await f.store.dbQueue.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_note BEFORE INSERT ON notes BEGIN SELECT RAISE(FAIL, 'disk full'); END")
        }
        weak var retained: NotesModel?
        do {
            let notes = NotesModel.shared(for: meeting, store: f.store)
            notes.userNotes = "Keep these unsaved edits"
            notes.flush()
            retained = notes
        }
        XCTAssertNotNil(retained)
        let recorder = f.controller()
        let firstQuit = await recorder.shutdown()
        XCTAssertFalse(firstQuit)
        try await f.store.dbQueue.write { db in try db.execute(sql: "DROP TRIGGER fail_note") }
        let secondQuit = await recorder.shutdown()
        XCTAssertTrue(secondQuit)
        XCTAssertEqual(try f.store.note(for: meeting.id, kind: "user")?.content, "Keep these unsaved edits")
    }

}
