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

    @Published var isRecording = false
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

    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var pipeline: AudioPipeline?
    private var streamer: DeepgramStreamer?

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    func toggle() {
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
        lastError = nil
        warning = nil

        guard let apiKey = KeychainStore.get(.deepgram), !apiKey.isEmpty else {
            lastError = "Add your Deepgram API key in Settings (⌘,) before recording."
            return
        }
        // Mic permission denial must not abort the session — system-audio-only
        // recording is still valid (and the only mode on Macs without a mic).
        let micPermitted = await AVCaptureDevice.requestAccess(for: .audio)
        let screenCapturePreflightGranted = CGPreflightScreenCaptureAccess()
        if !screenCapturePreflightGranted {
            // This registers Oatmeal in System Settings. Do not return here:
            // macOS can allow System Audio Recording Only while the older screen
            // capture preflight still reports false. The source of truth is
            // whether ScreenCaptureKit can actually start the audio stream below.
            CGRequestScreenCaptureAccess()
        }

        let event = calendarMeeting ?? CalendarService.shared.currentMeeting()
        var title = Meeting.defaultTitlePrefix + Self.titleFormatter.string(from: Date())
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
            let dir = try Store.recordingsDirectory()
            recordingURL = dir.appendingPathComponent("\(meeting.id).m4a")
            meeting.audioFilePath = recordingURL.path
            try Store.shared.save(meeting)
        } catch {
            lastError = "Couldn't create the meeting: \(error.localizedDescription)"
            return
        }

        let recordingStart = Date()
        let pipeline = AudioPipeline()
        let mic = MicCapture()
        let system = SystemAudioCapture()
        let streamer = DeepgramStreamer(apiKey: apiKey, recordingStart: recordingStart)

        mic.onSamples = { [weak pipeline] samples in pipeline?.appendMic(samples) }
        system.onSamples = { [weak pipeline] samples in pipeline?.appendSystem(samples) }
        system.onStop = { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.lastError = "System audio capture stopped: \(error.localizedDescription)"
            }
        }
        pipeline.onChunk = { [weak streamer] data in streamer?.send(data) }
        pipeline.onLevels = { [weak self] mic, system in
            Task { @MainActor in
                self?.micLevel = mic
                self?.systemLevel = system
            }
        }
        streamer.onSegment = { [weak self] segment in
            Task { @MainActor in self?.handleSegment(segment) }
        }
        streamer.onStatus = { [weak self] status in
            Task { @MainActor in self?.handleStatus(status) }
        }

        // Prefer both system audio and mic, but allow either source to keep
        // recording useful while macOS TCC is being straightened out.
        var systemStarted = false
        var micStarted = false
        do {
            try pipeline.start(recordingURL: recordingURL)
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
                if warning == nil {
                    warning = "Recording meeting audio only — no microphone is available, so your own voice won't be transcribed."
                }
            }
        } else if warning == nil {
            warning = "Recording meeting audio only — microphone access is denied (System Settings → Privacy & Security → Microphone)."
        }
        guard systemStarted || micStarted else {
            pipeline.stop()
            try? Store.shared.delete(meeting)
            lastError = """
                Couldn't start recording — no audio source was available.

                System audio: \(warning ?? "unavailable")
                Microphone: \(micPermitted ? "no usable microphone was found." : "access denied.")
                """
            warning = nil
            return
        }
        streamer.connect()

        self.pipeline = pipeline
        self.mic = micStarted ? mic : nil
        self.system = systemStarted ? system : nil
        self.streamer = streamer
        self.activeMeeting = meeting
        self.liveSegments = []
        self.interim = [:]
        self.recordingStart = recordingStart
        self.isPaused = false
        self.isRecording = true
    }

    func togglePause() {
        guard isRecording else { return }
        isPaused.toggle()
        pipeline?.setPaused(isPaused)
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

    func stop() async {
        streamer?.stop()
        mic?.stop()
        await system?.stop()

        // Give Deepgram a moment to flush trailing final results.
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        pipeline?.stop()
        mic = nil
        system = nil
        pipeline = nil
        streamer = nil

        if var meeting = activeMeeting {
            meeting.endedAt = Date()
            try? Store.shared.save(meeting)
            activeMeeting = meeting
        }
        interim = [:]
        connectionStatus = ""
        warning = nil
        micLevel = 0
        systemLevel = 0
        recordingStart = nil
        isPaused = false
        isRecording = false
    }

    // MARK: - Transcript handling

    private func handleSegment(_ segment: DeepgramStreamer.Segment) {
        guard let meeting = activeMeeting, isRecording else { return }
        let speaker = speakerKey(channel: segment.channel, speakerIndex: segment.speakerIndex)

        if segment.isFinal {
            interim[segment.channel] = nil
            guard !segment.text.isEmpty else { return }
            var record = TranscriptSegment(
                id: nil, meetingId: meeting.id, speaker: speaker, text: segment.text,
                startTime: segment.start, endTime: segment.end, isFinal: true)
            try? Store.shared.insert(&record)
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
