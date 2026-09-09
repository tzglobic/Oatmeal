import XCTest
import GRDB
@testable import Oatmeal

final class StoreTests: XCTestCase {
    func testPendingEnhancementSurvivesDatabaseReopenAndCascadesOnDelete() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let meeting = Meeting.new(title: "Meeting")
        do {
            let store = try Store(dbQueue: DatabaseQueue(path: url.path))
            try store.save(meeting)
            _ = try store.finishMeeting(id: meeting.id, at: Date())
        }
        let reopened = try Store(dbQueue: DatabaseQueue(path: url.path))
        XCTAssertEqual(try reopened.pendingEnhancements().map(\.id), [meeting.id])
        try reopened.delete(meeting)
        XCTAssertTrue(try reopened.pendingEnhancements().isEmpty)
    }

    func testAINameCannotOverwriteManualNameSetWhileWaiting() throws {
        let store = try Store(dbQueue: DatabaseQueue())
        let meeting = Meeting.new(title: "Meeting")
        try store.save(meeting)
        try store.updateSpeakerName(meetingId: meeting.id, key: "them0", name: "Manual name")
        XCTAssertFalse(try store.updateSpeakerName(meetingId: meeting.id, key: "them0", name: "AI guess", onlyIfUnnamed: true))
        XCTAssertEqual(try store.meeting(id: meeting.id)?.speakerNameMap["them0"], "Manual name")
        XCTAssertTrue(try store.updateSpeakerName(meetingId: meeting.id, key: "them1", name: "Another speaker", onlyIfUnnamed: true))
    }
}
