import SwiftUI

struct ActionItem: Identifiable {
    let id: String
    let meetingId: String
    let meetingTitle: String
    let meetingDate: Date
    let lineIndex: Int
    let text: String
    let done: Bool
}

/// Aggregates `- [ ]` checkbox lines across every meeting's enhanced notes.
@MainActor
final class ActionItemsModel: ObservableObject {
    @Published var items: [ActionItem] = []

    func reload() {
        var found: [ActionItem] = []
        let rows = (try? Store.shared.enhancedNotesWithMeetings()) ?? []
        for (note, meeting) in rows {
            for (index, line) in note.content.components(separatedBy: "\n").enumerated() {
                guard let (text, done) = Self.parseCheckbox(line) else { continue }
                found.append(ActionItem(
                    id: "\(meeting.id):\(index)",
                    meetingId: meeting.id,
                    meetingTitle: meeting.title,
                    meetingDate: meeting.createdAt,
                    lineIndex: index,
                    text: text,
                    done: done))
            }
        }
        items = found.sorted {
            if $0.done != $1.done { return !$0.done }
            return $0.meetingDate > $1.meetingDate
        }
    }

    static func parseCheckbox(_ line: String) -> (text: String, done: Bool)? {
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

    /// Flip `[ ]` ↔ `[x]` on the item's line in the stored enhanced note.
    func toggle(_ item: ActionItem) {
        guard let note = try? Store.shared.note(for: item.meetingId, kind: "enhanced") else { return }
        var lines = note.content.components(separatedBy: "\n")
        guard lines.indices.contains(item.lineIndex) else { reload(); return }
        let line = lines[item.lineIndex]
        lines[item.lineIndex] = item.done
            ? line.replacingOccurrences(of: "[x]", with: "[ ]")
                  .replacingOccurrences(of: "[X]", with: "[ ]")
            : line.replacingOccurrences(of: "[ ]", with: "[x]")
        try? Store.shared.saveNote(Note(meetingId: item.meetingId, kind: "enhanced",
                                        content: lines.joined(separator: "\n"), updatedAt: Date()))
        reload()
    }
}

struct ActionItemsView: View {
    @StateObject private var model = ActionItemsModel()
    let openMeeting: (String) -> Void

    private var grouped: [(meetingId: String, title: String, date: Date, items: [ActionItem])] {
        var order: [String] = []
        var buckets: [String: [ActionItem]] = [:]
        for item in model.items {
            if buckets[item.meetingId] == nil { order.append(item.meetingId) }
            buckets[item.meetingId, default: []].append(item)
        }
        return order.compactMap { id in
            guard let items = buckets[id], let first = items.first else { return nil }
            return (id, first.meetingTitle, first.meetingDate, items)
        }
    }

    var body: some View {
        Group {
            if model.items.isEmpty {
                ContentUnavailableView(
                    "No action items",
                    systemImage: "checklist",
                    description: Text("Action items from enhanced meeting notes show up here as a single to-do list.")
                )
            } else {
                List {
                    ForEach(grouped, id: \.meetingId) { group in
                        Section {
                            ForEach(group.items) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Button {
                                        model.toggle(item)
                                    } label: {
                                        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(item.done ? .green : .secondary)
                                    }
                                    .buttonStyle(.plain)
                                    Text(item.text)
                                        .strikethrough(item.done)
                                        .foregroundStyle(item.done ? .secondary : .primary)
                                    Spacer(minLength: 0)
                                }
                            }
                        } header: {
                            HStack {
                                Text(group.title)
                                Text(group.date, style: .date).foregroundStyle(.secondary)
                                Spacer()
                                Button("Open") { openMeeting(group.meetingId) }
                                    .buttonStyle(.link)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Action Items")
        .onAppear { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .meetingChanged)) { _ in
            model.reload()
        }
    }
}
