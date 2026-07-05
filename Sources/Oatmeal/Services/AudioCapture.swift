import Foundation
import AVFoundation
import ScreenCaptureKit

/// Converts arbitrary-format PCM buffers to 16kHz mono Int16 (what Deepgram expects).
/// One converter per stream — it keeps resampler state between buffers.
final class PCM16Converter {
    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        if converter == nil || inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.outputFormat)
            inputFormat = buffer.format
        }
        guard let converter else { return [] }

        let ratio = Self.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else {
            return []
        }

        // The input block must serve each buffer exactly once, then report .noDataNow.
        var served = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if served {
                inputStatus.pointee = .noDataNow
                return nil
            }
            served = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let channel = out.int16ChannelData else {
            return []
        }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }
}

/// Microphone capture via AVAudioEngine. The tap runs at the hardware format;
/// requesting 16kHz directly in installTap is not supported.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let converter = PCM16Converter()
    var onSamples: (([Int16]) -> Void)?

    func start() throws {
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.converter.convert(buffer)
            if !samples.isEmpty { self.onSamples?(samples) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// System audio capture via ScreenCaptureKit — audio only, no video is recorded.
/// SCK always runs a video pipeline, so we configure throwaway 2x2 @ 1fps video
/// and only attach an audio output.
final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "No display available for system audio capture." }
    }

    private var stream: SCStream?
    private let converter = PCM16Converter()
    private let queue = DispatchQueue(label: "oatmeal.system-audio")
    var onSamples: (([Int16]) -> Void)?
    var onStop: ((Error?) -> Void)?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16_000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: fmtDesc)
        try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            guard let pcm = AVAudioPCMBuffer(
                pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer) else { return }
            let samples = converter.convert(pcm)
            if !samples.isEmpty { onSamples?(samples) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}
