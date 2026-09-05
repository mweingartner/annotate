import SwiftUI

struct ReaderStatusBar: View {
    @Bindable var model: ReaderModel
    @State private var pageEntry = 1

    var body: some View {
        HStack(spacing: ReaderStyle.spacing) {
            HStack(spacing: 6) {
                Text("Page")
                TextField("Page number", value: $pageEntry, format: .number.grouping(.never))
                    .frame(width: 46)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(goToPage)
                    .accessibilityLabel("Go to page")
                Text("of \(model.pageCount)")
            }

            if !model.canEdit {
                Label("Read only", systemImage: "lock")
                    .help("This PDF does not allow annotations")
            }

            Spacer(minLength: ReaderStyle.compactSpacing)

            Text(model.statusMessage.isEmpty ? "Select a passage to annotate" : model.statusMessage)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(-1)

            HStack(spacing: ReaderStyle.compactSpacing) {
                Button("Previous marker", systemImage: "chevron.up", action: previousMarker)
                Text("\(model.filteredMarkers.count) \(model.filteredMarkers.count == 1 ? "marker" : "markers")")
                    .monospacedDigit()
                Button("Next marker", systemImage: "chevron.down", action: nextMarker)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(model.filteredMarkers.isEmpty)
        }
        .font(.callout)
        .padding(.horizontal, ReaderStyle.panelPadding)
        .padding(.vertical, ReaderStyle.compactSpacing)
        .background(.bar)
        .onAppear(perform: updatePageEntry)
        .onChange(of: model.pageNumber, updatePageEntry)
    }

    private func updatePageEntry() { pageEntry = model.pageNumber }
    private func goToPage() { model.goToPage(pageEntry); pageEntry = model.pageNumber }
    private func previousMarker() { model.navigateMarker(-1) }
    private func nextMarker() { model.navigateMarker(1) }
}
