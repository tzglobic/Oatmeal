import SwiftUI
import AppKit

struct MeetingDetailView: View {
    let meeting: Meeting
    @EnvironmentObject var recorder: RecordingController
    @StateObject private var notes: NotesModel
    @StateObject private var playback: PlaybackModel
    @State private var storedSegments: [TranscriptSegment] = []
    @State private var tab: Tab = .notes
    @State private var copied = false
    @State private var editedTitle: String
    @State private var speakerNames: [String: String]
    @State private var isRetranscribing = false
    @State private var renameSpeakerKey: String?
    @State private var renameSpeakerText = ""

    enum Tab: String, CaseIterable, Identifiable {
        case notes = "Notes"
        case transcript = "Transcript"
        case myNotes = "My Notes"
        var id: String { rawValue }
    }

    init(meeting: Meeting) {
        self.meeting = meeting
        _notes = StateObject(wrappedValue: NotesModel(meeting: meeting))
        _playback = StateObject(wrappedValue: PlaybackModel(path: meeting.audioFilePath))
        _editedTitle = State(initialValue: meeting.title)
        _speakerNames = State(initialValue: meeting.speakerNameMap)
    }

    private var isActive: Bool {
        recorder.isRecording && recorder.activeMeeting?.id == meeting.id
    }

    private var segments: [TranscriptSegment] {
        isActive ? recorder.liveSegments : storedSegments
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            loadSegments()
            if isActive { tab = .myNotes }
            else if notes.enhancedNotes.isEmpty && !segments.isEmpty { tab = .transcript }
        }
        .onDisappear {
            notes.flush()
            playback.pause()
            saveTitle()
        }
        .onChange(of: meeting.title) { _, newValue in
            editedTitle = newValue
        }
        .onChange(of: meeting.speakerNames) { _, _ in
            speakerNames = meeting.speakerNameMap
        }
        .onChange(of: recorder.isRecording) { _, nowRecording in
            if nowRecording {
                if recorder.activeMeeting?.id == meeting.id {
                    tab = .myNotes
                    playback.pause()
                }
            } else {
                loadSegments()
                // Auto-enhance the meeting that just finished recording.
                if recorder.activeMeeting?.id == meeting.id {
                    tab = .notes
                    notes.enhance()
                }
            }
        }
        .alert("Rename Speaker", isPresented: Binding(
            get: { renameSpeakerKey != nil },
            set: { if !$0 { renameSpeakerKey = nil } }
        )) {
            TextField("Name", text: $renameSpeakerText)
            Button("Save") { commitSpeakerRename() }
            Button("Cancel", role: .cancel) { renameSpeakerKey = nil }
        } message: {
            Text("Give this speaker a name. Leave empty to reset.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Meeting title", text: $editedTitle)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                    .onSubmit { saveTitle() }
                if isActive {
                    Label(recorder.isPaused ? "Paused" : "Recording",
                          systemImage: recorder.isPaused ? "pause.circle.fill" : "record.circle.fill")
                        .foregroundStyle(recorder.isPaused ? .orange : .red)
                        .font(.caption)
                        .fixedSize()
                }
                Text(meeting.createdAt, format: .dateTime.weekday().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            HStack(spacing: 10) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { t in Text(t.rawValue).tag(t) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                Spacer()

                Picker("Template", selection: $notes.template) {
                    ForEach(NoteTemplate.allCases) { t in Text(t.displayName).tag(t) }
                }
                .frame(maxWidth: 160)
                .help("Enhancement style used when generating notes")

                if notes.isEnhancing {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        notes.enhance()
                    } label: {
                        Label(notes.enhancedNotes.isEmpty ? "Enhance" : "Re-enhance",
                              systemImage: "sparkles")
                    }
                    .disabled(!notes.canEnhance || isActive)
                    .help("Merge your notes and the transcript into polished notes with AI")
                }

                Button {
                    copyCurrentTab()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copy this tab's content to the clipboard")

                Menu {
                    Button("Re-transcribe from Audio") { retranscribe() }
                        .disabled(isActive || isRetranscribing || !playback.available)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
            }

            if isRetranscribing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Re-transcribing from the meeting recording…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = notes.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .notes:
            if notes.isEnhancing {
                ContentUnavailableView {
                    ProgressView()
                } description: {
                    Text("Enhancing notes with AI…")
                }
            } else if notes.enhancedNotes.isEmpty {
                ContentUnavailableView(
                    "No enhanced notes yet",
                    systemImage: "sparkles",
                    description: Text("Press Enhance to merge your notes and the transcript into polished meeting notes.")
                )
            } else {
                editor(text: $notes.enhancedNotes)
            }
        case .transcript:
            if segments.isEmpty && !isActive {
                ContentUnavailableView(
                    "No transcript",
                    systemImage: "waveform",
                    description: Text("This meeting has no transcript segments.")
                )
            } else {
                VStack(spacing: 0) {
                    if playback.available && !isActive {
                        playbackBar
                        Divider()
                    }
                    transcriptList
                }
            }
        case .myNotes:
            ZStack(alignment: .topLeading) {
                editor(text: $notes.userNotes)
                if notes.userNotes.isEmpty {
                    Text(isActive ? "Type rough notes while the meeting runs — the AI folds them into the polished notes."
                                  : "Your raw notes for this meeting.")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 21)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var playbackBar: some View {
        HStack(spacing: 10) {
            Button {
                playback.toggle()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .help("Play the meeting recording — click any line to jump there")

            Text("\(PlaybackModel.timeString(playback.currentTime)) / \(PlaybackModel.timeString(playback.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(value: Binding(
                get: { playback.currentTime },
                set: { playback.seek(to: $0) }
            ), in: 0...max(playback.duration, 0.1))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func editor(text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(segments) { segment in
                        TranscriptRow(speakerLabel: displayName(for: segment.speaker),
                                      speakerColor: speakerColor(segment.speaker),
                                      text: segment.text,
                                      time: segment.startTime,
                                      isInterim: false,
                                      isCurrent: playback.isCurrent(start: segment.startTime,
                                                                    end: segment.endTime))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard playback.available, !isActive else { return }
                                playback.seek(to: segment.startTime)
                            }
                            .contextMenu {
                                if segment.speaker != "me" {
                                    Button("Rename Speaker…") {
                                        renameSpeakerText = speakerNames[segment.speaker] ?? ""
                                        renameSpeakerKey = segment.speaker
                                    }
                                }
                            }
                    }
                    if isActive {
                        ForEach([0, 1], id: \.self) { channel in
                            if let text = recorder.interim[channel], !text.isEmpty {
                                TranscriptRow(speakerLabel: channel == 0 ? "Me" : "Them",
                                              speakerColor: channel == 0 ? .blue : .purple,
                                              text: text, time: nil,
                                              isInterim: true, isCurrent: false)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                }
                .padding()
            }
            .onChange(of: segments.count) { _, _ in
                if isActive { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
        }
    }

    // MARK: - Speakers

    private func displayName(for key: String) -> String {
        if key == "me" { return "Me" }
        if let custom = speakerNames[key], !custom.isEmpty { return custom }
        if key == "them" { return "Them" }
        if key.hasPrefix("them"), let n = Int(key.dropFirst(4)) { return "Them \(n + 1)" }
        return key
    }

    private func speakerColor(_ key: String) -> Color {
        if key == "me" { return .blue }
        let palette: [Color] = [.purple, .orange, .teal, .pink]
        if key.hasPrefix("them"), let n = Int(key.dropFirst(4)) {
            return palette[n % palette.count]
        }
        return .purple
    }

    private func commitSpeakerRename() {
        guard let key = renameSpeakerKey else { return }
        try? Store.shared.updateSpeakerName(meetingId: meeting.id, key: key, name: renameSpeakerText)
        speakerNames = (try? Store.shared.meeting(id: meeting.id))?.speakerNameMap ?? speakerNames
        renameSpeakerKey = nil
        NotificationCenter.default.post(name: .meetingChanged, object: nil)
    }

    // MARK: - Actions

    private func saveTitle() {
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != meeting.title else {
            editedTitle = meeting.title
            return
        }
        try? Store.shared.updateTitle(meetingId: meeting.id, title: trimmed)
        NotificationCenter.default.post(name: .meetingChanged, object: nil)
    }

    private func retranscribe() {
        guard let path = meeting.audioFilePath else { return }
        isRetranscribing = true
        notes.errorMessage = nil
        Task {
            do {
                let utterances = try await TranscriptionService.retranscribe(
                    fileURL: URL(fileURLWithPath: path))
                let replacement = utterances.map { u in
                    TranscriptSegment(
                        id: nil, meetingId: meeting.id,
                        speaker: speakerKey(channel: u.channel, speakerIndex: u.speakerIndex),
                        text: u.text, startTime: u.start, endTime: u.end, isFinal: true)
                }
                try Store.shared.replaceSegments(for: meeting.id, with: replacement)
                loadSegments()
                tab = .transcript
            } catch {
                notes.errorMessage = error.localizedDescription
            }
            isRetranscribing = false
        }
    }

    private func copyCurrentTab() {
        let text: String
        switch tab {
        case .notes: text = notes.enhancedNotes
        case .transcript: text = NotesModel.transcriptText(segments)
        case .myNotes: text = notes.userNotes
        }
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func loadSegments() {
        storedSegments = (try? Store.shared.segments(for: meeting.id)) ?? []
    }
}

struct TranscriptRow: View {
    let speakerLabel: String
    let speakerColor: Color
    let text: String
    let time: Double?
    let isInterim: Bool
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(speakerLabel)
                .font(.caption.bold())
                .foregroundStyle(speakerColor)
                .frame(width: 70, alignment: .trailing)
                .lineLimit(1)
            Text(text)
                .textSelection(.enabled)
                .opacity(isInterim ? 0.5 : 1)
            Spacer(minLength: 0)
            if let time {
                Text(PlaybackModel.timeString(time))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
    }
}
