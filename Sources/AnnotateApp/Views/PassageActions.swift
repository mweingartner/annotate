import Atrium
import SwiftUI

/// What else can be done with a selected passage besides marking it.
struct PassageActions: View {
    @Bindable var model: ReaderModel

    var body: some View {
        Menu("Passage Actions", systemImage: "ellipsis.circle") {
            Button("Edit PDF Text", systemImage: "character.cursor.ibeam") { model.showTool(.edit) }
                .disabled(model.hasDraftChanges || model.isProcessing || model.pdfDocument?.allowsDocumentChanges != true || model.pdfDocument?.allowsCopying != true)
            Divider()
            Button("Highlight", systemImage: "highlighter") { model.addToolMarkup(.highlight, color: .systemYellow) }
            Button("Underline", systemImage: "underline") { model.addToolMarkup(.underline, color: .systemRed) }
            Button("Strikeout", systemImage: "strikethrough") { model.addToolMarkup(.strikeOut, color: .systemRed) }
        }
        .labelStyle(.iconOnly)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!model.canEdit || model.hasDraftChanges || model.isProcessing)
        .help(model.hasDraftChanges ? "Save or cancel this marker before other passage actions"
              : "Edit the passage's text, or add a standard highlight, underline or strikeout")
    }
}
