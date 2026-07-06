import SwiftUI
import AppKit

struct MeetingDetailView: View {
    let meeting: Meeting
    @EnvironmentObject var recorder: RecordingController
    @StateObject private var notes: NotesModel
    @State private var storedSegments: [TranscriptSegment] = []
    @State private var tab: Tab = .notes
    @State private var copied = false

    enum Tab: String, CaseIterable, Identifiable {
        case notes = "Notes"
        case transcript = "Transcript"
        case myNotes = "My Notes"
        var id: String { rawValue }
    }

    init(meeting: Meeting) {
        self.meeting = meeting
        _notes = StateObject(wrappedValue: NotesModel(meeting: meeting))
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
        .onDisappear { notes.flush() }
        .onChange(of: recorder.isRecording) { _, nowRecording in
            if nowRecording {
                if recorder.activeMeeting?.id == meeting.id { tab = .myNotes }
            } else {
                loadSegments()
                // Auto-enhance the meeting that just finished recording.
                if recorder.activeMeeting?.id == meeting.id {
                    tab = .notes
                    notes.enhance()
                }
            }
        }

    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(meeting.title).font(.title2).bold()
                if isActive {
                    Label("Recording", systemImage: "record.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                Spacer()
                Text(meeting.createdAt, format: .dateTime.weekday().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                transcriptList
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
                        TranscriptRow(speaker: segment.speaker, text: segment.text,
                                      time: segment.startTime, isInterim: false)
                    }
                    if isActive {
                        ForEach([0, 1], id: \.self) { channel in
                            if let text = recorder.interim[channel], !text.isEmpty {
                                TranscriptRow(speaker: channel == 0 ? "me" : "them", text: text,
                                              time: nil, isInterim: true)
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

    // MARK: - Actions

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
    let speaker: String
    let text: String
    let time: Double?
    let isInterim: Bool

    private var speakerLabel: String { speaker == "me" ? "Me" : "Them" }
    private var speakerColor: Color { speaker == "me" ? .blue : .purple }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(speakerLabel)
                .font(.caption.bold())
                .foregroundStyle(speakerColor)
                .frame(width: 44, alignment: .trailing)
            Text(text)
                .textSelection(.enabled)
                .opacity(isInterim ? 0.5 : 1)
            Spacer(minLength: 0)
            if let time {
                Text(Self.timestamp(time))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
