import SwiftUI

struct PassageActions: View {
    @Bindable var model: ReaderModel

    var body: some View {
        HStack {
            Button("Edit PDF text", systemImage: "pencil.and.outline") { model.showTool(.edit) }
                .disabled(model.hasDraftChanges || model.isProcessing || model.pdfDocument?.allowsDocumentChanges != true || model.pdfDocument?.allowsCopying != true)
                .help(model.hasDraftChanges ? "Save or cancel this marker draft before editing PDF text" : "Edit the selected words directly, with font and style controls")
            Spacer(minLength: 4)
            Menu("More passage actions", systemImage: "ellipsis") {
                Button("Highlight", systemImage: "highlighter") { model.addToolMarkup(.highlight, color: .systemYellow) }
                Button("Underline", systemImage: "underline") { model.addToolMarkup(.underline, color: .systemRed) }
                Button("Strikeout", systemImage: "strikethrough") { model.addToolMarkup(.strikeOut, color: .systemRed) }
            }
            .labelStyle(.iconOnly)
            .menuIndicator(.hidden)
            .disabled(!model.canEdit || model.hasDraftChanges || model.isProcessing)
            .help("Add standard PDF highlight, underline, or strikeout markup")
        }
        .font(.callout)
        .padding(.horizontal, ReaderStyle.panelPadding)
        .padding(.vertical, 10)
    }
}
