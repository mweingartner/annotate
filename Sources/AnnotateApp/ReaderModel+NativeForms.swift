import AnnotateCore
import AppKit
import PDFKit

extension ReaderModel {
    func recordNativeFormChange(previous: [PDFFormField]) {
        // Native widget interaction ends a text-editing session so its immutable
        // original-text snapshot can never overwrite a later field value.
        if liveEdit?.nativeUpdateFailed != true { _ = finishLiveText() }
        else { liveEdit?.needsUndoCheckpoint = true }
        if let undo = owner?.undoManager, undo.isUndoRegistrationEnabled {
            undo.registerUndo(withTarget: self) { target in target.restoreNativeFormValues(previous) }
            undo.setActionName("Fill Form Field")
        }
        recordDocumentChange()
        documentRevision += 1
        statusMessage = "Form field updated"
    }

    /// Native PDFKit widgets can still receive focus while an overflowing text edit
    /// remains pending. Carry their current values into the immutable text source
    /// before rebuilding its content, including radio groups and shared fields.
    /// Widgets that reflow moved are matched at the place they came from.
    func synchronizeNativeFields(into source: PDFDocument, from current: PDFDocument, reflowed: PDFNativeReflowResult? = nil) {
        var checkedButtons: [PDFAnnotation] = []
        for index in 0..<min(source.pageCount, current.pageCount) {
            let sourceWidgets = (source.page(at: index)?.annotations ?? []).filter { $0.type == "Widget" }
            for widget in current.page(at: index)?.annotations ?? [] where widget.type == "Widget" {
                var bounds = widget.bounds
                if let reflowed, !reflowed.region.isNull {
                    let original = bounds.offsetBy(dx: 0, dy: -reflowed.offset)
                    if reflowed.region.insetBy(dx: -1, dy: -1).contains(CGPoint(x: original.midX, y: original.midY)) { bounds = original }
                }
                guard let target = sourceWidgets.first(where: {
                    $0.fieldName == widget.fieldName && $0.bounds.matches(bounds) && $0.widgetFieldType == widget.widgetFieldType
                }) else { continue }
                if widget.widgetFieldType == .button {
                    target.buttonWidgetStateString = widget.buttonWidgetStateString
                    target.buttonWidgetState = .offState
                    if widget.buttonWidgetState == .onState { checkedButtons.append(target) }
                } else { target.widgetStringValue = widget.widgetStringValue }
            }
        }
        for widget in checkedButtons { widget.buttonWidgetState = .onState }
    }

    private func restoreNativeFormValues(_ fields: [PDFFormField]) {
        guard let document = pdfDocument, !document.isLocked, document.allowsFormFieldEntry else { return }
        let current = PDFFormEditor.fields(in: document)
        let targets: [(PDFFormField, PDFAnnotation)] = fields.compactMap { field in
            guard let page = document.page(at: field.pageIndex), page.annotations.indices.contains(field.annotationIndex) else { return nil }
            let annotation = page.annotations[field.annotationIndex]
            guard annotation.type == "Widget", annotation.fieldName == field.name else { return nil }
            return (field, annotation)
        }
        guard targets.count == fields.count else {
            errorMessage = "The form fields needed for undo are no longer available."
            return
        }
        let restore = {
            // Clear button states first, then select checked options. This preserves radio groups
            // even when their selected option appears before an unselected option in page order.
            for (field, annotation) in targets {
                switch field.kind {
                case .text, .choice, .list: annotation.widgetStringValue = field.value
                case .checkbox, .radio:
                    annotation.buttonWidgetStateString = field.exportValue
                    annotation.buttonWidgetState = .offState
                }
            }
            for (field, annotation) in targets where (field.kind == .checkbox || field.kind == .radio) && field.checked {
                annotation.buttonWidgetState = .onState
            }
        }
        if let tracker = pdfView?.nativeFormTracker { tracker.restoring(restore) }
        else { restore() }
        recordNativeFormChange(previous: current)
        for index in Set(fields.map(\.pageIndex)) {
            if let page = document.page(at: index) { pdfView?.annotationsChanged(on: page) }
        }
    }
}

private extension CGRect {
    /// The same rectangle, allowing for rounding in a move there and back.
    func matches(_ other: CGRect) -> Bool {
        abs(minX - other.minX) < 0.01 && abs(minY - other.minY) < 0.01
            && abs(width - other.width) < 0.01 && abs(height - other.height) < 0.01
    }
}
