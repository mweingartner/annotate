import Atrium
import SwiftUI

/// How to start editing text, and a new text box for text that isn't on the page yet.
struct PDFTextActions: View {
    @Bindable var model: ReaderModel

    var body: some View {
        if model.pdfDocument?.allowsDocumentChanges != true || model.pdfDocument?.allowsCopying != true {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                Label("Editing Not Allowed", systemImage: "lock.fill")
                    .font(Typography.heading)
                Text("This PDF’s security settings don’t allow its text to be changed.")
                    .font(Typography.supporting)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            actions
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: Spacing.control) {
            Text("Click a line on the page to edit it where it is, or drag across words to edit just those. Press Escape or click elsewhere when you are done.")
                .font(Typography.supporting)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.snug) {
                Button("Add Text Box", systemImage: "character.textbox", action: addText)
                    .disabled(!canEditText)
                    .help("Add new text in the chosen area, or near the top of this page")
                if !selectedText.isEmpty {
                    Button("Edit Selection", systemImage: "character.cursor.ibeam", action: editSelection)
                        .disabled(!canEditText)
                        .help("Edit the selected words in place")
                }
            }
        }
    }

    private var canEditText: Bool {
        !model.isProcessing && model.pdfDocument?.allowsDocumentChanges == true && model.pdfDocument?.allowsCopying == true
    }

    private var selectedText: String {
        // Native PDFSelection is not observable; the captured area/revision refresh this preview.
        _ = model.toolSelection
        _ = model.documentRevision
        return model.pdfView?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    private func editSelection() { model.beginLiveText(replacingSelection: true) }
    private func addText() { model.beginLiveText(replacingSelection: false) }
}
