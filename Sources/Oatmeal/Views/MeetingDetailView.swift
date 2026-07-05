import SwiftUI

struct MeetingDetailView: View {
    let meeting: Meeting
    @EnvironmentObject var recorder: RecordingController
    @State private var storedSegments: [TranscriptSegment] = []

    private var isActive: Bool {
        recorder.isRecording && recorder.activeMeeting?.id == meeting.id
    }

    private var segments: [TranscriptSegment] {
        isActive ? recorder.liveSegments : storedSegments
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title).font(.title2).bold()
                HStack(spacing: 8) {
                    Text(meeting.createdAt, format: .dateTime.weekday().month().day().hour().minute())
                    if isActive {
                        Label("Recording", systemImage: "record.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            if segments.isEmpty && !isActive {
                ContentUnavailableView(
                    "No transcript",
                    systemImage: "waveform",
                    description: Text("This meeting has no transcript segments.")
                )
            } else {
                transcriptList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { loadIfNeeded() }
        .onChange(of: recorder.isRecording) { _, nowRecording in
            if !nowRecording { loadIfNeeded(force: true) }
        }
        .onChange(of: meeting.id) { _, _ in loadIfNeeded(force: true) }
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

    private func loadIfNeeded(force: Bool = false) {
        guard force || !isActive else { return }
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
