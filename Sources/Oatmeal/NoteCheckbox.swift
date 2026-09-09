import Foundation

/// Shared by the global action list and the per-meeting follow-up rail.
enum NoteCheckbox {
    static func parse(_ line: String) -> (text: String, done: Bool)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- [", "* ["] {
            guard trimmed.hasPrefix(marker), trimmed.count > marker.count + 1 else { continue }
            let stateIndex = trimmed.index(trimmed.startIndex, offsetBy: marker.count)
            let state = trimmed[stateIndex]
            guard trimmed[trimmed.index(after: stateIndex)] == "]" else { continue }
            let text = trimmed[trimmed.index(stateIndex, offsetBy: 2)...]
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            switch state {
            case " ": return (text, false)
            case "x", "X": return (text, true)
            default: continue
            }
        }
        return nil
    }

    static func flipping(in line: String, to done: Bool) -> String {
        guard parse(line) != nil else { return line }
        let indent = line.prefix { $0.isWhitespace }.count
        let stateIndex = line.index(line.startIndex, offsetBy: indent + 3)
        var updated = line
        updated.replaceSubrange(stateIndex..<line.index(after: stateIndex), with: done ? "x" : " ")
        return updated
    }
}
