import Foundation

/// A presentation-only interpretation of notes; the original Markdown stays intact.
struct NotesDocument {
    struct Block: Identifiable {
        enum Kind: Equatable { case heading(Int), paragraph, bullet, code }
        let id: Int
        let kind: Kind
        let text: String
    }
    struct FollowUp: Identifiable {
        let id: Int // Index of the original Markdown line, never an inferred task ID.
        let text: String
        let done: Bool
    }
    let blocks: [Block]
    let followUps: [FollowUp]

    init(_ markdown: String) {
        var blocks: [Block] = []
        var followUps: [FollowUp] = []
        var fence: String?
        for (index, line) in markdown.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let openFence = fence {
                if trimmed.hasPrefix(openFence) { fence = nil }
                else { blocks.append(Block(id: index, kind: .code, text: line)) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                continue
            }
            guard !trimmed.isEmpty else { continue }
            if let task = NoteCheckbox.parse(line) {
                followUps.append(FollowUp(id: index, text: task.text, done: task.done))
                // Keep the task in its original context as well as in the rail.
                blocks.append(Block(id: index, kind: .bullet,
                                    text: "\(task.done ? "☑" : "☐") \(task.text)"))
            } else {
                let hashes = trimmed.prefix { $0 == "#" }.count
                if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                    blocks.append(Block(id: index, kind: .heading(hashes),
                                        text: String(trimmed.dropFirst(hashes + 1))))
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    blocks.append(Block(id: index, kind: .bullet, text: String(trimmed.dropFirst(2))))
                } else {
                    blocks.append(Block(id: index, kind: .paragraph, text: line))
                }
            }
        }
        self.blocks = blocks
        self.followUps = followUps
    }

    /// Verify the current line before applying a click from a possibly stale view.
    static func toggling(_ item: FollowUp, in markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        guard lines.indices.contains(item.id),
              let current = NoteCheckbox.parse(lines[item.id]),
              current.text == item.text, current.done == item.done else { return markdown }
        lines[item.id] = NoteCheckbox.flipping(in: lines[item.id], to: !item.done)
        return lines.joined(separator: "\n")
    }
}
