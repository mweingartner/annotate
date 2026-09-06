import AnnotateCore
import AppKit
import SwiftUI

struct AssistantAnswerCard: View {
    let answer: DocumentAssistantAnswer
    let goToPage: (Int) -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: answer.title).font(.headline).textSelection(.enabled)
            if let generatedBy = answer.generatedBy {
                Text(generatedBy).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text(displayedAnswer).lineSpacing(3).textSelection(.enabled)
            HStack {
                Text("Sources").font(.subheadline.bold())
                Spacer()
                if answer.isGenerated {
                    Button(copied ? "Copied" : "Copy answer", systemImage: copied ? "checkmark" : "doc.on.doc", action: copy)
                        .buttonStyle(.borderless).font(.caption)
                }
            }
            AssistantSourcePages(sources: answer.sources, goToPage: goToPage)
            DisclosureGroup("Read \(answer.sources.count) original passages") {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(answer.sources) { source in AssistantSourceRow(source: source, goToPage: goToPage) }
                }.padding(.top, 8)
            }
            DisclosureGroup("How this answer was made") {
                Text(answer.coverage).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
            if answer.isGenerated {
                Text("Check important details against the original pages.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
        .onChange(of: answer.id) { _, _ in copied = false }
    }

    private var displayedAnswer: AttributedString {
        var text = (try? AttributedString(markdown: answer.content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(answer.content)
        // Model output can format prose but cannot invent navigation actions.
        // Verified document pages remain available through the source buttons.
        for run in text.runs where run.link != nil { text[run.range].link = nil }
        return text
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer.content, forType: .string)
        copied = true
    }
}
