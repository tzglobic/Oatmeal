import Foundation
import AVFoundation

/// Phase 1 will implement:
///  - System audio capture via ScreenCaptureKit (SCStream, audio-only, no video)
///  - Mic capture via AVAudioEngine input tap
///  - Conversion of both channels to 16kHz linear PCM for Deepgram streaming
///  - Raw .m4a recording per meeting as a re-transcription fallback
final class AudioService: ObservableObject {
    @Published var isRecording = false

    func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
