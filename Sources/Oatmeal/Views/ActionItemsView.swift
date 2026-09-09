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
    @Published var errorMessage: String?

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

    /// Replaces the state character of the leading `- [ ]` / `* [x]` marker,
    /// leaving the rest of the line — brackets included — untouched.
    static func flippingCheckbox(in line: String, to done: Bool) -> String {
        for marker in ["- [", "* ["] {
            let indent = line.prefix { $0.isWhitespace }.count
            guard let range = line.range(of: marker),
                  line.distance(from: line.startIndex, to: range.lowerBound) == indent
            else { continue }
            let stateIndex = range.upperBound
            guard stateIndex < line.endIndex else { continue }
            let closeIndex = line.index(after: stateIndex)
            guard closeIndex < line.endIndex, line[closeIndex] == "]" else { continue }
            var updated = line
            updated.replaceSubrange(stateIndex..<closeIndex, with: done ? "x" : " ")
            return updated
        }
        return line
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
        // The note may have been re-enhanced or edited since this list loaded —
        // verify the line still holds this exact item before writing back.
        guard lines.indices.contains(item.lineIndex),
              let current = Self.parseCheckbox(lines[item.lineIndex]),
              current.text == item.text, current.done == item.done else {
            reload()
            return
        }
        // Rewrite only the checkbox marker. replacingOccurrences would also hit
        // a bracket pair inside the item's own text ("- [ ] fix the [x] badge"),
        // corrupting it on every toggle.
        lines[item.lineIndex] = Self.flippingCheckbox(in: lines[item.lineIndex], to: !item.done)
        do {
            try Store.shared.saveNote(Note(meetingId: item.meetingId, kind: "enhanced",
                                            content: lines.joined(separator: "\n"), updatedAt: Date()))
            errorMessage = nil
            reload()
        } catch { errorMessage = "Couldn't save the action item: \(error.localizedDescription)" }
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
        .alert("Action Items", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
        .onAppear { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .meetingChanged)) { _ in
            model.reload()
        }
    }
}
