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
    @EnvironmentObject var recorder: RecordingController

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                if model.meetings.isEmpty {
                    Text("No meetings yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.meetings) { meeting in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meeting.title)
                                    .lineLimit(1)
                                Text(meeting.createdAt, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if recorder.isRecording && recorder.activeMeeting?.id == meeting.id {
                                Spacer()
                                Image(systemName: "record.circle.fill")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            }
                        }
                        .tag(meeting.id)
                        .contextMenu {
                            Button("Delete Meeting", role: .destructive) {
                                deleteMeeting(meeting)
                            }
                            .disabled(recorder.isRecording && recorder.activeMeeting?.id == meeting.id)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .navigationTitle("Meetings")
        } detail: {
            if let id = model.selection,
               let meeting = model.meetings.first(where: { $0.id == id }) {
                MeetingDetailView(meeting: meeting)
                    .id(meeting.id) // fresh notes state per meeting
            } else {
                ContentUnavailableView(
                    "Select a meeting",
                    systemImage: "text.bubble",
                    description: Text("Press Record to capture a meeting, or set API keys in Settings (⌘,).")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                if recorder.isRecording && !recorder.connectionStatus.isEmpty {
                    Text(recorder.connectionStatus)
                        .font(.caption)
                        .foregroundStyle(recorder.connectionStatus == "Live" ? .green : .orange)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    recorder.toggle()
                } label: {
                    if recorder.isRecording {
                        Label("Stop", systemImage: "stop.circle.fill")
                            .foregroundStyle(.red)
                    } else {
                        Label("Record", systemImage: "record.circle")
                    }
                }
                .help(recorder.isRecording ? "Stop recording" : "Start recording a meeting")
            }
        }
        .onAppear { model.reload() }
        .onChange(of: recorder.activeMeeting?.id) { _, newValue in
            model.reload()
            if let newValue { model.selection = newValue }
        }
        .onChange(of: recorder.isRecording) { _, _ in
            model.reload()
        }
        .alert("Recording", isPresented: Binding(
            get: { recorder.lastError != nil },
            set: { if !$0 { recorder.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recorder.lastError ?? "")
        }
    }

    private func deleteMeeting(_ meeting: Meeting) {
        // Deleting cascades to transcript segments, notes, and chats (FK).
        try? Store.shared.delete(meeting)
        if let path = meeting.audioFilePath {
            try? FileManager.default.removeItem(atPath: path)
        }
        if model.selection == meeting.id { model.selection = nil }
        model.reload()
    }
}
