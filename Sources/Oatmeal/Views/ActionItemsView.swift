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
            for item in NotesDocument(note.content).followUps {
                found.append(ActionItem(
                    id: "\(meeting.id):\(item.id)",
                    meetingId: meeting.id,
                    meetingTitle: meeting.title,
                    meetingDate: meeting.createdAt,
                    lineIndex: item.id,
                    text: item.text,
                    done: item.done))
            }
        }
        items = found.sorted {
            if $0.done != $1.done { return !$0.done }
            return $0.meetingDate > $1.meetingDate
        }
    }

    /// Replaces the state character of the leading `- [ ]` / `* [x]` marker,
    /// leaving the rest of the line — brackets included — untouched.
    nonisolated static func flippingCheckbox(in line: String, to done: Bool) -> String {
        NoteCheckbox.flipping(in: line, to: done)
    }

    nonisolated static func parseCheckbox(_ line: String) -> (text: String, done: Bool)? {
        NoteCheckbox.parse(line)
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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                OatmealSectionLabel(title: "Across your meetings")
                Text("Action items")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("\(model.items.filter { !$0.done }.count) open · Follow through on your meeting notes")
                    .font(.subheadline)
                    .foregroundStyle(OatmealStyle.muted)
            }
            .padding(24)
            Divider()
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
                                        Image(systemName: item.done ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(OatmealStyle.accent)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(item.done ? "Mark incomplete" : "Complete"): \(item.text)")
                                    Text(item.text)
                                        .strikethrough(item.done)
                                        .foregroundStyle(item.done ? .secondary : .primary)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 8)
                                .listRowBackground(OatmealStyle.panel)
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
                .scrollContentBackground(.hidden)
                .background(OatmealStyle.panel)
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
