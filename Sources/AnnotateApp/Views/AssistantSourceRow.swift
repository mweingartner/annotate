import AnnotateCore
import SwiftUI

struct AssistantSourceRow: View {
    let source: DocumentAssistantSource
    let goToPage: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(source.label, systemImage: "doc.text.magnifyingglass") { goToPage(source.pageNumber) }
                .buttonStyle(.link).accessibilityHint("Opens the original PDF page")
            Text(verbatim: source.text).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            DisclosureGroup("Full passage") {
                Text(verbatim: source.text).font(.callout).textSelection(.enabled).padding(.top, 5)
            }
            .font(.caption)
        }
        .padding(10)
        .background(.background.opacity(0.7), in: .rect(cornerRadius: 8))
    }
}
