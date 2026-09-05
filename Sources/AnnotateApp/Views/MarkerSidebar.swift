import SwiftUI
import AnnotateCore

struct MarkerSidebar: View {
    @Bindable var model: ReaderModel
    @FocusState private var searchFocused: Bool

    private var isShowingSearch: Bool { !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: ReaderStyle.spacing) {
                HStack {
                    Text("Your margins")
                        .font(.title2)
                        .fontDesign(.serif)
                        .bold()
                    Spacer()
                    Text("\(model.markerCount)")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: .capsule)
                        .accessibilityLabel("\(model.markerCount) markers")
                }

                HStack(spacing: ReaderStyle.compactSpacing) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Search this PDF", text: $model.query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .accessibilityLabel("Search this PDF")
                    if !model.query.isEmpty {
                        Button("Clear search", systemImage: "xmark.circle.fill", action: clearSearch)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.background, in: .rect(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(searchFocused ? ReaderStyle.accent : Color.primary.opacity(0.12), lineWidth: searchFocused ? 2 : 1)
                }

                if !isShowingSearch {
                    MarkerFilters(model: model)
                }
            }
            .padding(ReaderStyle.panelPadding)

            Divider()

            if isShowingSearch {
                SearchResultsPanel(model: model)
            } else {
                MarkerListPanel(model: model)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background.secondary)
        .onChange(of: model.searchFocusRequest, focusSearch)
        .onAppear(perform: focusSearchIfRequested)
    }

    private func focusSearch() { searchFocused = true }
    private func focusSearchIfRequested() {
        if model.searchFocusRequest > 0 { searchFocused = true }
    }
    private func clearSearch() { model.query = ""; searchFocused = true }
}
