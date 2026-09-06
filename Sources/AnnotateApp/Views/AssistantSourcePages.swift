import AnnotateCore
import SwiftUI

struct AssistantSourcePages: View {
    let sources: [DocumentAssistantSource]
    let goToPage: (Int) -> Void

    var body: some View {
        let pages = Array(Set(sources.map(\.pageNumber))).sorted()
        VStack(alignment: .leading, spacing: 8) {
            pageButtons(Array(pages.prefix(12)))
            if pages.count > 12 {
                DisclosureGroup("All \(pages.count) source pages") { pageButtons(Array(pages.dropFirst(12))) }
            }
        }
    }

    private func pageButtons(_ pages: [Int]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(pages, id: \.self) { page in
                Button("Page \(page)", systemImage: "arrow.up.right") { goToPage(page) }
                    .font(.caption).buttonStyle(.bordered).controlSize(.small)
                    .accessibilityHint("Opens source page \(page) in the PDF")
            }
        }
    }
}
