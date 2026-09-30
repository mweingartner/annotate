import AnnotateCore
import AppKit
import Atrium
import SwiftUI

/// One answer: what was asked, the reply, and the pages and passages it came from. The
/// panel raises only the latest answer on a surface; earlier ones sit between hairlines.
struct AssistantAnswerCard: View {
    let answer: DocumentAssistantAnswer
    let goToPage: (Int) -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.control) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(verbatim: answer.title).font(Typography.heading).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let generatedBy = answer.generatedBy {
                    Text(generatedBy).font(Typography.meta).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Text(displayedAnswer).font(Typography.body).lineSpacing(Spacing.hair).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader("Sources") {
                    if answer.isGenerated {
                        Button(copied ? "Copied" : "Copy answer", systemImage: copied ? "checkmark" : "doc.on.doc", action: copy)
                            .buttonStyle(.quiet)
                    }
                }
                AssistantSourcePages(sources: answer.sources, goToPage: goToPage)
            }
            DisclosureGroup("Read \(answer.sources.count) original passages") {
                AssistantSourceList(sources: answer.sources, goToPage: goToPage)
                    .padding(.top, Spacing.snug)
            }
            DisclosureGroup("How this answer was made") {
                Text(answer.coverage).font(Typography.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.snug)
            }
            if answer.isGenerated {
                Text("Check important details against the original pages.")
                    .font(Typography.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
