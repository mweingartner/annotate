import SwiftUI
import AnnotateCore

struct MarkerListPanel: View {
    @Bindable var model: ReaderModel

    var body: some View {
        if model.filteredMarkers.isEmpty {
            ContentUnavailableView {
                Label(model.filter == .all ? "Make it yours" : "Nothing here yet", systemImage: model.filter.symbol)
            } description: {
                Text(model.filter == .all
                     ? "Select text to capture a passage, or mark the current page. Your thoughts will be waiting here."
                     : "Markers in this category will appear here. A passage can belong to more than one category.")
            } actions: {
                Button("Mark this page", systemImage: "bookmark.badge.plus", action: model.beginPageMarker)
                    .disabled(!model.canEdit)
            }
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ReaderStyle.compactSpacing) {
                    HStack {
                        Text(model.filter.title.uppercased())
                            .tracking(1.1)
                        Spacer()
                        Text("PAGE")
                            .tracking(1.1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 3)

                    ForEach(model.filteredMarkers) { marker in
                        MarkerRow(marker: marker, selected: model.selectedMarkerID == marker.id,
                                  jump: { model.jump(to: marker) }, edit: { model.edit(marker) }, delete: { model.delete(marker) }, canEdit: model.canEdit)
                    }
                }
                .padding(ReaderStyle.panelPadding)
            }
            .accessibilityLabel("\(model.filter.title) markers")
        }
    }
}
