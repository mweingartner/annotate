import AppKit
import PDFKit

@MainActor
public enum PDFFormEditor {
    private static let radioOptionKey = PDFAnnotationKey(rawValue: "/AnnotateRadioOption")
    public static func fields(in document: PDFDocument) -> [PDFFormField] {
        guard !document.isLocked else { return [] }
        return (0..<document.pageCount).flatMap { pageIndex -> [PDFFormField] in
            guard let page = document.page(at: pageIndex) else { return [] }
            return page.annotations.enumerated().compactMap { index, annotation in
                guard let kind = kind(of: annotation) else { return nil }
                let option = radioOption(annotation)
                let checked = kind == .radio ? annotation.widgetStringValue == option : annotation.buttonWidgetState == .onState
                return PDFFormField(pageIndex: pageIndex, annotationIndex: index,
                                    name: annotation.fieldName ?? "Unnamed field", kind: kind,
                                    value: annotation.widgetStringValue ?? "", choices: annotation.choices ?? [],
                                    readOnly: annotation.isReadOnly, checked: checked,
                                    exportValue: option)
            }
        }
    }

    public static func create(in document: PDFDocument, region: PageRegion, name: String, kind: PDFFormKind,
                              choices: [String] = [], exportValue: String = "Yes", multiline: Bool = false) throws {
        guard !document.isLocked else { throw AnnotateError.lockedDocument }
        guard document.allowsCommenting, document.allowsDocumentChanges else { throw PDFFormError.creationRestricted }
        let page = try validate(region, in: document)
        let fieldName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fieldName.isEmpty, fieldName.utf8.count <= 255, !fieldName.contains(".") else { throw PDFFormError.invalidName }
        let existing = fields(in: document).filter { $0.name == fieldName }
        if !existing.isEmpty {
            guard kind == .radio, existing.allSatisfy({ $0.kind == .radio && $0.exportValue != exportValue }) else {
                throw PDFFormError.duplicateName
            }
        }
        if kind == .choice || kind == .list, choices.isEmpty || choices.contains(where: { $0.isEmpty }) || Set(choices).count != choices.count {
            throw PDFFormError.invalidChoices
        }
        if kind == .radio, exportValue.isEmpty || exportValue == "Off" { throw PDFFormError.invalidRadioValue }
        let annotation = PDFAnnotation(bounds: region.bounds, forType: .widget, withProperties: nil)
        annotation.font = NSFont.systemFont(ofSize: min(14, max(8, region.bounds.height - 6)))
        annotation.fontColor = .black
        annotation.backgroundColor = NSColor(srgbRed: 0.94, green: 0.97, blue: 1, alpha: 1)
        annotation.color = NSColor(srgbRed: 0.3, green: 0.4, blue: 0.5, alpha: 1)
        let border = PDFBorder()
        border.lineWidth = 1
        annotation.border = border
        annotation.shouldPrint = true
        annotation.shouldDisplay = true
        switch kind {
        case .text:
            annotation.widgetFieldType = .text
            annotation.isMultiline = multiline
            annotation.widgetStringValue = ""
        case .checkbox:
            annotation.widgetFieldType = .button
            annotation.widgetControlType = .checkBoxControl
            annotation.buttonWidgetStateString = "Yes"
            annotation.buttonWidgetState = .offState
        case .radio:
            annotation.widgetFieldType = .button
            annotation.widgetControlType = .radioButtonControl
            annotation.buttonWidgetStateString = exportValue
            annotation.setValue(exportValue, forAnnotationKey: radioOptionKey)
            annotation.radiosInUnison = false
            annotation.allowsToggleToOff = false
            annotation.buttonWidgetState = .offState
        case .choice, .list:
            annotation.widgetFieldType = .choice
            annotation.isListChoice = kind == .list
            annotation.choices = choices
            annotation.values = choices
            annotation.widgetStringValue = choices.first
        }
        page.addAnnotation(annotation)
        annotation.fieldName = fieldName
        if let font = annotation.font { PDFContentEditor.setTextAppearance(annotation, font: font, color: .black) }
    }

    public static func fill(in document: PDFDocument, field: PDFFormField, value: String) throws {
        guard !document.isLocked else { throw AnnotateError.lockedDocument }
        guard document.allowsFormFieldEntry else { throw PDFFormError.fillingRestricted }
        guard let annotation = document.page(at: field.pageIndex)?.annotations[safeFormIndex: field.annotationIndex],
              let type = kind(of: annotation), annotation.fieldName == field.name,
              !annotation.isReadOnly else { throw PDFFormError.readOnly }
        let widgets = (0..<document.pageCount).flatMap { document.page(at: $0)?.annotations ?? [] }
            .filter { $0.type == "Widget" && $0.fieldName == annotation.fieldName }
        guard widgets.allSatisfy({ !$0.isReadOnly }) else { throw PDFFormError.readOnly }
        switch type {
        case .text:
            if annotation.maximumLength > 0, value.count > annotation.maximumLength { throw PDFFormError.tooLong }
            for widget in widgets { widget.widgetStringValue = value }
        case .choice, .list:
            guard (annotation.choices ?? []).contains(value) || (annotation.values ?? []).contains(value) else { throw PDFFormError.invalidChoices }
            let index = annotation.choices?.firstIndex(of: value)
            let exported = index.flatMap { annotation.values?[safeFormIndex: $0] } ?? value
            for widget in widgets { widget.widgetStringValue = exported }
        case .checkbox:
            for widget in widgets { widget.buttonWidgetState = value == "Off" ? .offState : .onState }
        case .radio:
            let selected = radioOption(annotation)
            for widget in widgets {
                widget.buttonWidgetStateString = radioOption(widget)
                widget.buttonWidgetState = radioOption(widget) == selected ? .onState : .offState
            }
        }
    }

    public static func remove(in document: PDFDocument, field: PDFFormField) throws {
        guard !document.isLocked, document.allowsCommenting, document.allowsDocumentChanges else { throw PDFFormError.creationRestricted }
        guard let page = document.page(at: field.pageIndex),
              let annotation = page.annotations[safeFormIndex: field.annotationIndex],
              kind(of: annotation) != nil, annotation.fieldName == field.name else { throw PDFFormError.readOnly }
        page.removeAnnotation(annotation)
    }

    static func validate(_ region: PageRegion, in document: PDFDocument) throws -> PDFPage {
        guard let page = document.page(at: region.pageIndex),
              [region.bounds.minX, region.bounds.minY, region.bounds.width, region.bounds.height].allSatisfy(\.isFinite),
              region.bounds.width >= 4, region.bounds.height >= 4,
              page.bounds(for: .mediaBox).contains(region.bounds) else { throw PDFFormError.invalidBounds }
        return page
    }

    /// Restore PDFKit's in-memory on-state names from persisted metadata. PDFKit-generated radio
    /// appearances flatten their state dictionary on write, although their current value persists.
    public static func refreshRadioOptions(in document: PDFDocument) {
        guard !document.isLocked else { return }
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] where kind(of: annotation) == .radio {
                if let option = annotation.value(forAnnotationKey: radioOptionKey) as? String {
                    annotation.buttonWidgetStateString = option
                }
            }
        }
    }

    private static func radioOption(_ annotation: PDFAnnotation) -> String {
        annotation.value(forAnnotationKey: radioOptionKey) as? String ?? annotation.buttonWidgetStateString
    }

    private static func kind(of annotation: PDFAnnotation) -> PDFFormKind? {
        guard annotation.type == "Widget" else { return nil }
        switch annotation.widgetFieldType {
        case .text: return .text
        case .choice: return annotation.isListChoice ? .list : .choice
        case .button:
            return annotation.widgetControlType == .checkBoxControl ? .checkbox : annotation.widgetControlType == .radioButtonControl ? .radio : nil
        default: return nil
        }
    }
}

private extension Array {
    subscript(safeFormIndex index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
