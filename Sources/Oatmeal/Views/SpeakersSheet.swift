import SwiftUI

/// Edit who's who in a meeting: every detected speaker with a sample of what
/// they said, a name field, quick-pick from calendar attendees, and one-click
/// AI identification from the transcript.
struct SpeakersSheet: View {
    let meetingId: String
    let attendees: [String]
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = []
    @State private var names: [String: String] = [:]
    @State private var isIdentifying = false
    @State private var statusMessage: String?

    struct Row: Identifiable {
        let key: String
        let defaultLabel: String
        let sample: String
        var id: String { key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speakers").font(.title3.bold())

            if rows.isEmpty {
                Text("No other speakers detected in this meeting's transcript yet.")
                    .foregroundStyle(.secondary)
            } else {
                Form {
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.defaultLabel)
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                Text("“\(row.sample)”")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                            }
                            .frame(width: 170, alignment: .leading)

                            TextField("Name", text: binding(for: row.key))
                                .textFieldStyle(.roundedBorder)

                            if !attendees.isEmpty {
                                Menu {
                                    ForEach(attendees, id: \.self) { attendee in
                                        Button(attendee) { names[row.key] = attendee }
                                    }
                                } label: {
                                    Image(systemName: "person.crop.circle.badge.questionmark")
                                }
                                .menuStyle(.borderlessButton)
                                .frame(width: 30)
                                .help("Pick from this meeting's attendees")
                            }
                        }
                    }
                }
                .formStyle(.columns)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if isIdentifying {
                    ProgressView().controlSize(.small)
                    Text("Identifying from transcript…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        identifyWithAI()
                    } label: {
                        Label("Identify with AI", systemImage: "sparkles")
                    }
                    .disabled(rows.isEmpty)
                    .help("Infer names from introductions and how people address each other, matched against the attendee list")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: load)
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(get: { names[key] ?? "" }, set: { names[key] = $0 })
    }

    private func load() {
        let meeting = try? Store.shared.meeting(id: meetingId)
        let stored = meeting?.speakerNameMap ?? [:]
        let segments = (try? Store.shared.segments(for: meetingId)) ?? []

        var seen: [String] = []
        var samples: [String: String] = [:]
        for segment in segments where segment.speaker != "me" {
            if samples[segment.speaker] == nil {
                seen.append(segment.speaker)
                samples[segment.speaker] = String(segment.text.prefix(80))
            }
        }
        rows = seen.map { key in
            Row(key: key, defaultLabel: Self.defaultLabel(for: key), sample: samples[key] ?? "")
        }
        names = stored
    }

    private static func defaultLabel(for key: String) -> String {
        if key == "them" { return "Them" }
        if key.hasPrefix("them"), let n = Int(key.dropFirst(4)) { return "Them \(n + 1)" }
        return key
    }

    private func identifyWithAI() {
        isIdentifying = true
        statusMessage = nil
        Task {
            do {
                let outcome = try await SpeakerIdentifier.identify(meetingId: meetingId)
                // Merge fresh results into the fields (AI never overwrites manual
                // names, so refreshing from the store keeps user edits).
                if let updated = try? Store.shared.meeting(id: meetingId) {
                    for (key, name) in updated.speakerNameMap where (names[key] ?? "").isEmpty {
                        names[key] = name
                    }
                }
                statusMessage = outcome.named > 0
                    ? "Identified \(outcome.named) speaker\(outcome.named == 1 ? "" : "s")."
                    : "Couldn't confidently identify anyone — the transcript may not contain names."
            } catch {
                statusMessage = error.localizedDescription
            }
            isIdentifying = false
        }
    }

    private func save() {
        do {
            for row in rows {
                try Store.shared.updateSpeakerName(
                    meetingId: meetingId, key: row.key, name: names[row.key] ?? "")
            }
        } catch {
            statusMessage = "Couldn't save speaker names: \(error.localizedDescription)"
            return
        }
        NotificationCenter.default.post(name: .meetingChanged, object: nil)
        onSaved()
        dismiss()
    }
}
