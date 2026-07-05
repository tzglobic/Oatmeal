import Foundation
import AVFoundation

/// Interleaves mic (ch 0) and system audio (ch 1) into 100ms stereo Int16 chunks
/// for Deepgram's multichannel stream, and writes the same frames to an .m4a
/// fallback recording. Sources arrive on different threads at different cadences,
/// so each is ring-buffered and a timer drains both, padding shortfalls with
/// silence to keep the two channels aligned.
final class AudioPipeline {
    var onChunk: ((Data) -> Void)?

    private var micBuffer: [Int16] = []
    private var systemBuffer: [Int16] = []
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var audioFile: AVAudioFile?

    private let chunkFrames = 1_600            // 100ms @ 16kHz
    private let maxBufferedFrames = 160_000    // cap each ring buffer at 10s

    private static let fileFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 2, interleaved: true)!

    func appendMic(_ samples: [Int16]) {
        append(samples, to: &micBuffer)
    }

    func appendSystem(_ samples: [Int16]) {
        append(samples, to: &systemBuffer)
    }

    private func append(_ samples: [Int16], to buffer: inout [Int16]) {
        lock.lock()
        buffer.append(contentsOf: samples)
        if buffer.count > maxBufferedFrames {
            buffer.removeFirst(buffer.count - maxBufferedFrames)
        }
        lock.unlock()
    }

    func start(recordingURL: URL) throws {
        audioFile = try AVAudioFile(
            forWriting: recordingURL,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 96_000,
            ],
            commonFormat: .pcmFormatInt16,
            interleaved: true)

        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "oatmeal.pipeline"))
        t.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.drain() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        audioFile = nil // AVAudioFile finalizes on dealloc
    }

    private func drain() {
        lock.lock()
        var mic = Array(micBuffer.prefix(chunkFrames))
        micBuffer.removeFirst(min(chunkFrames, micBuffer.count))
        var system = Array(systemBuffer.prefix(chunkFrames))
        systemBuffer.removeFirst(min(chunkFrames, systemBuffer.count))
        lock.unlock()

        if mic.count < chunkFrames {
            mic.append(contentsOf: repeatElement(0, count: chunkFrames - mic.count))
        }
        if system.count < chunkFrames {
            system.append(contentsOf: repeatElement(0, count: chunkFrames - system.count))
        }

        var interleaved = [Int16](repeating: 0, count: chunkFrames * 2)
        for i in 0..<chunkFrames {
            interleaved[2 * i] = mic[i]
            interleaved[2 * i + 1] = system[i]
        }

        let data = interleaved.withUnsafeBufferPointer { Data(buffer: $0) }
        onChunk?(data)
        writeToFile(interleaved)
    }

    private func writeToFile(_ interleaved: [Int16]) {
        let frames = AVAudioFrameCount(interleaved.count / 2)
        guard let file = audioFile,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.fileFormat, frameCapacity: frames),
              let channelData = buffer.int16ChannelData else { return }
        buffer.frameLength = frames
        interleaved.withUnsafeBufferPointer { src in
            channelData[0].update(from: src.baseAddress!, count: interleaved.count)
        }
        try? file.write(from: buffer)
    }
}
