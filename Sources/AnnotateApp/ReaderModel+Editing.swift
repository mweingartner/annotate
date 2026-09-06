import AnnotateCore
import AppKit
import PDFKit

extension ReaderModel {
    var selectedToolRegions: [PageRegion] {
        if let selection = pdfView?.currentSelection, let document = pdfDocument {
            let regions = MarkerCodec.regions(for: selection, in: document)
            if !regions.isEmpty { return regions }
        }
        return toolSelection.map { [$0] } ?? []
    }

    func defaultToolArea() -> PageRegion? {
        guard let page = pdfDocument?.page(at: pageNumber - 1) else { return nil }
        let box = page.bounds(for: .cropBox)
        return PageRegion(pageIndex: pageNumber - 1, bounds: CGRect(x: box.minX + box.width * 0.1,
            y: box.minY + box.height * 0.65, width: box.width * 0.6, height: box.height * 0.1))
    }

    func beginLiveText(replacingSelection: Bool) {
        guard !hasPendingImageChanges else {
            errorMessage = "Apply or discard the pending image changes before editing text."
            return
        }
        guard finishLiveText(), !isProcessing, let document = pdfDocument,
              !document.isLocked, document.allowsDocumentChanges, document.allowsCopying else { return }
        if hasDraftChanges { saveDraft() }
        guard !hasDraftChanges else { return }
        let selection = pdfView?.currentSelection
        let text = replacingSelection ? (selection?.string ?? "") : "Type here"
        let selected = selectedToolRegions
        let region: PageRegion
        if replacingSelection, let first = selected.first {
            guard selected.allSatisfy({ $0.pageIndex == first.pageIndex }), !text.isEmpty else {
                errorMessage = "Select a word, line, or paragraph on one page to edit."
                return
            }
            region = PageRegion(pageIndex: first.pageIndex, bounds: selected.reduce(first.bounds) { $0.union($1.bounds) })
        } else if let area = toolSelection ?? defaultToolArea() { region = area }
        else { errorMessage = "Select the text or an area to edit."; return }
        do {
            guard let bytes = document.dataRepresentation(), let source = PDFDocument(data: bytes),
                  let page = source.page(at: region.pageIndex) else { throw PDFNativeTextError.invalidSelection }
            let fallback = replacingSelection ? selection?.attributedString : nil
            let nativeStyle: PDFNativeTextStyleResult?
            if replacingSelection, let fallback {
                nativeStyle = try PDFNativeTextStyle.attributedText(in: source, region: region, originalText: text, fallback: fallback)
            } else { nativeStyle = nil }
            let original = nativeStyle?.text ?? fallback
            let attributes = original.flatMap { $0.length > 0 ? $0.attributes(at: 0, effectiveRange: nil) : nil } ?? [:]
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
            let color = attributes[.foregroundColor] as? NSColor ?? .black
            let attributed = original ?? NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            // PDF selections describe glyph ink. Give the editable layout enough vertical
            // space for its first baseline; the removal region remains the exact selection.
            let crop = page.bounds(for: .cropBox)
            let height = min(crop.height, max(region.bounds.height + font.pointSize * 0.3, font.pointSize * 1.5))
            let bounds = CGRect(x: region.bounds.minX, y: max(crop.minY, region.bounds.maxY - height),
                                width: region.bounds.width, height: height).intersection(crop)
            let session = LiveTextEdit(identifier: UUID().uuidString, pageIndex: region.pageIndex, text: text,
                font: font, color: color, bounds: bounds, pageBounds: crop,
                attributedText: attributed, isExistingContent: replacingSelection)
            session.nativeSource = source
            session.canEditScannedText = nativeStyle?.requiresScannedEditing ?? false
            if let substitutions = nativeStyle?.fontSubstitutions, !substitutions.isEmpty {
                session.fontSubstitutionMessage = substitutions.joined(separator: " ")
            }
            session.nativeOriginalRegion = region
            session.nativeOriginalText = replacingSelection ? text : ""
            session.needsUndoCheckpoint = true
            startLiveSession(session)
            if !replacingSelection { updateLiveText() }
        } catch { errorMessage = error.localizedDescription }
    }

    func editTextAnnotation(_ annotation: PDFAnnotation, page: PDFPage) {
        guard !hasPendingImageChanges else {
            errorMessage = "Apply or discard the pending image changes before editing text."
            return
        }
        guard !isProcessing, let document = pdfDocument, !document.isLocked,
              document.allowsDocumentChanges, document.allowsCopying, annotation.type == "FreeText",
              annotation.value(forAnnotationKey: MarkerCodec.ownerKey) as? String != MarkerCodec.ownerValue,
              finishLiveText() else { return }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound, let annotationIndex = page.annotations.firstIndex(of: annotation),
              let bytes = document.dataRepresentation(), let source = PDFDocument(data: bytes),
              let sourcePage = source.page(at: pageIndex), sourcePage.annotations.indices.contains(annotationIndex) else { return }
        sourcePage.removeAnnotation(sourcePage.annotations[annotationIndex])
        let text = annotation.contents ?? ""
        let font = annotation.font ?? .systemFont(ofSize: 14), color = annotation.fontColor ?? .black
        let session = LiveTextEdit(identifier: UUID().uuidString, pageIndex: pageIndex, text: text, font: font,
            color: color, bounds: annotation.bounds, pageBounds: page.bounds(for: .cropBox), isExistingContent: true)
        session.nativeSource = source
        session.nativeOriginalRegion = PageRegion(pageIndex: pageIndex, bounds: annotation.bounds)
        session.needsUndoCheckpoint = true
        startLiveSession(session)
    }

    private func startLiveSession(_ session: LiveTextEdit) {
        activeTool = .edit
        session.changed = { [weak self] in self?.updateLiveText() }
        session.selectionChanged = { [weak self] in self?.pdfView?.refreshLiveEditor() }
        liveEdit = session
        session.updateSelection(NSRange(location: 0, length: session.attributedText.length))
        toolSelection = PageRegion(pageIndex: session.pageIndex, bounds: session.appliedBounds)
        suppressSelection = true
        pdfView?.clearSelection()
        suppressSelection = false
        pdfView?.refreshLiveEditor(focus: true)
        // The new inspector changes the split-view layout. Restore the insertion
        // point after SwiftUI has installed that layout instead of leaving focus
        // on the window's first text field.
        Task { @MainActor [weak self, weak session] in
            await Task.yield()
            guard let self, let session, self.liveEdit === session else { return }
            self.pdfView?.refreshLiveEditor(focus: true)
        }
    }

    func updateLiveText() {
        guard !isProcessing, let edit = liveEdit, !edit.isApplyingNativeUpdate,
              let source = edit.nativeSource, let region = edit.nativeOriginalRegion,
              let document = pdfDocument, !document.isLocked, document.allowsDocumentChanges else { return }
        let editorHadFocus = pdfView?.window?.firstResponder === pdfView?.liveTextView
        edit.isApplyingNativeUpdate = true
        defer { edit.isApplyingNativeUpdate = false }
        do {
            synchronizeNativeFields(into: source, from: document)
            let destination = PageRegion(pageIndex: edit.pageIndex, bounds: edit.appliedBounds)
            let result: PDFDocument
            if edit.usesScannedTextEditing {
                result = try PDFNativeTextEditor.replaceScanned(in: source, region: region,
                    originalText: edit.nativeOriginalText, replacement: edit.attributedText, destination: destination)
            } else {
                result = try PDFNativeTextEditor.replace(in: source, region: region,
                    originalText: edit.nativeOriginalText, replacement: edit.attributedText, destination: destination)
            }
            if edit.needsUndoCheckpoint {
                guard let previous = document.dataRepresentation() else { throw PDFNativeTextError.cannotWrite }
                owner?.undoManager?.registerUndo(withTarget: self) { target in target.restoreLiveTextCheckpoint(previous) }
                owner?.undoManager?.setActionName(edit.isExistingContent ? "Edit Text" : "Add Text")
                recordDocumentChange()
                edit.needsUndoCheckpoint = false
            }
            edit.nativeUpdateFailed = false
            if let message = edit.nativeFailureMessage, errorMessage?.hasPrefix(message) == true { errorMessage = nil }
            if edit.geometryIsValid, errorMessage?.hasPrefix("Keep the text block inside") == true { errorMessage = nil }
            edit.nativeFailureMessage = nil
            suppressSelection = true
            pdfView?.selectionTask?.cancel()
            pdfView?.closeAnnotationPopover()
            pdfDocument = result
            MarkerCodec.refreshAppearance(in: result)
            PDFFormEditor.refreshRadioOptions(in: result)
            markers = MarkerCodec.markers(in: result)
            pdfView?.replaceDocumentForLiveEdit(result)
            pageNumber = edit.pageIndex + 1
            toolSelection = PageRegion(pageIndex: edit.pageIndex, bounds: edit.appliedBounds)
            documentRevision += 1
            suppressSelection = false
            pdfView?.refreshLiveEditor(focus: editorHadFocus)
            statusMessage = "PDF text updated"
            if !edit.geometryIsValid {
                errorMessage = "Keep the text block inside the page. Text changes use its last valid position and size."
            }
        } catch {
            if case PDFNativeTextError.scannedText = error { edit.canEditScannedText = true }
            edit.nativeUpdateFailed = true
            edit.nativeFailureMessage = error.localizedDescription
            errorMessage = error.localizedDescription + " Your pending text remains in the editor; it has not been saved over the PDF."
            pdfView?.refreshLiveEditor()
        }
    }

    func enableScannedTextEditing() {
        guard let edit = liveEdit, edit.canEditScannedText else { return }
        edit.usesScannedTextEditing = true
        updateLiveText()
    }

    private func restoreLiveTextCheckpoint(_ data: Data) {
        guard let restored = PDFDocument(data: data) else {
            errorMessage = "The text editing undo checkpoint could not be restored."
            return
        }
        discardPendingLiveText()
        replacePDF(restored, actionName: "Edit Text")
    }

    @discardableResult
    func finishLiveText() -> Bool {
        guard liveEdit?.nativeUpdateFailed != true else {
            errorMessage = (liveEdit?.nativeFailureMessage ?? "The text could not be applied.")
                + " Resize or correct the text, or discard the pending edit before closing the editor."
            return false
        }
        discardPendingLiveText()
        return true
    }

    func discardPendingLiveText() {
        liveEdit?.changed = {}
        liveEdit?.selectionChanged = {}
        liveEdit = nil
        pdfView?.removeLiveEditor()
    }

    func addToolMarkup(_ subtype: PDFAnnotationSubtype, color: NSColor) {
        let regions = selectedToolRegions
        guard !regions.isEmpty else { errorMessage = "Select text or draw an area first."; return }
        mutatePDF("Add \(subtype.rawValue)") { working in
            try PDFContentEditor.addMarkup(subtype, regions: regions, document: working, color: color)
        }
    }

    func queueRedaction() {
        let regions = selectedToolRegions
        guard !regions.isEmpty else { errorMessage = "Select text or draw the area to redact."; return }
        for region in regions where !redactionRegions.contains(region) { redactionRegions.append(region) }
        statusMessage = "\(redactionRegions.count) redaction areas queued"
    }

    func exportRedactedPDF() {
        if hasDraftChanges { saveDraft() }
        guard !hasDraftChanges else { return }
        guard let document = pdfDocument else { return }
        let regions = redactionRegions
        performOperation("Preparing redacted copy") { [weak self] in
            guard let self else { return }
            let data = try await PDFContentEditor.redactedData(document: document, regions: regions) { [weak self] done, total in
                self?.operationProgress = "Redacting · \(done) of \(total) pages"
            }
            self.saveOutput(data: data, suggestedName: (self.fileName as NSString).deletingPathExtension + " — Redacted.pdf", contentType: .pdf)
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
