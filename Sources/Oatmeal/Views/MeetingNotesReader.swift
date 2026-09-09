import SwiftUI

struct MeetingNotesReader: View {
    @Binding var markdown: String
    let onSave: () -> Void

    var body: some View {
        let document = NotesDocument(markdown)
        GeometryReader { geometry in
            ScrollView {
                if geometry.size.width >= 700 && !document.followUps.isEmpty {
                    HStack(alignment: .top, spacing: 28) {
                        readingColumn(document)
                        followUps(document).frame(width: 220)
                    }
                    .padding(24)
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        if !document.followUps.isEmpty {
                            DisclosureGroup("Follow-ups · \(document.followUps.filter { !$0.done }.count) open") {
                                followUps(document).padding(.top, 12)
                            }
                            .font(.system(size: 13, weight: .semibold))
                        }
                        readingColumn(document)
                    }
                    .padding(24)
                }
            }
        }
    }

    private func readingColumn(_ document: NotesDocument) -> some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(document.blocks) { block in
                switch block.kind {
                case .heading(let level):
                    Text(inline(block.text))
                        .font(.system(size: level == 1 ? 23 : 16, weight: .bold, design: .rounded))
                        .padding(.top, block.id == document.blocks.first?.id ? 0 : 14)
                        .accessibilityAddTraits(.isHeader)
                case .bullet:
                    HStack(alignment: .top, spacing: 10) {
                        Text("·").foregroundStyle(OatmealStyle.accent)
                        Text(inline(block.text)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .code:
                    Text(block.text).font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8).background(OatmealStyle.paper)
                case .paragraph:
                    Text(inline(block.text)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.system(size: 14))
        .lineSpacing(5)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func followUps(_ document: NotesDocument) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            OatmealSectionLabel(title: "Follow-ups · \(document.followUps.count)")
            ForEach(document.followUps) { item in
                HStack(alignment: .top, spacing: 9) {
                    Button {
                        markdown = NotesDocument.toggling(item, in: markdown)
                        onSave()
                    } label: {
                        Image(systemName: item.done ? "checkmark.square.fill" : "square")
                            .foregroundStyle(OatmealStyle.accent)
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.done ? "Mark incomplete" : "Complete"): \(item.text)")
                    Text(inline(item.text))
                        .strikethrough(item.done)
                        .foregroundStyle(item.done ? OatmealStyle.muted : OatmealStyle.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 13))
                .lineSpacing(3)
            }
        }
        .padding(18)
        .background(OatmealStyle.paper, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(OatmealStyle.line, lineWidth: 1) }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
