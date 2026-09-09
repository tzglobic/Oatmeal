import Foundation
import AVFoundation
import CoreGraphics

protocol RecordingPipeline: AnyObject {
    var onChunk: ((Data) -> Void)? { get set }
    var onLevels: ((Float, Float) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    func appendMic(_ samples: [Int16])
    func appendSystem(_ samples: [Int16])
    func start(recordingURL: URL) throws
    @discardableResult func stop() -> Error?
    func setPaused(_ paused: Bool)
}

protocol MicrophoneCapturing: AnyObject {
    var onSamples: (([Int16]) -> Void)? { get set }
    func start() throws
    func stop()
}

protocol SystemCapturing: AnyObject {
    var onSamples: (([Int16]) -> Void)? { get set }
    var onStop: ((Error?) -> Void)? { get set }
    func start() async throws
    func stop() async
}

protocol TranscriptStreaming: AnyObject {
    var onSegment: ((DeepgramStreamer.Segment) -> Void)? { get set }
    var onStatus: ((DeepgramStreamer.Status) -> Void)? { get set }
    func connect()
    func send(_ data: Data)
    func finish() async
}

extension AudioPipeline: RecordingPipeline {}
extension MicCapture: MicrophoneCapturing {}
extension SystemAudioCapture: SystemCapturing {}
extension DeepgramStreamer: TranscriptStreaming {}

/// Hardware and permission boundaries can be replaced without touching personal data.
@MainActor
struct RecordingDependencies {
    var apiKey: () -> String? = { KeychainStore.get(.deepgram) }
    var microphonePermission: () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }
    var screenPermission: () -> Bool = {
        let granted = CGPreflightScreenCaptureAccess()
        if !granted { CGRequestScreenCaptureAccess() }
        return granted
    }
    var currentMeeting: () -> UpcomingMeeting? = { CalendarService.shared.currentMeeting() }
    var recordingsDirectory: () throws -> URL = Store.recordingsDirectory
    var makePipeline: () -> RecordingPipeline = { AudioPipeline() }
    var makeMic: () -> MicrophoneCapturing = { MicCapture() }
    var makeSystem: () -> SystemCapturing = { SystemAudioCapture() }
    var makeStreamer: (String, Date) -> TranscriptStreaming = { DeepgramStreamer(apiKey: $0, recordingStart: $1) }
    var now: () -> Date = Date.init
}
