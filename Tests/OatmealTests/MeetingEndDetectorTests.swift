import XCTest
@testable import Oatmeal

final class MeetingEndDetectorTests: XCTestCase {
    @MainActor func testDisablingCancelsCountdownAndStaleTimerCannotStopNextSession() async {
        var date = Date(timeIntervalSince1970: 1_000)
        var enabled = true
        var stops = 0
        var withdrawals = 0
        let detector = MeetingEndDetector(now: { date }, enabled: { enabled }, usesTimers: false,
                                          notify: { _, _ in }, withdraw: { withdrawals += 1 })
        detector.onStop = { stops += 1 }
        detector.begin(eventEnd: nil)
        date.addTimeInterval(901)
        detector.evaluate()
        let deadline = detector.pending!.deadline
        enabled = false
        detector.settingsChanged()
        XCTAssertNil(detector.pending)
        XCTAssertEqual(withdrawals, 1)
        date = deadline
        detector.reactionWindowClosed(deadline: deadline)
        XCTAssertEqual(stops, 0)
        enabled = true
        detector.begin(eventEnd: nil)
        date.addTimeInterval(901)
        detector.evaluate()
        detector.reactionWindowClosed(deadline: deadline)
        XCTAssertEqual(stops, 0)
        let newDeadline = detector.pending!.deadline
        date = newDeadline
        detector.reactionWindowClosed(deadline: newDeadline)
        XCTAssertEqual(stops, 1)
        detector.end()
    }

    @MainActor func testDeadlineRechecksSettingEvenWithoutSettingsCallback() async {
        var date = Date()
        var enabled = true
        var stops = 0
        let detector = MeetingEndDetector(now: { date }, enabled: { enabled }, usesTimers: false,
                                          notify: { _, _ in }, withdraw: {})
        detector.onStop = { stops += 1 }
        detector.begin(eventEnd: nil)
        date.addTimeInterval(901)
        detector.evaluate()
        let deadline = detector.pending!.deadline
        enabled = false
        date = deadline
        detector.reactionWindowClosed(deadline: deadline)
        XCTAssertEqual(stops, 0)
        XCTAssertNil(detector.pending)
        detector.end()
    }

    @MainActor func testSpeechAndPauseCancelProposals() async {
        var date = Date()
        let detector = MeetingEndDetector(now: { date }, enabled: { true }, usesTimers: false,
                                          notify: { _, _ in }, withdraw: {})
        detector.begin(eventEnd: date)
        date.addTimeInterval(181)
        detector.evaluate()
        XCTAssertNotNil(detector.pending)
        detector.noteLevels(mic: 0.5, system: 0)
        XCTAssertNil(detector.pending)
        date.addTimeInterval(901)
        detector.evaluate()
        XCTAssertNotNil(detector.pending)
        detector.setPaused(true)
        XCTAssertNil(detector.pending)
        date.addTimeInterval(901)
        detector.evaluate()
        XCTAssertNil(detector.pending)
        detector.end()
    }
}
