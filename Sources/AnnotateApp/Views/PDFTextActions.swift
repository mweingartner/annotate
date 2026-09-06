import SwiftUI

struct PDFTextActions: View {
    @Bindable var model: ReaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Select a word, line, or paragraph on the PDF to open its text editor. Type on the page and use the font controls to format selected words.")
                .font(.callout).foregroundStyle(.secondary)
            if !selectedText.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Selected text").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(selectedText).font(.callout).lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(ReaderStyle.accent.opacity(0.08), in: .rect(cornerRadius: 8))
            }
            Button("Edit selected text", systemImage: "text.cursor", action: editSelection)
                .buttonStyle(.borderedProminent)
                .disabled(selectedText.isEmpty || model.isProcessing || model.pdfDocument?.allowsDocumentChanges != true || model.pdfDocument?.allowsCopying != true)
                .help("Open the selected PDF passage in the native text editor")
            Button("Add text box", systemImage: "text.badge.plus", action: addText)
                .disabled(model.isProcessing || model.pdfDocument?.allowsDocumentChanges != true || model.pdfDocument?.allowsCopying != true)
            Text("Select saved text to edit it again. Existing annotation text boxes also open with a click.")
                .font(.caption).foregroundStyle(.secondary)
        }
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
