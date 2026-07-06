import Foundation

/// Enhancement templates — each is just a different system prompt, Granola-style.
enum NoteTemplate: String, CaseIterable, Identifiable {
    case standard
    case oneOnOne
    case sales
    case standup

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .oneOnOne: return "1:1"
        case .sales: return "Sales Call"
        case .standup: return "Standup"
        }
    }

    private static let preamble = """
        You turn raw meeting notes and a transcript into polished meeting notes.

        The user's raw notes are the backbone: preserve their bullets, wording, and \
        emphasis wherever possible, expanding shorthand and filling gaps using the \
        transcript. The transcript labels the user as "Me" and other participants as \
        "Them". Never invent facts that appear in neither the notes nor the transcript. \
        If the transcript is empty or thin, work with what the notes give you.

        Output clean Markdown only — no preamble, no closing remarks, no code fences \
        around the whole document.
        """

    var systemPrompt: String {
        switch self {
        case .standard:
            return Self.preamble + """


                Structure:
                ## Summary — 2-3 sentences on what the meeting was about and where it landed.
                ## Key Points — the substance, grouped by topic; fold the user's bullets in here.
                ## Decisions — decisions actually made (omit the section if none).
                ## Action Items — checkbox list; include owner and deadline when mentioned (omit if none).
                """
        case .oneOnOne:
            return Self.preamble + """


                This was a 1:1 conversation. Structure:
                ## Summary — the tone and main threads of the conversation.
                ## Topics Discussed — grouped by thread; keep personal/career items distinct from project items.
                ## Feedback — anything given or received (omit if none).
                ## Follow-ups — checkbox list of commitments either person made (omit if none).
                """
        case .sales:
            return Self.preamble + """


                This was a sales call. Structure:
                ## Summary — prospect, their situation, and how the call went.
                ## Needs & Pain Points — what the prospect is trying to solve.
                ## Objections & Questions — concerns raised and how they were answered (omit if none).
                ## Next Steps — checkbox list with owners and dates (omit if none).
                """
        case .standup:
            return Self.preamble + """


                This was a team standup. Structure it per person where identifiable:
                ## Updates — done / in progress per person or workstream.
                ## Blockers — anything blocking progress (omit if none).
                ## Action Items — checkbox list (omit if none).
                Keep it terse — standup notes should scan in seconds.
                """
        }
    }
}
