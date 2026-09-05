import SwiftUI

struct ReaderHeader: View {
    @Bindable var model: ReaderModel

    var body: some View {
        HStack(spacing: ReaderStyle.spacing) {
            Button("Toggle markers sidebar", systemImage: "sidebar.left", action: toggleSidebar)
                .labelStyle(.iconOnly)
                .help("Show or hide markers and search")
                .disabled(model.pdfDocument == nil)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.pdfDocument == nil ? "Annotate" : model.fileName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.pdfDocument == nil ? "A little more thought in every margin." : "Your reading. Your thinking. One place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.pdfDocument != nil {
                Button("Search document", systemImage: "magnifyingglass", action: model.showSearch)
                    .labelStyle(.iconOnly)
                    .help("Search document (⌘F)")

                HStack(spacing: ReaderStyle.compactSpacing) {
                    Button("Zoom out", systemImage: "minus.magnifyingglass", action: model.zoomOut)
                Button("Fit width", systemImage: "arrow.up.left.and.arrow.down.right", action: model.fitPage)
                    Button("Zoom in", systemImage: "plus.magnifyingglass", action: model.zoomIn)
                }
                .labelStyle(.iconOnly)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .rect(cornerRadius: ReaderStyle.radius))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Document zoom")

                Button("Mark page", systemImage: "bookmark.badge.plus", action: model.beginPageMarker)
                    .buttonStyle(.borderedProminent)
                    .tint(ReaderStyle.actionFill)
                    .foregroundStyle(.white)
                    .disabled(!model.canEdit)
                    .help("Add a marker to the current page; select text for a passage marker")
            }

            Menu("Document actions", systemImage: "ellipsis.circle") {
                Button("Open PDF…", systemImage: "folder", action: model.openDocument)
                Divider()
                Button("Save", systemImage: "square.and.arrow.down", action: model.saveDocument)
                    .disabled(model.pdfDocument == nil || !model.canEdit)
                Button("Export Annotated PDF…", systemImage: "square.and.arrow.up", action: model.exportDocument)
                    .disabled(model.pdfDocument == nil)
                Button("Print…", systemImage: "printer", action: model.printDocument)
                    .disabled(model.pdfDocument == nil)
            }
            .menuIndicator(.hidden)
            .labelStyle(.iconOnly)
            .help("Open, save, export, and print")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, ReaderStyle.panelPadding)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func toggleSidebar() {
        model.sidebarVisible.toggle()
    }
}
