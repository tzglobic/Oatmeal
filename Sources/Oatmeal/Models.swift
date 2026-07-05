import Foundation
import GRDB

struct Meeting: Identifiable, Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meetings"

    var id: String
    var title: String
    var createdAt: Date
    var endedAt: Date?
    var calendarEventId: String?
    /// JSON-encoded array of attendee email addresses.
    var attendees: String?
    var audioFilePath: String?

    static func new(title: String) -> Meeting {
        Meeting(id: UUID().uuidString, title: title, createdAt: Date())
    }

    init(id: String, title: String, createdAt: Date, endedAt: Date? = nil,
         calendarEventId: String? = nil, attendees: String? = nil, audioFilePath: String? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.calendarEventId = calendarEventId
        self.attendees = attendees
        self.audioFilePath = audioFilePath
    }
}

struct TranscriptSegment: Identifiable, Codable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "transcript_segments"

    var id: Int64?
    var meetingId: String
    /// "me" (mic) or "them" (system audio); refined by diarization later.
    var speaker: String
    var text: String
    var startTime: Double
    var endTime: Double
    var isFinal: Bool

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct Note: Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "notes"

    var meetingId: String
    /// "user" (typed live) or "enhanced" (AI output).
    var kind: String
    var content: String
    var updatedAt: Date
}

struct ChatMessage: Identifiable, Codable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "chats"

    var id: Int64?
    /// nil = the cross-meeting "All meetings" thread.
    var meetingId: String?
    var role: String
    var content: String
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct Recipe: Identifiable, Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "recipes"

    var id: String
    var name: String
    var prompt: String
    var createdAt: Date
}
