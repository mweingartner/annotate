import AnnotateCore
import Atrium
import SwiftUI

/// One original passage behind an answer: a link to its page, a preview, and the full text.
struct AssistantSourceRow: View {
    let source: DocumentAssistantSource
    let goToPage: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Button(source.label, systemImage: "doc.text.magnifyingglass") { goToPage(source.pageNumber) }
                .buttonStyle(.link).accessibilityHint("Opens the original PDF page")
            Text(verbatim: source.text).font(Typography.supporting).foregroundStyle(.secondary).lineLimit(3)
            DisclosureGroup("Full passage") {
                Text(verbatim: source.text)
                    .font(Typography.supporting).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.tight)
            }
            .font(Typography.meta)
        }
        .padding(.vertical, Spacing.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Source passages as rows separated by hairlines, shared by the request review and answers.
struct AssistantSourceList: View {
    let sources: [DocumentAssistantSource]
    let goToPage: (Int) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                if index > 0 { Hairline() }
                AssistantSourceRow(source: source, goToPage: goToPage)
            }
        }
    }
}
