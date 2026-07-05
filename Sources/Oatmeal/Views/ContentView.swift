import SwiftUI

final class MeetingListModel: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selection: Meeting.ID?

    func reload() {
        meetings = (try? Store.shared.allMeetings()) ?? []
    }
}

struct ContentView: View {
    @EnvironmentObject var model: MeetingListModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                if model.meetings.isEmpty {
                    Text("No meetings yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.meetings) { meeting in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meeting.title)
                                .lineLimit(1)
                            Text(meeting.createdAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(meeting.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .navigationTitle("Meetings")
        } detail: {
            if let id = model.selection,
               let meeting = model.meetings.first(where: { $0.id == id }) {
                MeetingDetailView(meeting: meeting)
            } else {
                ContentUnavailableView(
                    "Select a meeting",
                    systemImage: "text.bubble",
                    description: Text("Recording arrives in Phase 1 — set your API keys in Settings (⌘,) first.")
                )
            }
        }
        .onAppear { model.reload() }
    }
}

struct MeetingDetailView: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(meeting.title).font(.title2).bold()
            Text(meeting.createdAt, style: .date)
                .foregroundStyle(.secondary)
            Divider()
            Text("Notes, transcript, and chat tabs arrive in Phases 1–4.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
