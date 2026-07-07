import Foundation

/// Shared entry point for AI speaker identification — used automatically after
/// a recording is enhanced, and manually from the Speakers panel.
enum SpeakerIdentifier {
    struct Outcome {
        let named: Int          // how many speakers got a new name
        let unnamedLeft: Int    // them-keys still without a name
    }

    /// Names unnamed "them*" speakers in a meeting. Never overwrites a name the
    /// user set manually. Posts `.meetingChanged` when anything was applied.
    @discardableResult
    static func identify(meetingId: String) async throws -> Outcome {
        guard let meeting = try? Store.shared.meeting(id: meetingId) else {
            return Outcome(named: 0, unnamedLeft: 0)
        }
        let segments = (try? Store.shared.segments(for: meetingId)) ?? []
        let existing = meeting.speakerNameMap
        let themKeys = Set(segments.map(\.speaker)).filter { $0 != "me" }
        let unnamed = themKeys.filter { existing[$0]?.isEmpty != false }
        guard !unnamed.isEmpty, !segments.isEmpty else {
            return Outcome(named: 0, unnamedLeft: unnamed.count)
        }

        let transcript = segments
            .map { "[\($0.speaker)] \($0.text)" }
            .joined(separator: "\n")
        let mapping = try await AIService.identifySpeakers(
            transcript: transcript, attendees: meeting.attendeesList)

        var named = 0
        for (key, name) in mapping {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard unnamed.contains(key), !trimmed.isEmpty else { continue }
            try? Store.shared.updateSpeakerName(meetingId: meetingId, key: key, name: trimmed)
            named += 1
        }
        if named > 0 {
            NotificationCenter.default.post(name: .meetingChanged, object: nil)
        }
        return Outcome(named: named, unnamedLeft: unnamed.count - named)
    }
}
