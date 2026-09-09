import XCTest
import AVFoundation
@testable import Oatmeal

final class AudioPipelineTests: XCTestCase {
    func testStopDrainsBothChannelsAndFinalizesReadableAudio() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let pipeline = AudioPipeline(usesTimer: false)
        var chunks: [Data] = []
        pipeline.onChunk = { chunks.append($0) }
        try pipeline.start(recordingURL: url)
        pipeline.appendMic([Int16](repeating: 1_000, count: 3_200))
        pipeline.appendSystem([Int16](repeating: 2_000, count: 3_200))
        XCTAssertNil(pipeline.stop())
        XCTAssertEqual(chunks.count, 2)
        let samples = chunks[0].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(Array(samples.prefix(4)), [1_000, 2_000, 1_000, 2_000])
        let audio = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(audio.length, 0)
        XCTAssertEqual(audio.fileFormat.channelCount, 2)
        pipeline.stop()
        XCTAssertEqual(chunks.count, 2)
    }

    func testWriteFailureIsReportedOnceAndReturnedFromStop() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let pipeline = AudioPipeline(usesTimer: false, write: { _, _ in throw TestFailure.diskFull })
        var errors = 0
        pipeline.onError = { _ in errors += 1 }
        try pipeline.start(recordingURL: url)
        pipeline.appendMic([Int16](repeating: 1, count: 3_200))
        XCTAssertNotNil(pipeline.stop())
        XCTAssertEqual(errors, 1)
    }
}
