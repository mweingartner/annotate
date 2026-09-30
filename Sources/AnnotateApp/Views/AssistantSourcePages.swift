import AnnotateCore
import Atrium
import SwiftUI

/// The pages an answer drew on, as quiet links that open each page.
struct AssistantSourcePages: View {
    let sources: [DocumentAssistantSource]
    let goToPage: (Int) -> Void

    var body: some View {
        let pages = Array(Set(sources.map(\.pageNumber))).sorted()
        VStack(alignment: .leading, spacing: Spacing.snug) {
            pageButtons(Array(pages.prefix(12)))
            if pages.count > 12 {
                DisclosureGroup("All \(pages.count) source pages") { pageButtons(Array(pages.dropFirst(12))) }
            }
        }
    }

    private func pageButtons(_ pages: [Int]) -> some View {
        // Adaptive columns, so the grid never asks for more width than the inspector has.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.control * 3), alignment: .leading)],
                  alignment: .leading, spacing: Spacing.tight) {
            ForEach(pages, id: \.self) { page in
                Button("Page \(page)", systemImage: "arrow.up.right") { goToPage(page) }
                    .font(Typography.meta).buttonStyle(.quiet)
                    .accessibilityHint("Opens source page \(page) in the PDF")
            }
        }
    }
}
