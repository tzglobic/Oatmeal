import Foundation
import SwiftUI

/// Per-meeting notes state: the user's raw notes, the AI-enhanced notes, and the
/// enhancement pipeline. Edits auto-save (debounced) to SQLite.
@MainActor
final class NotesModel: ObservableObject {
    let meetingId: String
    private let store: Store
    private let enhanceNotes: (String, String, NoteTemplate) async throws -> String
    private let generateTitle: (String, String) async throws -> String
    private let identifySpeakers: (String) async throws -> Void
    private var enhancementTask: Task<Void, Never>?
    private var userDirty = false
    private var enhancedDirty = false

    private final class WeakModel {
        weak var value: NotesModel?
        init(_ value: NotesModel) { self.value = value }
    }
    private static var models: [String: WeakModel] = [:]
    private static var unsavedModels: [String: NotesModel] = [:]
    var hasUnsavedChanges: Bool { userDirty || enhancedDirty }

    /// Views and post-recording work share the same editor, including unsaved text.
    static func shared(for meeting: Meeting) -> NotesModel {
        if let model = models[meeting.id]?.value { return model }
        models = models.filter { $0.value.value != nil }
        let model = NotesModel(meeting: meeting)
        models[meeting.id] = WeakModel(model)
        return model
    }

    @discardableResult
    static func flushAll() -> Bool {
        let editors = models.values.compactMap(\.value)
        for model in editors { model.flush() }
        return editors.allSatisfy { !$0.hasUnsavedChanges }
    }

    static func cancelEnhancements() {
        for model in models.values.compactMap(\.value) { model.enhancementTask?.cancel() }
    }

    @Published var userNotes: String = "" {
        didSet { if !suppressSave { userDirty = true; scheduleSave() } }
    }
    @Published var enhancedNotes: String = "" {
        didSet { if !suppressSave { enhancedDirty = true; scheduleSave() } }
    }
    @Published var template: NoteTemplate = .standard {
        didSet {
            if !suppressSave {
                do {
                    try store.updateTemplate(meetingId: meetingId, template: template.rawValue)
                } catch { errorMessage = "Couldn't save the template: \(error.localizedDescription)" }
            }
        }
    }
    @Published var isEnhancing = false
    @Published var errorMessage: String?

    private var suppressSave = true
    private var saveTask: Task<Void, Never>?

    init(meeting: Meeting, store: Store = .shared,
         enhanceNotes: @escaping (String, String, NoteTemplate) async throws -> String = { try await AIService.enhanceNotes(userNotes: $0, transcript: $1, template: $2) },
         generateTitle: @escaping (String, String) async throws -> String = { try await AIService.generateTitle(userNotes: $0, transcript: $1) },
         identifySpeakers: @escaping (String) async throws -> Void = { _ = try await SpeakerIdentifier.identify(meetingId: $0) }) {
        self.store = store
        self.enhanceNotes = enhanceNotes
        self.generateTitle = generateTitle
        self.identifySpeakers = identifySpeakers
        meetingId = meeting.id
        template = NoteTemplate(rawValue: meeting.template) ?? .standard
        do {
            userNotes = try store.note(for: meetingId, kind: "user")?.content ?? ""
            enhancedNotes = try store.note(for: meetingId, kind: "enhanced")?.content ?? ""
            suppressSave = false
        } catch {
            errorMessage = "Couldn't load notes: \(error.localizedDescription). Reopen this meeting to retry."
        }
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
        guard !suppressSave else { return }
        let now = Date()
        do {
            // Only write edited fields; an action-item toggle in another view
            // must not be overwritten by flushing an unchanged editor.
            if userDirty {
                try store.saveNote(Note(meetingId: meetingId, kind: "user",
                                        content: userNotes, updatedAt: now))
                userDirty = false
            }
            if enhancedDirty {
                try store.saveNote(Note(meetingId: meetingId, kind: "enhanced",
                                        content: enhancedNotes, updatedAt: now))
                enhancedDirty = false
            }
            if !hasUnsavedChanges { Self.unsavedModels[meetingId] = nil }
        } catch {
            // Keep failed edits available even if the window closes.
            if Self.models[meetingId]?.value === self { Self.unsavedModels[meetingId] = self }
            errorMessage = "Couldn't save notes: \(error.localizedDescription). Your edits are still in this window."
        }
    }

    // MARK: - Enhancement

    var canEnhance: Bool { !isEnhancing }

    /// `auto` marks the automatic post-recording invocation: an empty meeting is
    /// then a silent no-op rather than an error the user never asked about.
    @discardableResult
    func enhance(auto: Bool = false) -> Task<Void, Never>? {
        guard !isEnhancing else { return enhancementTask }
        guard !suppressSave else { return nil }
        let segments: [TranscriptSegment]
        do { segments = try store.segments(for: meetingId) }
        catch { errorMessage = "Couldn't load transcript: \(error.localizedDescription)"; return nil }
        let hasNotes = !userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !segments.isEmpty || hasNotes else {
            if !auto {
                errorMessage = "Nothing to enhance yet — record the meeting or type some notes first."
            }
            if auto {
                do { try store.completeEnhancement(meetingId: meetingId) }
                catch { errorMessage = "Couldn't finish the empty meeting: \(error.localizedDescription)" }
            }
            return nil
        }
        isEnhancing = true
        errorMessage = nil
        let notes = userNotes
        let names = (try? store.meeting(id: meetingId))?.speakerNameMap ?? [:]
        let transcript = Self.transcriptText(segments, names: names)
        let template = template
        let task = Task {
            do {
                let result = try await enhanceNotes(notes, transcript, template)
                try Task.checkCancellation()
                enhancedNotes = result
                flush() // persist now — don't risk losing the result to the debounce window
                guard !hasUnsavedChanges else {
                    isEnhancing = false
                    enhancementTask = nil
                    return
                }
                try store.completeEnhancement(meetingId: meetingId)
                await autoTitleIfNeeded(userNotes: notes, transcript: transcript)
                // Best-effort: put real names on the "Them" speakers.
                if !Task.isCancelled { try? await identifySpeakers(meetingId) }
            } catch is CancellationError {
                // Quit leaves the persisted job pending for the next launch.
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            isEnhancing = false
            enhancementTask = nil
        }
        enhancementTask = task
        return task
    }

    /// Replace the default "Meeting <date>" title with an AI-generated one.
    /// Never touches a title the user set themselves.
    private func autoTitleIfNeeded(userNotes: String, transcript: String) async {
        guard let meeting = try? store.meeting(id: meetingId),
              meeting.title.hasPrefix(Meeting.defaultTitlePrefix) else { return }
        guard let title = try? await generateTitle(userNotes, transcript), !title.isEmpty else { return }
        do {
            try store.updateGeneratedTitle(meetingId: meetingId, expected: meeting.title, title: title)
        } catch { errorMessage = "Couldn't save the generated title: \(error.localizedDescription)" }
        NotificationCenter.default.post(name: .meetingChanged, object: nil)
    }

    /// Plain-text transcript with speaker labels and timestamps. Passing the
    /// meeting's speaker-name map keeps assigned names (and Them 1/Them 2
    /// diarization) instead of flattening everyone to "Them".
    static func transcriptText(_ segments: [TranscriptSegment],
                               names: [String: String] = [:]) -> String {
        segments.map { segment in
            let t = Int(segment.startTime)
            let speaker = speakerDisplayName(key: segment.speaker, names: names)
            return String(format: "[%@ %d:%02d] %@", speaker, t / 60, t % 60, segment.text)
        }.joined(separator: "\n")
    }
}
