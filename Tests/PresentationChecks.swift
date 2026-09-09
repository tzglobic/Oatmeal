import Foundation

/// Run with Scripts/check-presentation.sh; no XCTest or Xcode installation needed.
@main
struct PresentationChecks {
    static func main() {
        let source = "## Decisions\nKeep the original.\n\n- [ ] Call **Maya**\n```md\n- [ ] Example only\n```\n  * [X] Already done\n"
        let document = NotesDocument(source)
        precondition(document.followUps.map(\.id) == [3, 7])
        precondition(document.followUps.map(\.done) == [false, true])
        precondition(document.blocks.contains { $0.kind == .code && $0.text == "- [ ] Example only" })
        precondition(document.blocks.contains { $0.text == "Keep the original." })

        let original = "## Follow-ups\n\n  * [ ] Fix the [x] badge — **Maya**\n- [X] Done\n\n"
        let item = NotesDocument(original).followUps.first!
        let updated = NotesDocument.toggling(item, in: original)
        precondition(updated == "## Follow-ups\n\n  * [x] Fix the [x] badge — **Maya**\n- [X] Done\n\n")
        precondition(NotesDocument.toggling(NotesDocument(updated).followUps.first!, in: updated) == original)

        let stale = NotesDocument("- [ ] Original task").followUps.first!
        for current in ["- [ ] New task", "- [x] Original task", "", "## Heading\n- [ ] Original task"] {
            precondition(NotesDocument.toggling(stale, in: current) == current)
        }

        let mixed = NotesDocument("# Title\n## Summary\nA **bold** point.\n- A bullet\n#hashtag\n- [q] Not a task\n~~~\ncode\n~~~")
        precondition(mixed.blocks.count == 7)
        precondition(mixed.blocks[0].kind == .heading(1))
        precondition(mixed.blocks[3].kind == .bullet)
        precondition(mixed.blocks[4].text == "#hashtag")
        precondition(mixed.blocks[6].kind == .code)
        precondition(mixed.followUps.isEmpty)

        struct Entry { let id: Int; let date: Date }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12))!
        let meetings = [0, -1, -8].map { offset in
            Entry(id: offset, date: calendar.date(byAdding: .day, value: offset, to: now)!)
        }
        let groups = MeetingTimeline.groups(Array(meetings.reversed()), date: \.date, now: now, calendar: calendar)
        precondition(groups.map(\.title) == ["Today", "This week", "Earlier"])
        precondition(groups.flatMap(\.meetings).map(\.id) == [0, -1, -8])
        precondition(MeetingTimeline.groups(meetings, date: \.date, searching: true).first?.meetings.count == 3)
        precondition(MeetingTimeline.groups([Entry](), date: \.date).isEmpty)
        print("PASS: Markdown rendering, fenced examples, checkbox round-trip, stale edits, timeline grouping and search")
    }
}
