import SwiftUI

struct SearchResultsPanel: View {
    @Bindable var model: ReaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.isSearching ? "Searching…" : "\(model.searchResults.count) \(model.searchResults.count == 1 ? "result" : "results")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Searching PDF")
                }
            }
            .padding(ReaderStyle.panelPadding)

            if model.searchResults.isEmpty && !model.isSearching {
                ContentUnavailableView.search(text: model.query)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: ReaderStyle.compactSpacing) {
                        ForEach(model.searchResults) { hit in
                            SearchResultRow(hit: hit, jump: { model.jump(to: hit) })
                        }
                    }
                    .padding(.horizontal, ReaderStyle.panelPadding)
                    .padding(.bottom, ReaderStyle.panelPadding)
                }
                .accessibilityLabel("Search results")
            }
        }
    }
}
