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
    /// NoteTemplate raw value used for AI enhancement.
    var template: String
    /// JSON dict mapping speaker keys ("them0", "them1", …) to display names.
    var speakerNames: String?

    static func new(title: String) -> Meeting {
        Meeting(id: UUID().uuidString, title: title, createdAt: Date())
    }

    /// Auto-generated titles start with this; AI auto-titling only replaces those.
    static let defaultTitlePrefix = "Meeting "

    var speakerNameMap: [String: String] {
        guard let data = speakerNames?.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    var attendeesList: [String] {
        guard let data = attendees?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    init(id: String, title: String, createdAt: Date, endedAt: Date? = nil,
         calendarEventId: String? = nil, attendees: String? = nil, audioFilePath: String? = nil,
         template: String = NoteTemplate.standard.rawValue, speakerNames: String? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.calendarEventId = calendarEventId
        self.attendees = attendees
        self.audioFilePath = audioFilePath
        self.template = template
        self.speakerNames = speakerNames
    }
}

extension Notification.Name {
    /// Posted after a meeting's title/speakers change outside the list's own actions.
    static let meetingChanged = Notification.Name("oatmeal.meetingChanged")
}

/// Maps a Deepgram channel + diarized speaker index to our stored speaker key.
func speakerKey(channel: Int, speakerIndex: Int?) -> String {
    if channel == 0 { return "me" }
    if let index = speakerIndex { return "them\(index)" }
    return "them"
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
