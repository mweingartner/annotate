import AnnotateCore
import AppKit
import PDFKit
import UniformTypeIdentifiers

extension ReaderModel {
    /// Keep the document's save position aligned with forward and inverse edits.
    func recordDocumentChange() {
        // NSDocument observes its default undo manager. With autosavesInPlace its edited
        // state settles on the next run-loop turn; manually counting the same action twice
        // prevents undo from returning to the saved position.
        guard let owner, owner.undoManager == nil else { return }
        owner.updateChangeCount(.changeDone)
    }

    func showTool(_ tool: WorkspaceTool) {
        guard finishLiveText() else { return }
        let selection = pdfView?.currentSelection?.copy() as? PDFSelection
        let enteringEdit = tool == .edit && activeTool != .edit
        if hasDraftChanges { saveDraft() }
        guard !hasDraftChanges else { return }
        cancelDraft()
        selectingToolArea = false
        activeTool = activeTool == tool ? nil : tool
        pdfView?.closeAnnotationPopover()
        if enteringEdit, let selection, selection.string?.isEmpty == false {
            suppressSelection = true
            pdfView?.setCurrentSelection(selection, animate: false)
            suppressSelection = false
            beginLiveText(replacingSelection: true)
        }
    }

    /// Work on a serialized copy so a failed operation cannot partially modify an autosaving document.
    func mutatePDF(_ name: String, operation: (PDFDocument) throws -> Void) {
        guard !isProcessing, let source = pdfDocument else { return }
        guard finishLiveText() else { return }
        if hasDraftChanges { saveDraft() }
        guard !hasDraftChanges else { return }
        do {
            guard let bytes = source.dataRepresentation(), let working = PDFDocument(data: bytes) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if working.isLocked { throw AnnotateError.lockedDocument }
            try operation(working)
            guard working.pageCount > 0 else { throw AnnotateError.emptyDocument }
            replacePDF(working, actionName: name, previousData: bytes)
        } catch { errorMessage = error.localizedDescription }
    }

    /// `previousData`: the current document's bytes when the caller already has them, as the
    /// undo snapshot. Serializing a document after a page was moved or swapped can take
    /// seconds, so it is done once, not twice.
    func replacePDF(_ document: PDFDocument, actionName: String, previousData: Data? = nil) {
        guard document.pageCount > 0, !document.isLocked else {
            errorMessage = "The replacement PDF is locked or has no pages."
            return
        }
        if owner?.undoManager?.isUndoing == true || owner?.undoManager?.isRedoing == true { discardPendingLiveText() }
        else if !finishLiveText() { return }
        if let previous = previousData ?? pdfDocument?.dataRepresentation() {
            owner?.undoManager?.registerUndo(withTarget: self) { target in
                target.restoreWorkspace(previous, actionName: actionName)
            }
            owner?.undoManager?.setActionName(actionName)
        }
        let currentPage = pageNumber
        redactionRegions = []
        query = ""
        suppressSelection = true
        pdfView?.selectionTask?.cancel()
        pdfView?.closeAnnotationPopover()
        cancelDraft()
        pdfDocument = document
        MarkerCodec.refreshAppearance(in: document)
        PDFFormEditor.refreshRadioOptions(in: document)
        markers = MarkerCodec.markers(in: document)
        pageCount = document.pageCount
        pageNumber = min(max(1, currentPage), pageCount)
        canEdit = document.allowsCommenting
        selectedMarkerID = nil
        toolSelection = nil
        selectingToolArea = false
        documentRevision += 1
        pdfView?.document = document
        if let page = document.page(at: pageNumber - 1) { pdfView?.go(to: page) }
        suppressSelection = false
        recordDocumentChange()
        statusMessage = actionName
    }

    private func restoreWorkspace(_ data: Data, actionName: String) {
        guard let restored = PDFDocument(data: data) else {
            errorMessage = "The undo snapshot could not be restored."
            return
        }
        replacePDF(restored, actionName: actionName)
    }

    func performOperation(_ title: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !isProcessing else { return }
        guard finishLiveText() else { return }
        isProcessing = true
        operationProgress = title
        operationTask = Task { @MainActor [weak self] in
            defer { self?.isProcessing = false; self?.operationProgress = ""; self?.operationTask = nil }
            do {
                try Task.checkCancellation()
                // Long operations render pages for output files; markers must look as saved.
                try await MarkerChrome.drawingForOutput { try await operation() }
            } catch is CancellationError {
                self?.statusMessage = "Operation cancelled"
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func saveOutput(data: Data, suggestedName: String, contentType: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = suggestedName
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                if url.isSameFile(as: self.owner?.fileURL) { throw WorkspaceError.sourceOverwrite }
                try data.write(to: url, options: .atomic)
                self.statusMessage = "Saved \(url.lastPathComponent)"
            } catch { self.errorMessage = error.localizedDescription }
        }
        if let window = owner?.windowForSheet { panel.beginSheetModal(for: window, completionHandler: complete) }
        else { complete(panel.runModal()) }
    }

    func newBlankPDF() {
        let pdf = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
        pdf.insert(page, at: 0)
        openCreatedPDF(pdf, name: "Untitled PDF")
    }

    func openCreatedPDF(_ pdf: PDFDocument, name: String) {
        let document = AnnotateDocument()
        document.fileType = UTType.pdf.identifier
        document.model.load(pdf, owner: document)
        document.model.fileName = name
        document.updateChangeCount(.changeDone)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
    }
}

enum WorkspaceError: LocalizedError {
    case sourceOverwrite
    var errorDescription: String? { "Choose another filename so the original PDF remains available." }
}
