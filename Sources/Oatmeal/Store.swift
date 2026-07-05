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
