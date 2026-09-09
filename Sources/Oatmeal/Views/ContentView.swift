import SwiftUI

final class MeetingListModel: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var displayed: [Meeting] = []
    @Published var selection: String?
    @Published var searchText: String = "" {
        didSet { applySearch() }
    }

    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .meetingChanged, object: nil, queue: .main) { [weak self] _ in
                self?.reload()
            }
    }

    func reload() {
        meetings = (try? Store.shared.allMeetings()) ?? []
        applySearch()
    }

    private func applySearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            displayed = meetings
        } else {
            displayed = (try? Store.shared.searchMeetings(query)) ?? []
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: MeetingListModel
    @EnvironmentObject var recorder: RecordingController
    @ObservedObject private var calendar = CalendarService.shared
    @ObservedObject private var endDetector = MeetingEndDetector.shared
    @State private var renameTarget: Meeting?
    @State private var renameText = ""

    static let actionItemsID = "__action_items__"

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .tint(OatmealStyle.accent)
        .foregroundStyle(OatmealStyle.ink)
        .background(OatmealStyle.paper)
        .safeAreaInset(edge: .top) { meetingEndedBanner }
        .onAppear {
            model.reload()
            if model.selection == nil { model.selection = model.meetings.first?.id }
            Task { await CalendarService.shared.requestAccessAndStart() }
        }
        .onChange(of: recorder.activeMeeting?.id) { _, newValue in
            model.reload()
            if let newValue { model.selection = newValue }
        }
        .onChange(of: recorder.isRecording) { _, _ in
            model.reload()
        }
        .alert("Oatmeal", isPresented: Binding(
            get: { recorder.lastError != nil },
            set: { if !$0 { recorder.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recorder.lastError ?? "")
        }
        .alert("Recording Warning", isPresented: Binding(
            get: { recorder.warning != nil },
            set: { if !$0 { recorder.warning = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recorder.warning ?? "")
        }
        .alert("Rename Meeting", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Title", text: $renameText)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $model.selection) {
            if model.searchText.isEmpty {
                Label("Action Items", systemImage: "checklist")
                    .tag(Self.actionItemsID)
            }
            if model.searchText.isEmpty && calendar.hasAccess && !calendar.upcoming.isEmpty {
                Section("Up Next") {
                    ForEach(calendar.upcoming.prefix(6)) { event in
                        UpcomingMeetingRow(
                            meeting: event,
                            recordDisabled: recorder.state != .idle,
                            record: { Task { await recorder.start(calendarMeeting: event) } })
                            .selectionDisabled()
                    }
                }
            }
            if model.displayed.isEmpty {
                Section("Meetings") {
                    Text(model.searchText.isEmpty ? "No meetings yet" : "No matches")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(meetingGroups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.meetings) { meeting in
                            meetingRow(meeting)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(OatmealStyle.paper)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        .navigationTitle("Oatmeal")
        .searchable(text: $model.searchText, placement: .sidebar,
                    prompt: "Search meetings, transcripts, notes")
    }

    private var meetingGroups: [(title: String, meetings: [Meeting])] {
        MeetingTimeline.groups(model.displayed, date: \.createdAt, searching: !model.searchText.isEmpty)
    }

    private func meetingRow(_ meeting: Meeting) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(meeting.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .help(meeting.title)
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
        .padding(.vertical, 7)
        .listRowBackground(model.selection == meeting.id ? OatmealStyle.selection : Color.clear)
        .tag(meeting.id)
        .contextMenu {
            Button("Rename…") {
                renameText = meeting.title
                renameTarget = meeting
            }
            Divider()
            Button("Delete Meeting", role: .destructive) {
                deleteMeeting(meeting)
            }
            .disabled(recorder.isRecording && recorder.activeMeeting?.id == meeting.id)
        }
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(spacing: 0) {
            captureBar
            Divider()
            meetingContent
        }
        .background(OatmealStyle.panel)
    }

    @ViewBuilder
    private var meetingContent: some View {
        if model.selection == Self.actionItemsID {
            ActionItemsView { meetingId in
                model.selection = meetingId
            }
        } else if let id = model.selection,
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

    // MARK: - Toolbar

    /// Asks the same question as the notification, in case that was missed or
    /// dismissed — the countdown is live so it's obvious how long is left.
    @ViewBuilder
    private var meetingEndedBanner: some View {
        if let pending = endDetector.pending {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Still recording — has this meeting ended?")
                        .font(.headline)
                    Text("Oatmeal thinks the call is over — \(pending.trigger.summary).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(pending.deadline.timeIntervalSince(context.date).rounded()))
                    Text("Stopping in \(remaining)s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button("Keep Recording") { endDetector.keepRecording() }
                Button("Stop & Save") { endDetector.stopNow() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.orange.opacity(0.15))
            .overlay(alignment: .bottom) { Divider() }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var recordingStatus: String {
        switch recorder.state {
        case .idle: "Not recording"
        case .starting: "Starting recording…"
        case .recording: recorder.isPaused ? "Recording paused" : "Recording"
        case .stopping: "Saving recording…"
        }
    }

    private var captureBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Label(recordingStatus,
                      systemImage: recorder.isRecording ? "record.circle.fill" : "waveform.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(recorder.isRecording ? Color.red : OatmealStyle.muted)
                Spacer(minLength: 8)
                SettingsLink { Image(systemName: "gearshape") }
                    .help("Recording permissions and API keys")
                    .accessibilityLabel("Settings")
                if recorder.isRecording {
                    Button(recorder.isPaused ? "Resume" : "Pause") { recorder.togglePause() }
                        .disabled(recorder.isTransitioning)
                }
                Button {
                    recorder.toggle()
                } label: {
                    Label(recorder.isTransitioning ? recordingStatus : recorder.isRecording ? "Stop & Save" : "Start recording",
                          systemImage: recorder.isRecording ? "stop.fill" : "record.circle")
                }
                .disabled(recorder.isTransitioning)
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? .red : OatmealStyle.accent)
            }
            if recorder.isRecording {
                HStack(spacing: 12) {
                    LevelMeter(label: "Mic", level: recorder.micLevel)
                    LevelMeter(label: "System", level: recorder.systemLevel)
                    if let start = recorder.recordingStart {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Self.elapsedString(from: start, to: context.date))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !recorder.connectionStatus.isEmpty {
                        Text(recorder.connectionStatus)
                            .font(.caption)
                            .foregroundStyle(recorder.connectionStatus == "Live" ? .green : .orange)
                    }
                    if let active = recorder.activeMeeting, model.selection != active.id {
                        Button("Open recording") { model.selection = active.id }
                            .buttonStyle(.link)
                            .help(active.title)
                    }
                }
            } else {
                Text("Capture meeting audio and turn it into useful notes.")
                    .font(.caption)
                    .foregroundStyle(OatmealStyle.muted)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(OatmealStyle.paper)
    }

    private static func elapsedString(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Actions

    private func commitRename() {
        guard let meeting = renameTarget else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard !trimmed.isEmpty, trimmed != meeting.title else { return }
        do {
            try Store.shared.updateTitle(meetingId: meeting.id, title: trimmed)
            model.reload()
        } catch { recorder.lastError = "Couldn't rename the meeting: \(error.localizedDescription)" }
    }

    private func deleteMeeting(_ meeting: Meeting) {
        // Deleting cascades to transcript segments, notes, and chats (FK).
        do {
            try Store.shared.delete(meeting)
        } catch {
            recorder.lastError = "Couldn't delete the meeting: \(error.localizedDescription)"
            return // Do not remove recoverable audio if the database operation failed.
        }
        if let path = meeting.audioFilePath, FileManager.default.fileExists(atPath: path) {
            do { try FileManager.default.removeItem(atPath: path) }
            catch { recorder.lastError = "The meeting was deleted, but its audio file could not be removed: \(error.localizedDescription)" }
        }
        if model.selection == meeting.id { model.selection = nil }
        model.reload()
    }
}

/// Calendar event row in the "Up Next" sidebar section, with Join and Record.
struct UpcomingMeetingRow: View {
    let meeting: UpcomingMeeting
    let recordDisabled: Bool
    let record: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(meeting.title).lineLimit(1)
                    if meeting.isNow {
                        Text("Now")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red.opacity(0.18)))
                            .foregroundStyle(.red)
                    }
                }
                HStack(spacing: 4) {
                    Text("\(meeting.start.formatted(date: .omitted, time: .shortened))–\(meeting.end.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let provider = meeting.provider {
                        Text(provider)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.blue.opacity(0.15)))
                            .foregroundStyle(.blue)
                    }
                }
            }
            Spacer(minLength: 0)
            if let url = meeting.callURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "video")
                }
                .buttonStyle(.borderless)
                .help("Join the \(meeting.provider ?? "video") call")
            }
            Button(action: record) {
                Image(systemName: "record.circle")
            }
            .buttonStyle(.borderless)
            .disabled(recordDisabled)
            .help("Record this meeting")
        }
    }
}

/// Tiny live audio level bar shown in the toolbar while recording, so silent
/// capture failures are visible at a glance.
struct LevelMeter: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 50, height: 6)
                Capsule()
                    .fill(level > 0.02 ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: max(2, 50 * CGFloat(min(level, 1))), height: 6)
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
        .help("\(label) audio level — if this never moves, that source isn't being captured")
    }
}
