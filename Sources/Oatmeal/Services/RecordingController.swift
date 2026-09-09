import Foundation
import SwiftUI
import AVFoundation
import CoreGraphics

/// Orchestrates a recording session: permissions → meeting row → audio capture
/// → Deepgram streaming → live transcript state → persistence.
@MainActor
final class RecordingController: ObservableObject {
    /// Single app-wide instance — the window, menu bar extra, and notification
    /// actions all drive the same recorder.
    static let shared = RecordingController()

    enum State { case idle, starting, recording, stopping }
    @Published private(set) var state: State = .idle {
        didSet {
            let waiters = stateWaiters
            stateWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
    var isRecording: Bool { state == .recording || state == .stopping }
    var isTransitioning: Bool { state == .starting || state == .stopping }
    private var stateWaiters: [CheckedContinuation<Void, Never>] = []
    private var shuttingDown = false
    private let store: Store
    private let dependencies: RecordingDependencies
    private let endDetector: MeetingEndDetector
    private let postProcess: ((Meeting) async -> Void)?
    private var processingTasks: [String: Task<Void, Never>] = [:]
    private var sessionID: UUID?
    private var transcriptInbox: TranscriptInbox?
    @Published var isPaused = false
    @Published var activeMeeting: Meeting?
    @Published var liveSegments: [TranscriptSegment] = []
    @Published var interim: [Int: String] = [:] // channel → in-progress text
    @Published var connectionStatus: String = ""
    @Published var lastError: String?
    @Published var warning: String?
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var recordingStart: Date?

    private var mic: MicrophoneCapturing?
    private var system: SystemCapturing?
    private var pipeline: RecordingPipeline?
    private var streamer: TranscriptStreaming?

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    init(store: Store = .shared, dependencies: RecordingDependencies? = nil,
         endDetector: MeetingEndDetector? = nil,
         postProcess: ((Meeting) async -> Void)? = nil) {
        self.store = store
        self.dependencies = dependencies ?? RecordingDependencies()
        self.endDetector = endDetector ?? .shared
        self.postProcess = postProcess
        // The detector only ever proposes; stopping is this controller's job,
        // so it goes through the same stop() as the button and the menu bar.
        self.endDetector.onStop = { [weak self] in
            Task { await self?.stop() }
        }
    }

    func toggle() {
        guard !isTransitioning, !shuttingDown else { return }
        if isRecording {
            Task { await stop() }
        } else {
            Task { await start() }
        }
    }

    /// Starts a recording. Pass a calendar event to pre-associate it; otherwise
    /// the event happening right now (if any) is attached automatically —
    /// title, event id, and attendees come from the calendar.
    func start(calendarMeeting: UpcomingMeeting? = nil) async {
        guard state == .idle, !shuttingDown else { return }
        state = .starting
        defer { if state == .starting { state = .idle } }
        lastError = nil
        warning = nil

        guard let apiKey = dependencies.apiKey(), !apiKey.isEmpty else {
            lastError = "Add your Deepgram API key in Settings (⌘,) before recording."
            return
        }
        // Mic permission denial must not abort the session — system-audio-only
        // recording is still valid (and the only mode on Macs without a mic).
        let micPermitted = await dependencies.microphonePermission()
        guard !shuttingDown else { return }
        let screenCapturePreflightGranted = dependencies.screenPermission()
        let event = calendarMeeting ?? dependencies.currentMeeting()
        var title = Meeting.defaultTitlePrefix + Self.titleFormatter.string(from: dependencies.now())
        if let eventTitle = event?.title.trimmingCharacters(in: .whitespaces), !eventTitle.isEmpty {
            title = eventTitle
        }
        var meeting = Meeting.new(title: title)
        if let event {
            meeting.calendarEventId = event.eventId
            if !event.attendees.isEmpty,
               let data = try? JSONEncoder().encode(event.attendees) {
                meeting.attendees = String(data: data, encoding: .utf8)
            }
        }
        let recordingURL: URL
        do {
            let dir = try dependencies.recordingsDirectory()
            recordingURL = dir.appendingPathComponent("\(meeting.id).m4a")
            meeting.audioFilePath = recordingURL.path
            try store.save(meeting)
        } catch {
            lastError = "Couldn't create the meeting: \(error.localizedDescription)"
            return
        }

        let recordingStart = dependencies.now()
        let pipeline = dependencies.makePipeline()
        let mic = dependencies.makeMic()
        let system = dependencies.makeSystem()
        let streamer = dependencies.makeStreamer(apiKey, recordingStart)
        let id = UUID()
        sessionID = id
        let inbox = TranscriptInbox()
        transcriptInbox = inbox

        mic.onSamples = { [weak pipeline] samples in pipeline?.appendMic(samples) }
        system.onSamples = { [weak pipeline] samples in pipeline?.appendSystem(samples) }
        system.onStop = { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard self?.sessionID == id else { return }
                self?.lastError = "System audio capture stopped: \(error.localizedDescription)"
            }
        }
        pipeline.onChunk = { [weak streamer] data in streamer?.send(data) }
        pipeline.onLevels = { [weak self] mic, system in
            Task { @MainActor in
                guard self?.sessionID == id else { return }
                self?.micLevel = mic
                self?.systemLevel = system
                self?.endDetector.noteLevels(mic: mic, system: system)
            }
        }
        streamer.onSegment = { [weak self] segment in
            inbox.append(segment)
            Task { @MainActor in
                guard self?.sessionID == id else { return }
                self?.drainTranscript()
            }
        }
        streamer.onStatus = { [weak self] status in
            Task { @MainActor in
                guard self?.sessionID == id else { return }
                self?.handleStatus(status)
            }
        }

        pipeline.onError = { [weak self] error in
            Task { @MainActor in
                guard let self, self.sessionID == id else { return }
                self.lastError = "Audio could not be saved: \(error.localizedDescription). Recording has been stopped."
                if self.state == .starting {
                    self.startupWriteFailed = true
                } else {
                    await self.stop()
                }
            }
        }
        startupWriteFailed = false
        do {
            try pipeline.start(recordingURL: recordingURL)
        } catch {
            sessionID = nil
            cleanupFailedMeeting(meeting, recordingURL: recordingURL)
            await streamer.finish()
            lastError = "Couldn't create the audio recording: \(error.localizedDescription)"
            return
        }

        // Prefer both system audio and mic, but allow either source to keep
        // recording useful while macOS TCC is being straightened out.
        var systemStarted = false
        var micStarted = false
        do {
            try await system.start()
            systemStarted = true
        } catch {
            await system.stop()
            warning = systemAudioStartMessage(error: error, preflightGranted: screenCapturePreflightGranted)
        }
        if micPermitted {
            do {
                try mic.start()
                micStarted = true
            } catch {
                mic.stop()
                if warning == nil {
                    warning = "Recording meeting audio only — no microphone is available, so your own voice won't be transcribed."
                }
            }
        } else if warning == nil {
            warning = "Recording meeting audio only — microphone access is denied (System Settings → Privacy & Security → Microphone)."
        }
        guard (systemStarted || micStarted), !shuttingDown, !startupWriteFailed else {
            mic.stop()
            await system.stop()
            pipeline.stop()
            sessionID = nil
            await streamer.finish()
            cleanupFailedMeeting(meeting, recordingURL: recordingURL)
            if !shuttingDown && !startupWriteFailed {
                lastError = "Couldn't start recording — no audio source was available. System audio: \(warning ?? "unavailable"). Microphone: \(micPermitted ? "unavailable" : "access denied")."
            }
            warning = nil
            return
        }

        self.pipeline = pipeline
        self.mic = micStarted ? mic : nil
        self.system = systemStarted ? system : nil
        self.streamer = streamer
        self.activeMeeting = meeting
        self.liveSegments = []
        self.interim = [:]
        self.recordingStart = recordingStart
        self.isPaused = false
        self.state = .recording
        streamer.connect()

        // The calendar end time is what makes the earlier of the two triggers
        // available; without an event, only prolonged silence can end this.
        endDetector.begin(eventEnd: event?.end)
    }

    func togglePause() {
        guard state == .recording else { return }
        isPaused.toggle()
        pipeline?.setPaused(isPaused)
        endDetector.setPaused(isPaused)
    }

    private func systemAudioStartMessage(error: Error, preflightGranted: Bool) -> String {
        if preflightGranted {
            return "Couldn't start recording: \(error.localizedDescription)"
        }
        return """
            Couldn't start system audio capture: \(error.localizedDescription)

            Oatmeal is enabled in System Settings, but macOS has not applied the grant to this running copy yet.

            1. Quit Oatmeal completely.
            2. Open System Settings → Privacy & Security → Screen & System Audio Recording.
            3. Remove Oatmeal from the list if there are duplicate entries, then add \(Bundle.main.bundlePath).
            4. Enable Oatmeal and reopen it.
            """
    }

    private var startupWriteFailed = false

    private func cleanupFailedMeeting(_ meeting: Meeting, recordingURL: URL) {
        do {
            try store.delete(meeting)
            if FileManager.default.fileExists(atPath: recordingURL.path) {
                try FileManager.default.removeItem(at: recordingURL)
            }
        } catch {
            lastError = "Couldn't clean up the failed recording: \(error.localizedDescription)"
        }
    }

    func stop() async {
        if state == .stopping {
            await waitForTransition()
            return
        }
        guard state == .recording else { return }
        state = .stopping
        endDetector.end()
        mic?.stop()
        await system?.stop()
        if let error = pipeline?.stop() {
            lastError = "Audio could not be saved: \(error.localizedDescription). The recording may be incomplete."
        }
        await streamer?.finish() // audio precedes CloseStream, trailing results precede completion

        drainTranscript() // UI tasks may not have delivered the final results yet
        transcriptInbox = nil
        mic = nil
        system = nil
        pipeline = nil
        streamer = nil
        sessionID = nil

        if let meeting = activeMeeting {
            do {
                activeMeeting = try store.finishMeeting(id: meeting.id, at: dependencies.now())
            } catch {
                lastError = "Couldn't save the meeting end time: \(error.localizedDescription)"
            }
        }
        interim = [:]
        connectionStatus = ""
        warning = nil
        micLevel = 0
        systemLevel = 0
        recordingStart = nil
        isPaused = false
        if let meeting = activeMeeting, !shuttingDown { process(meeting) }
        state = .idle
        NotificationCenter.default.post(name: .meetingChanged, object: nil)
    }

    private func waitForTransition() async {
        while isTransitioning {
            await withCheckedContinuation { stateWaiters.append($0) }
        }
    }

    private func process(_ meeting: Meeting) {
        guard processingTasks[meeting.id] == nil else { return }
        processingTasks[meeting.id] = Task {
            if let postProcess {
                await postProcess(meeting)
            } else {
                let notes = NotesModel.shared(for: meeting)
                await notes.enhance(auto: true)?.value
                if !Task.isCancelled, let error = notes.errorMessage {
                    lastError = "Notes for \(meeting.title): \(error)"
                }
            }
            processingTasks[meeting.id] = nil
        }
    }

    /// Pending jobs survive quitting or an unavailable API; retry once at launch.
    func resumePendingEnhancements() {
        guard !shuttingDown else { return }
        do {
            for meeting in try store.pendingEnhancements() { process(meeting) }
        } catch {
            lastError = "Couldn't load unfinished enhancements: \(error.localizedDescription)"
        }
    }

    /// Quit waits for local recording finalization, not a remote AI request.
    /// Unfinished enhancement jobs are persisted and resume on the next launch.
    @discardableResult
    func shutdown() async -> Bool {
        shuttingDown = true
        await waitForTransition()
        await stop()
        for task in processingTasks.values { task.cancel() }
        NotesModel.cancelEnhancements()
        guard NotesModel.flushAll() else {
            lastError = "Couldn't save all notes. Oatmeal stayed open so you can copy your edits or retry saving."
            shuttingDown = false
            return false
        }
        return true
    }

    // MARK: - Transcript handling

    private func drainTranscript() {
        for segment in transcriptInbox?.takeAll() ?? [] { handleSegment(segment) }
    }

    private func handleSegment(_ segment: DeepgramStreamer.Segment) {
        guard let meeting = activeMeeting, isRecording else { return }
        let speaker = speakerKey(channel: segment.channel, speakerIndex: segment.speakerIndex)

        if segment.isFinal {
            interim[segment.channel] = nil
            guard !segment.text.isEmpty else { return }
            var record = TranscriptSegment(
                id: nil, meetingId: meeting.id, speaker: speaker, text: segment.text,
                startTime: segment.start, endTime: segment.end, isFinal: true)
            do {
                try store.insert(&record)
            } catch {
                lastError = "Transcript could not be saved: \(error.localizedDescription). The audio recording can be re-transcribed."
            }
            liveSegments.append(record)
            // Channels finalize independently, so keep the merged view in time order.
            liveSegments.sort { $0.startTime < $1.startTime }
        } else if !segment.text.isEmpty {
            interim[segment.channel] = segment.text
        }
    }

    private func handleStatus(_ status: DeepgramStreamer.Status) {
        switch status {
        case .connecting: connectionStatus = "Connecting…"
        case .connected: connectionStatus = "Live"
        case .reconnecting: connectionStatus = "Reconnecting…"
        case .stopped: connectionStatus = ""
        }
    }
}

/// Deposit results before finish() resumes, independent of main-actor scheduling.
private final class TranscriptInbox {
    private let lock = NSLock()
    private var segments: [DeepgramStreamer.Segment] = []

    func append(_ segment: DeepgramStreamer.Segment) {
        lock.lock()
        segments.append(segment)
        lock.unlock()
    }

    func takeAll() -> [DeepgramStreamer.Segment] {
        lock.lock()
        defer { lock.unlock() }
        let result = segments
        segments.removeAll()
        return result
    }
}
