import Foundation
import AVFoundation

/// Interleaves mic (ch 0) and system audio (ch 1) into 100ms stereo Int16 chunks
/// for Deepgram's multichannel stream, and writes the same frames to an .m4a
/// fallback recording. Sources arrive on different threads at different cadences,
/// so each is ring-buffered and a timer drains both, padding shortfalls with
/// silence to keep the two channels aligned.
final class AudioPipeline {
    var onChunk: ((Data) -> Void)?
    /// Called ~10x/sec with (mic, system) levels in 0…1.
    var onLevels: ((Float, Float) -> Void)?

    private var micBuffer: [Int16] = []
    private var systemBuffer: [Int16] = []
    private var paused = false
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "oatmeal.pipeline")
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

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.drain() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        // Finalize the .m4a on the same queue drain() uses, so we never nil the
        // file out from under an in-flight write. AVAudioFile flushes on dealloc.
        queue.async { [self] in audioFile = nil }
    }

    /// While paused, both channels emit silence — the Deepgram timeline and the
    /// .m4a stay aligned with wall-clock time, so resume needs no offset math.
    func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        micBuffer.removeAll()
        systemBuffer.removeAll()
        lock.unlock()
    }

    private func drain() {
        lock.lock()
        var mic: [Int16]
        var system: [Int16]
        if paused {
            micBuffer.removeAll()
            systemBuffer.removeAll()
            mic = []
            system = []
        } else {
            mic = Array(micBuffer.prefix(chunkFrames))
            micBuffer.removeFirst(min(chunkFrames, micBuffer.count))
            system = Array(systemBuffer.prefix(chunkFrames))
            systemBuffer.removeFirst(min(chunkFrames, systemBuffer.count))
        }
        lock.unlock()

        onLevels?(Self.level(mic), Self.level(system))

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

    /// RMS of the chunk mapped to 0…1, scaled so normal speech reads mid-meter.
    private static func level(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for s in samples { sum += Double(s) * Double(s) }
        let rms = (sum / Double(samples.count)).squareRoot() / 32768.0
        return Float(min(1.0, rms * 6.0))
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
