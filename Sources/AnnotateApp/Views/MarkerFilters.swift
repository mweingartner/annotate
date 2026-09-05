import SwiftUI
import AnnotateCore

struct MarkerFilters: View {
    @Bindable var model: ReaderModel

    private let filters: [MarkerFilter] = [.all, .important, .revisit, .question, .note]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: ReaderStyle.compactSpacing) {
            ForEach(filters, id: \.self) { filter in
                MarkerFilterButton(
                    filter: filter,
                    count: model.markers.count { filter.matches($0) },
                    selected: model.filter == filter,
                    action: { model.setFilter(filter) }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Marker categories")
    }
}
