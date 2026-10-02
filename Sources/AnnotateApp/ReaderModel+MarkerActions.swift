import AnnotateCore

extension ReaderModel {
    /// Marker actions remain available from every workspace tool, with the editor visible.
    func openMarkerEditor(_ marker: PDFMarker) {
        guard canEdit, !isProcessing, finishLiveText(),
              let current = markers.first(where: { $0.id == marker.id }) else { return }
        activeTool = nil
        selectingToolArea = false
        pdfView?.closeAnnotationPopover()
        edit(current)
    }

    func markCurrentPageFromWorkspace() {
        guard canEdit, !isProcessing, finishLiveText() else { return }
        activeTool = nil
        selectingToolArea = false
        pdfView?.closeAnnotationPopover()
        beginPageMarker()
    }

    func removeMarkerFromReader(_ marker: PDFMarker) {
        guard canEdit, !isProcessing else { return }
        guard !hasDraftChanges else {
            errorMessage = "Save or cancel the open marker draft before deleting a marker."
            return
        }
        guard finishLiveText(), let current = markers.first(where: { $0.id == marker.id }) else { return }
        delete(current)
        if selectedMarkerID == marker.id { selectedMarkerID = nil }
        statusMessage = "Marker deleted · Undo to restore"
    }
}

extension ReaderModel {
    /// Return to reading. Like Escape, closing ends a text edit even when its text could
    /// not be applied, dropping only that text.
    func closeActiveTool() {
        endLiveTextEditing()
        guard liveEdit == nil else { return }
        activeTool = nil
        selectingToolArea = false
    }
}
