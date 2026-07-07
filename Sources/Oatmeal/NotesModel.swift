import Foundation
import SwiftUI

/// Per-meeting notes state: the user's raw notes, the AI-enhanced notes, and the
/// enhancement pipeline. Edits auto-save (debounced) to SQLite.
@MainActor
final class NotesModel: ObservableObject {
    let meetingId: String

    @Published var userNotes: String = "" {
        didSet { if !suppressSave { scheduleSave() } }
    }
    @Published var enhancedNotes: String = "" {
        didSet { if !suppressSave { scheduleSave() } }
    }
    @Published var template: NoteTemplate = .standard {
        didSet {
            if !suppressSave {
                try? Store.shared.updateTemplate(meetingId: meetingId, template: template.rawValue)
            }
        }
    }
    @Published var isEnhancing = false
    @Published var errorMessage: String?

    private var suppressSave = true
    private var saveTask: Task<Void, Never>?

    init(meeting: Meeting) {
        meetingId = meeting.id
        template = NoteTemplate(rawValue: meeting.template) ?? .standard
        userNotes = (try? Store.shared.note(for: meetingId, kind: "user"))??.content ?? ""
        enhancedNotes = (try? Store.shared.note(for: meetingId, kind: "enhanced"))??.content ?? ""
        suppressSave = false
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            persist()
        }
    }

    /// Save immediately (e.g. when the view disappears).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        persist()
    }

    private func persist() {
        let now = Date()
        try? Store.shared.saveNote(Note(meetingId: meetingId, kind: "user",
                                        content: userNotes, updatedAt: now))
        try? Store.shared.saveNote(Note(meetingId: meetingId, kind: "enhanced",
                                        content: enhancedNotes, updatedAt: now))
    }

    // MARK: - Enhancement

    var canEnhance: Bool { !isEnhancing }

    /// `auto` marks the automatic post-recording invocation: an empty meeting is
    /// then a silent no-op rather than an error the user never asked about.
    func enhance(auto: Bool = false) {
        guard !isEnhancing else { return }
        let segments = (try? Store.shared.segments(for: meetingId)) ?? []
        let hasNotes = !userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !segments.isEmpty || hasNotes else {
            if !auto {
                errorMessage = "Nothing to enhance yet — record the meeting or type some notes first."
            }
            return
        }
        isEnhancing = true
        errorMessage = nil
        let notes = userNotes
        let transcript = Self.transcriptText(segments)
        let template = template
        Task {
            do {
                let result = try await AIService.enhanceNotes(
                    userNotes: notes, transcript: transcript, template: template)
                enhancedNotes = result
                flush() // persist now — don't risk losing the result to the debounce window
                await autoTitleIfNeeded(userNotes: notes, transcript: transcript)
                // Best-effort: put real names on the "Them" speakers.
                _ = try? await SpeakerIdentifier.identify(meetingId: meetingId)
            } catch {
                errorMessage = error.localizedDescription
            }
            isEnhancing = false
        }
    }

    /// Replace the default "Meeting <date>" title with an AI-generated one.
    /// Never touches a title the user set themselves.
    private func autoTitleIfNeeded(userNotes: String, transcript: String) async {
        guard let meeting = try? Store.shared.meeting(id: meetingId),
              meeting.title.hasPrefix(Meeting.defaultTitlePrefix) else { return }
        guard let title = try? await AIService.generateTitle(
            userNotes: userNotes, transcript: transcript), !title.isEmpty else { return }
        try? Store.shared.updateTitle(meetingId: meetingId, title: title)
        NotificationCenter.default.post(name: .meetingChanged, object: nil)
    }

    static func transcriptText(_ segments: [TranscriptSegment]) -> String {
        segments.map { segment in
            let t = Int(segment.startTime)
            let speaker = segment.speaker == "me" ? "Me" : "Them"
            return String(format: "[%@ %d:%02d] %@", speaker, t / 60, t % 60, segment.text)
        }.joined(separator: "\n")
    }
}
