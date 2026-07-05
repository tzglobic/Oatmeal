import Foundation
import SwiftUI
import AVFoundation
import CoreGraphics

/// Orchestrates a recording session: permissions → meeting row → audio capture
/// → Deepgram streaming → live transcript state → persistence.
@MainActor
final class RecordingController: ObservableObject {
    @Published var isRecording = false
    @Published var activeMeeting: Meeting?
    @Published var liveSegments: [TranscriptSegment] = []
    @Published var interim: [Int: String] = [:] // channel → in-progress text
    @Published var connectionStatus: String = ""
    @Published var lastError: String?

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

    func start() async {
        lastError = nil

        guard let apiKey = KeychainStore.get(.deepgram), !apiKey.isEmpty else {
            lastError = "Add your Deepgram API key in Settings (⌘,) before recording."
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            lastError = "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone."
            return
        }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            lastError = """
                Screen Recording permission is needed to capture meeting audio — Oatmeal never records your screen.

                1. Open System Settings → Privacy & Security → Screen & System Audio Recording and enable Oatmeal.
                2. Quit and reopen Oatmeal — macOS only applies the grant on relaunch.

                If Oatmeal already appears enabled there but you still see this, the app was rebuilt and macOS lost the grant: toggle Oatmeal off and on again, then relaunch.
                """
            return
        }

        var meeting = Meeting.new(title: "Meeting \(Self.titleFormatter.string(from: Date()))")
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
        streamer.onSegment = { [weak self] segment in
            Task { @MainActor in self?.handleSegment(segment) }
        }
        streamer.onStatus = { [weak self] status in
            Task { @MainActor in self?.handleStatus(status) }
        }

        do {
            try pipeline.start(recordingURL: recordingURL)
            try mic.start()
            try await system.start()
        } catch {
            pipeline.stop()
            mic.stop()
            await system.stop()
            try? Store.shared.delete(meeting)
            lastError = "Couldn't start recording: \(error.localizedDescription)"
            return
        }
        streamer.connect()

        self.pipeline = pipeline
        self.mic = mic
        self.system = system
        self.streamer = streamer
        self.activeMeeting = meeting
        self.liveSegments = []
        self.interim = [:]
        self.isRecording = true
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
        isRecording = false
    }

    // MARK: - Transcript handling

    private func handleSegment(_ segment: DeepgramStreamer.Segment) {
        guard let meeting = activeMeeting, isRecording else { return }
        let speaker = segment.channel == 0 ? "me" : "them"

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
