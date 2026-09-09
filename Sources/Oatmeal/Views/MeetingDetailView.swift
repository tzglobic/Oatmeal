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
    @State private var showSpeakersSheet = false
    @State private var isEditingNotes = false

    enum Tab: String, CaseIterable, Identifiable {
        case notes = "Notes"
        case transcript = "Transcript"
        case myNotes = "Scratchpad"
        var id: String { rawValue }
    }

    init(meeting: Meeting) {
        self.meeting = meeting
        _notes = StateObject(wrappedValue: NotesModel.shared(for: meeting))
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

    private var audioFileExists: Bool {
        guard let path = meeting.audioFilePath else { return false }
        return FileManager.default.fileExists(atPath: path)
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
                if recorder.activeMeeting?.id == meeting.id {
                    // The .m4a is finalized now — make playback pick it up.
                    playback.load(path: meeting.audioFilePath)
                    // RecordingController starts enhancement even without this view.
                    tab = .notes
                }
            }
        }
        .sheet(isPresented: $showSpeakersSheet) {
            SpeakersSheet(meetingId: meeting.id, attendees: meeting.attendeesList) {
                speakerNames = (try? Store.shared.meeting(id: meeting.id))?.speakerNameMap ?? speakerNames
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
        VStack(alignment: .leading, spacing: 14) {
            OatmealSectionLabel(title: "Meeting notes")
            HStack(spacing: 8) {
                TextField("Meeting title", text: $editedTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .accessibilityLabel("Meeting title")
                    .onSubmit { saveTitle() }
                if isActive {
                    Label(recorder.isPaused ? "Paused" : "Recording",
                          systemImage: recorder.isPaused ? "pause.circle.fill" : "record.circle.fill")
                        .foregroundStyle(recorder.isPaused ? .orange : .red)
                        .font(.caption)
                        .fixedSize()
                }
            }

            HStack(spacing: 8) {
                Text(meeting.createdAt, format: .dateTime.weekday().month().day().hour().minute())
                if let ended = meeting.endedAt {
                    Text("·")
                    Text(PlaybackModel.timeString(max(0, ended.timeIntervalSince(meeting.createdAt))))
                }
            }
            .font(.caption)
            .foregroundStyle(OatmealStyle.muted)

            if !meeting.attendeesList.isEmpty {
                Label(meeting.attendeesList.joined(separator: ", "), systemImage: "person.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(meeting.attendeesList.joined(separator: "\n"))
            }

            HStack(spacing: 20) {
                ForEach(Tab.allCases) { t in
                    Button {
                        tab = t
                    } label: {
                        Text(t.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tab == t ? OatmealStyle.ink : OatmealStyle.muted)
                            .padding(.vertical, 10)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(tab == t ? OatmealStyle.accent : .clear).frame(height: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == t ? .isSelected : [])
                }
                Spacer()
                Button {
                    copyCurrentTab()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copy this tab's content to the clipboard")

                Menu {
                    Button("Speakers…") { showSpeakersSheet = true }
                        .disabled(isActive)
                    Button("Re-transcribe from Audio") { retranscribe() }
                        .disabled(isActive || isRetranscribing || !audioFileExists)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
                .accessibilityLabel("Meeting options")
            }

            if tab == .notes {
                ViewThatFits(in: .horizontal) {
                    HStack { noteActions }
                    VStack(alignment: .leading, spacing: 8) { noteActions }
                }
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
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var noteActions: some View {
        Picker("Template", selection: $notes.template) {
            ForEach(NoteTemplate.allCases) { t in Text(t.displayName).tag(t) }
        }
        .frame(width: 180)
        .disabled(notes.isEnhancing)
        Spacer(minLength: 8)
        if !notes.enhancedNotes.isEmpty && !notes.isEnhancing {
            Button(isEditingNotes ? "Done" : "Edit notes") {
                isEditingNotes.toggle()
                if !isEditingNotes { notes.flush() }
            }
        }
        Button {
            isEditingNotes = false
            notes.enhance()
        } label: {
            Label(notes.isEnhancing ? "Generating…" : notes.enhancedNotes.isEmpty ? "Generate notes" : "Regenerate",
                  systemImage: "sparkles")
        }
        .disabled(!notes.canEnhance || isActive)
        .help("Generate notes from your scratchpad and transcript using the selected template")
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
                    description: Text("Generate notes to turn your scratchpad and transcript into a summary, decisions, and follow-ups.")
                )
            } else {
                if isEditingNotes {
                    editor(text: $notes.enhancedNotes)
                        .accessibilityLabel("Edit meeting notes (Markdown)")
                } else {
                    MeetingNotesReader(markdown: $notes.enhancedNotes, onSave: { notes.flush() })
                        .disabled(!notes.canEdit)
                }
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
            VStack(alignment: .leading, spacing: 0) {
                Text("Your rough notes · included when generating meeting notes")
                    .font(.caption)
                    .foregroundStyle(OatmealStyle.muted)
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
            ZStack(alignment: .topLeading) {
                editor(text: $notes.userNotes)
                    .accessibilityLabel("Scratchpad")
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
            .foregroundStyle(OatmealStyle.accent)
            .accessibilityLabel(playback.isPlaying ? "Pause audio" : "Play audio")
            .help("Play the meeting recording — click any line to jump there")

            Text("\(PlaybackModel.timeString(playback.currentTime)) / \(PlaybackModel.timeString(playback.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(value: Binding(
                get: { playback.currentTime },
                set: { playback.seek(to: $0) }
            ), in: 0...max(playback.duration, 0.1))
            .accessibilityLabel("Recording position")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(OatmealStyle.paper)
    }

    private func editor(text: Binding<String>) -> some View {
        TextEditor(text: text)
            .disabled(!notes.canEdit)
            .font(.system(size: 14))
            .lineSpacing(5)
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
                                                                    end: segment.endTime),
                                      onSpeakerTap: segment.speaker == "me" ? nil : {
                                          renameSpeakerText = speakerNames[segment.speaker] ?? ""
                                          renameSpeakerKey = segment.speaker
                                      },
                                      onSeek: playback.available && !isActive ? {
                                          playback.seek(to: segment.startTime)
                                      } : nil)
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
                                    Button("All Speakers…") { showSpeakersSheet = true }
                                }
                            }
                    }
                    if isActive {
                        ForEach([0, 1], id: \.self) { channel in
                            if let text = recorder.interim[channel], !text.isEmpty {
                                TranscriptRow(speakerLabel: channel == 0 ? "Me" : "Them",
                                              speakerColor: channel == 0 ? .blue : .purple,
                                              text: text, time: nil,
                                              isInterim: true, isCurrent: false,
                                              onSpeakerTap: nil)
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
        speakerDisplayName(key: key, names: speakerNames)
    }

    private func speakerColor(_ key: String) -> Color {
        if key == "me" { return OatmealStyle.accent }
        let palette: [Color] = [.purple, .orange, .teal, .pink]
        // n is a diarization index and should never be negative, but a negative
        // modulo here would be an out-of-bounds trap rather than a wrong colour.
        if key.hasPrefix("them"), let n = Int(key.dropFirst(4)), n >= 0 {
            return palette[n % palette.count]
        }
        return .purple
    }

    private func commitSpeakerRename() {
        guard let key = renameSpeakerKey else { return }
        do {
            try Store.shared.updateSpeakerName(meetingId: meeting.id, key: key, name: renameSpeakerText)
        } catch {
            notes.errorMessage = "Couldn't save the speaker name: \(error.localizedDescription)"
            return
        }
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
        do { try Store.shared.updateTitle(meetingId: meeting.id, title: trimmed) }
        catch {
            notes.errorMessage = "Couldn't save the title: \(error.localizedDescription)"
            return
        }
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
        case .transcript: text = NotesModel.transcriptText(segments, names: speakerNames)
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
    var onSpeakerTap: (() -> Void)?
    var onSeek: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let time {
                Group {
                    if let onSeek {
                        Button(PlaybackModel.timeString(time), action: onSeek)
                            .buttonStyle(.plain)
                            .accessibilityLabel("Jump to \(PlaybackModel.timeString(time))")
                    } else {
                        Text(PlaybackModel.timeString(time))
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(OatmealStyle.muted)
                .frame(width: 50, alignment: .leading)
            }
            Group {
                if let onSpeakerTap {
                    Button(action: onSpeakerTap) {
                        Text(speakerLabel).underline(pattern: .dot)
                    }
                    .buttonStyle(.plain)
                    .help("Click to rename this speaker")
                } else {
                    Text(speakerLabel)
                }
            }
            .font(.caption.bold())
            .foregroundStyle(speakerColor)
            .frame(width: 90, alignment: .leading)
            .lineLimit(1)
            .truncationMode(.tail)
            Text(text)
                .font(.system(size: 14))
                .lineSpacing(4)
                .textSelection(.enabled)
                .opacity(isInterim ? 0.5 : 1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(isCurrent ? OatmealStyle.selection : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }
}
