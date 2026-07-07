import Foundation
import GRDB

/// Local SQLite storage. Everything lives on-device in
/// ~/Library/Application Support/Oatmeal/oatmeal.sqlite
final class Store {
    static let shared = Store()

    let dbQueue: DatabaseQueue

    private init() {
        do {
            let fm = FileManager.default
            let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                 appropriateFor: nil, create: true)
                .appendingPathComponent("Oatmeal", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            dbQueue = try DatabaseQueue(path: dir.appendingPathComponent("oatmeal.sqlite").path)
            try Store.migrator.migrate(dbQueue)
        } catch {
            fatalError("Failed to open database: \(error)")
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "meetings") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("calendarEventId", .text)
                t.column("attendees", .text)
                t.column("audioFilePath", .text)
            }

            try db.create(table: "transcript_segments") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingId", .text).notNull()
                    .references("meetings", onDelete: .cascade)
                t.column("speaker", .text).notNull()
                t.column("text", .text).notNull()
                t.column("startTime", .double).notNull()
                t.column("endTime", .double).notNull()
                t.column("isFinal", .boolean).notNull().defaults(to: true)
            }
            try db.create(indexOn: "transcript_segments", columns: ["meetingId"])

            try db.create(table: "notes") { t in
                t.column("meetingId", .text).notNull()
                    .references("meetings", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("content", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["meetingId", "kind"])
            }

            try db.create(table: "chats") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingId", .text)
                    .references("meetings", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "recipes") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("prompt", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v2-meeting-template") { db in
            try db.alter(table: "meetings") { t in
                t.add(column: "template", .text).notNull().defaults(to: NoteTemplate.standard.rawValue)
            }
        }

        migrator.registerMigration("v3-speaker-names") { db in
            try db.alter(table: "meetings") { t in
                t.add(column: "speakerNames", .text)
            }
        }

        return migrator
    }

    // MARK: - Meetings

    func allMeetings() throws -> [Meeting] {
        try dbQueue.read { db in
            try Meeting.order(Column("createdAt").desc).fetchAll(db)
        }
    }

    func save(_ meeting: Meeting) throws {
        try dbQueue.write { db in
            try meeting.save(db)
        }
    }

    func delete(_ meeting: Meeting) throws {
        _ = try dbQueue.write { db in
            try meeting.delete(db)
        }
    }

    func meeting(id: String) throws -> Meeting? {
        try dbQueue.read { db in
            try Meeting.fetchOne(db, key: id)
        }
    }

    func updateTitle(meetingId: String, title: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE meetings SET title = ? WHERE id = ?",
                           arguments: [title, meetingId])
        }
    }

    func updateSpeakerName(meetingId: String, key: String, name: String) throws {
        try dbQueue.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: meetingId) else { return }
            var map = meeting.speakerNameMap
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                map.removeValue(forKey: key)
            } else {
                map[key] = trimmed
            }
            meeting.speakerNames = String(data: try JSONEncoder().encode(map), encoding: .utf8)
            try meeting.save(db)
        }
    }

    /// Case-insensitive substring search across titles, transcripts, and notes.
    /// LIKE is plenty at personal scale; swap for FTS5 when Phase 4 chat needs it.
    func searchMeetings(_ query: String) throws -> [Meeting] {
        // Escape LIKE metacharacters so a literal % or _ in the query isn't
        // treated as a wildcard.
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        return try dbQueue.read { db in
            try Meeting.fetchAll(db, sql: """
                SELECT DISTINCT meetings.* FROM meetings
                LEFT JOIN transcript_segments ON transcript_segments.meetingId = meetings.id
                LEFT JOIN notes ON notes.meetingId = meetings.id
                WHERE meetings.title LIKE :p ESCAPE '\\'
                   OR transcript_segments.text LIKE :p ESCAPE '\\'
                   OR notes.content LIKE :p ESCAPE '\\'
                ORDER BY meetings.createdAt DESC
                """, arguments: ["p": pattern])
        }
    }

    // MARK: - Transcript segments

    func insert(_ segment: inout TranscriptSegment) throws {
        try dbQueue.write { db in
            try segment.insert(db)
        }
    }

    func segments(for meetingId: String) throws -> [TranscriptSegment] {
        try dbQueue.read { db in
            try TranscriptSegment
                .filter(Column("meetingId") == meetingId)
                .order(Column("startTime"))
                .fetchAll(db)
        }
    }

    /// Atomically replace a meeting's transcript (used by re-transcription).
    func replaceSegments(for meetingId: String, with segments: [TranscriptSegment]) throws {
        try dbQueue.write { db in
            try TranscriptSegment.filter(Column("meetingId") == meetingId).deleteAll(db)
            for var segment in segments {
                try segment.insert(db)
            }
        }
    }

    // MARK: - Notes

    func note(for meetingId: String, kind: String) throws -> Note? {
        try dbQueue.read { db in
            try Note.filter(Column("meetingId") == meetingId && Column("kind") == kind).fetchOne(db)
        }
    }

    func saveNote(_ note: Note) throws {
        try dbQueue.write { db in
            try note.save(db)
        }
    }

    /// All enhanced notes with their meetings, for the action-items rollup.
    func enhancedNotesWithMeetings() throws -> [(note: Note, meeting: Meeting)] {
        try dbQueue.read { db in
            let notes = try Note.filter(Column("kind") == "enhanced").fetchAll(db)
            let ids = notes.map(\.meetingId)
            let meetings = try Meeting.filter(ids.contains(Column("id"))).fetchAll(db)
            let byId = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })
            return notes.compactMap { note in byId[note.meetingId].map { (note, $0) } }
        }
    }

    func updateTemplate(meetingId: String, template: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE meetings SET template = ? WHERE id = ?",
                           arguments: [template, meetingId])
        }
    }

    // MARK: - Files

    static func recordingsDirectory() throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: true)
            .appendingPathComponent("Oatmeal/Recordings", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
