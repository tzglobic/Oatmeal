import XCTest
import GRDB
@testable import Oatmeal

final class NotesModelTests: XCTestCase {
    @MainActor func testEnhancementUsesUnsavedNotesAndDoesNotOverwriteLaterEdits() async throws {
        let store = try Store(dbQueue: DatabaseQueue())
        let meeting = Meeting.new(title: "Manual title")
        try store.save(meeting)
        let gate = Gate()
        let entered = expectation(description: "enhancing")
        var calls = 0
        let model = NotesModel(meeting: meeting, store: store, enhanceNotes: { notes, _, _ in
            calls += 1
            XCTAssertEqual(notes, "not yet saved")
            entered.fulfill()
            await gate.wait()
            return "Enhanced result"
        }, generateTitle: { _, _ in "unused" }, identifySpeakers: { _ in })
        model.userNotes = "not yet saved"
        let first = try XCTUnwrap(model.enhance(auto: true))
        await fulfillment(of: [entered], timeout: 2)
        model.userNotes = "edited during enhancement"
        let second = try XCTUnwrap(model.enhance())
        await gate.release()
        await first.value
        await second.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try store.note(for: meeting.id, kind: "user")?.content, "edited during enhancement")
        XCTAssertEqual(try store.note(for: meeting.id, kind: "enhanced")?.content, "Enhanced result")
    }

    @MainActor func testGeneratedTitleCannotOverwriteRenameWhileWaitingForAI() async throws {
        let store = try Store(dbQueue: DatabaseQueue())
        let meeting = Meeting.new(title: "Meeting Sep 9")
        try store.save(meeting)
        let gate = Gate()
        let entered = expectation(description: "generating title")
        let model = NotesModel(meeting: meeting, store: store,
                               enhanceNotes: { _, _, _ in "Summary" }, generateTitle: { _, _ in
            entered.fulfill()
            await gate.wait()
            return "AI title"
        }, identifySpeakers: { _ in })
        model.userNotes = "Some notes"
        let task = try XCTUnwrap(model.enhance())
        await fulfillment(of: [entered], timeout: 2)
        try store.updateTitle(meetingId: meeting.id, title: "My manual title")
        await gate.release()
        await task.value
        XCTAssertEqual(try store.meeting(id: meeting.id)?.title, "My manual title")
    }

    @MainActor func testUnchangedEnhancedNotesDoNotOverwriteActionItemToggle() async throws {
        let store = try Store(dbQueue: DatabaseQueue())
        let meeting = Meeting.new(title: "Meeting")
        try store.save(meeting)
        try store.saveNote(Note(meetingId: meeting.id, kind: "enhanced", content: "- [ ] follow up", updatedAt: Date()))
        let model = NotesModel(meeting: meeting, store: store)
        try store.saveNote(Note(meetingId: meeting.id, kind: "enhanced", content: "- [x] follow up", updatedAt: Date()))
        model.userNotes = "A new raw note"
        model.flush()
        XCTAssertEqual(try store.note(for: meeting.id, kind: "enhanced")?.content, "- [x] follow up")
    }

    @MainActor func testFailedSaveRetainsEditsAndCanBeRetried() async throws {
        let store = try Store(dbQueue: DatabaseQueue())
        let meeting = Meeting.new(title: "Meeting")
        try store.save(meeting)
        let model = NotesModel(meeting: meeting, store: store)
        try await store.dbQueue.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_note BEFORE INSERT ON notes BEGIN SELECT RAISE(FAIL, 'disk full'); END")
        }
        model.userNotes = "Do not lose this"
        model.flush()
        XCTAssertTrue(model.errorMessage?.contains("Couldn't save notes") == true)
        XCTAssertEqual(model.userNotes, "Do not lose this")
        try await store.dbQueue.write { db in try db.execute(sql: "DROP TRIGGER fail_note") }
        model.flush()
        XCTAssertEqual(try store.note(for: meeting.id, kind: "user")?.content, "Do not lose this")
    }
    @MainActor func testCancelledEnhancementLeavesJobPendingAndDoesNotSaveLateResult() async throws {
        let store = try Store(dbQueue: DatabaseQueue())
        let meeting = Meeting.new(title: "Manual title")
        try store.save(meeting)
        _ = try store.finishMeeting(id: meeting.id, at: Date())
        let gate = Gate()
        let entered = expectation(description: "AI request started")
        let model = NotesModel(meeting: meeting, store: store, enhanceNotes: { _, _, _ in
            entered.fulfill()
            await gate.wait()
            return "Late result after Quit"
        }, generateTitle: { _, _ in "unused" }, identifySpeakers: { _ in })
        model.userNotes = "Preserve the raw notes"
        let task = try XCTUnwrap(model.enhance(auto: true))
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        model.flush()
        await gate.release()
        await task.value
        XCTAssertNil(try store.note(for: meeting.id, kind: "enhanced"))
        XCTAssertEqual(try store.note(for: meeting.id, kind: "user")?.content, "Preserve the raw notes")
        XCTAssertEqual(try store.pendingEnhancements().map(\.id), [meeting.id])
        XCTAssertFalse(model.isEnhancing)
    }

}
