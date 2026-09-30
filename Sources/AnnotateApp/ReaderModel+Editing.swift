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

    /// Opens text for editing in place. `reflowingLines` treats the selection as one
    /// paragraph: its line ends become spaces, so edits rewrap within the paragraph's
    /// width instead of pushing each original line past its end.
    func beginLiveText(replacingSelection: Bool, reflowingLines: Bool = false) {
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
            var original = nativeStyle?.text ?? fallback
            if reflowingLines, let lines = original {
                original = ParagraphText.joiningLines(lines)
                // Measured on the displayed page, which the selection belongs to.
                if let selection, let shown = document.page(at: region.pageIndex),
                   let pitch = ParagraphText.linePitch(of: selection, on: shown),
                   let joined = original { original = ParagraphText.keepingLinePitch(pitch, in: joined) }
            }
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
        // Growing re-enters this method through the block's change handler, which
        // applies the text at the new size.
        if growIntoEmptySpace(edit, on: document.page(at: edit.pageIndex)) { return }
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
            // Queued redaction areas are fixed rectangles; text that moved may no longer be
            // under them. Clear this page's areas so they are drawn again deliberately.
            if redactionRegions.contains(where: { $0.pageIndex == edit.pageIndex }) {
                redactionRegions.removeAll { $0.pageIndex == edit.pageIndex }
                statusMessage = "Redaction areas on this page were cleared because its text changed"
            }
            suppressSelection = true
            pdfView?.selectionTask?.cancel()
            pdfView?.closeAnnotationPopover()
            // Typing replaces only the edited page inside the open document, which the
            // reader redraws at once. Replacing the whole document would blank the page
            // for a moment on every keystroke. Pages with form fields keep the whole-
            // document path, because their fields also live in the document's form.
            result.delegate = MarkerChrome.documentDelegate
            if let page = result.page(at: edit.pageIndex), document.canExchangePage(at: edit.pageIndex) {
                document.exchangePage(at: edit.pageIndex, with: page)
                MarkerCodec.refreshAppearance(in: document)
                markers = MarkerCodec.markers(in: document)
                pdfView?.layoutDocumentView()
            } else {
                pdfDocument = result
                MarkerCodec.refreshAppearance(in: result)
                PDFFormEditor.refreshRadioOptions(in: result)
                markers = MarkerCodec.markers(in: result)
                pdfView?.replaceDocumentForLiveEdit(result)
            }
            pageNumber = edit.pageIndex + 1
            toolSelection = PageRegion(pageIndex: edit.pageIndex, bounds: edit.appliedBounds)
            documentRevision += 1
            suppressSelection = false
            pdfView?.refreshLiveEditor(focus: editorHadFocus)
            if !edit.geometryIsValid {
                errorMessage = "Keep the text block inside the page. Text changes use its last valid position and size."
            }
        } catch {
            if case PDFNativeTextError.scannedText = error { edit.canEditScannedText = true }
            edit.nativeUpdateFailed = true
            edit.nativeFailureMessage = error.localizedDescription
            // Text that doesn't fit shows on the page (an overflow mark on the block) and in
            // the inspector; other failures also need the banner.
            if error as? PDFNativeTextError != .replacementDoesNotFit {
                errorMessage = error.localizedDescription + " Your pending text remains in the editor; it has not been saved over the PDF."
            }
            pdfView?.refreshLiveEditor()
        }
    }

    /// Text that no longer fits grows its block downward, like a text box in Pages, but
    /// only over empty page: never over other text, and never off the page. Otherwise the
    /// overflow is reported and the person decides, as before.
    private func growIntoEmptySpace(_ edit: LiveTextEdit, on page: PDFPage?) -> Bool {
        guard edit.textOverflows, let page, let fitted = edit.heightFittedBounds(),
              fitted.minY < edit.appliedBounds.minY else { return false }
        let grown = edit.appliedBounds.minY - fitted.minY
        // The new lines plus half as much again below them must be empty page, so the
        // paragraph never ends up touching what follows.
        let added = CGRect(x: fitted.minX, y: fitted.minY - grown / 2, width: fitted.width, height: grown * 1.5)
        let covered = page.selection(for: added)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard covered.isEmpty else { return false }
        edit.bounds = fitted
        return true
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
        // The text block's area was only the edit's own outline; don't leave it behind.
        if let edit = liveEdit, toolSelection == PageRegion(pageIndex: edit.pageIndex, bounds: edit.appliedBounds) {
            toolSelection = nil
        }
        // A problem reported about this edit no longer applies once it is gone.
        if let message = liveEdit?.nativeFailureMessage, errorMessage?.hasPrefix(message) == true { errorMessage = nil }
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

extension PDFDocument {
    /// Whether the page at `index` can be swapped in place: it has no form fields, whose
    /// field objects are shared with the document's form and cannot move with a page.
    func canExchangePage(at index: Int) -> Bool {
        guard let page = page(at: index), outlineItems() != nil else { return false }
        return !page.annotations.contains { $0.type == "Widget" }
    }

    /// Every outline entry, walked without recursion and visiting each entry once, or nil
    /// for an outline too large to retarget on every keystroke (a crafted file can nest
    /// thousands of levels); such documents keep the whole-document path.
    func outlineItems(limit: Int = 10_000) -> [PDFOutline]? {
        guard let root = outlineRoot else { return [] }
        var items: [PDFOutline] = [], stack = [root], seen: Set<ObjectIdentifier> = []
        while let item = stack.popLast() {
            guard seen.insert(ObjectIdentifier(item)).inserted else { continue }
            items.append(item)
            // Checked before reading any children, so a node with a million children costs
            // one count, not a million lookups.
            guard items.count + stack.count + item.numberOfChildren <= limit else { return nil }
            for index in 0..<item.numberOfChildren { item.child(at: index).map { stack.append($0) } }
        }
        return items
    }

    /// Puts `replacement` in place of the page at `index`, keeping this document object.
    /// Outline entries and links that led to the old page lead to the new one.
    func exchangePage(at index: Int, with replacement: PDFPage) {
        guard let old = page(at: index) else { return }
        // Links on the replacement lead to pages of the document it was made in; they
        // must lead to the same pages here.
        let origin = replacement.document
        let pages = (0..<pageCount).map { page(at: $0) }
        /// What becomes of a destination: unchanged, moved to a page of this document, or
        /// dropped because it leads into the temporary document and has no match here (a
        /// dangling target is worse than none).
        enum Retarget { case keep, move(PDFDestination), drop }
        func retarget(_ destination: PDFDestination?) -> Retarget {
            guard let destination, let page = destination.page else { return .keep }
            let moved: PDFPage
            if page === old { moved = replacement }
            else if let origin, origin !== self, page !== replacement, page.document === origin {
                let position = origin.index(for: page)
                guard position != NSNotFound, pages.indices.contains(position),
                      let local = position == index ? replacement : pages[position] else { return .drop }
                moved = local
            } else { return .keep }
            let result = PDFDestination(page: moved, at: destination.point)
            result.zoom = destination.zoom
            return .move(result)
        }
        func target(of destination: PDFDestination?) -> PDFDestination? {
            if case .move(let moved) = retarget(destination) { return moved }
            return nil
        }
        // Resolve every destination before the page moves: a destination read from a
        // file finds its page through the document and loses it once the page is removed.
        var updates: [() -> Void] = []
        for item in outlineItems() ?? [] {
            if let moved = target(of: item.destination) { updates.append { item.destination = moved } }
            if let action = item.action as? PDFActionGoTo, let moved = target(of: action.destination) {
                updates.append { action.destination = moved; item.action = action }
            }
        }
        // Any annotation can carry a go-to action (links, and buttons on other pages).
        for page in pages.compactMap({ $0 }).filter({ $0 !== old }) + [replacement] {
            for annotation in page.annotations {
                if let action = annotation.action as? PDFActionGoTo {
                    switch retarget(action.destination) {
                    case .move(let moved): updates.append { action.destination = moved; annotation.action = action }
                    case .drop: updates.append { annotation.action = nil }
                    case .keep: break
                    }
                }
                guard annotation.type == "Link" else { continue }
                switch retarget(annotation.destination) {
                case .move(let moved): updates.append { annotation.destination = moved }
                case .drop: updates.append { annotation.destination = nil }
                case .keep: break
                }
            }
        }
        insert(replacement, at: index)
        removePage(at: index + 1)
        updates.forEach { $0() }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
