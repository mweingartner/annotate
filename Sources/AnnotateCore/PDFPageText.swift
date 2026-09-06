import AppKit
import PDFKit

public struct PDFPageTextRecord: Sendable {
    public let text: String
    public let label: String
    /// Original PDF page coordinates, suitable for selection and navigation.
    public let bounds: CGRect
    fileprivate let annotationIndex: Int
}

/// Shared semantic extraction for exports and AI evidence. PDFKit's page text
/// omits FreeText annotations and filled widgets even when they are visible.
@MainActor
public enum PDFPageText {
    nonisolated public static let orderingDescription = "Page text comes first. Text boxes and filled text/choice fields follow in top-to-bottom, left-to-right order; they are not merged into paragraphs. Hidden annotations and password fields are excluded."

    public static func attributedText(from page: PDFPage) throws -> NSAttributedString {
        if let document = page.document { try PDFConversion.validate(document) }
        let result = NSMutableAttributedString(attributedString: page.attributedString ?? NSAttributedString(string: ""))
        let additions = try visibleAnnotations(on: page)
        if !additions.isEmpty {
            result.append(NSAttributedString(string: "\n\n[Text boxes and form values follow the page text in displayed reading order.]\n",
                                             attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        }
        for record in additions {
            let annotation = page.annotations[record.annotationIndex]
            result.append(NSAttributedString(string: "\n[\(record.label)]\n", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]))
            result.append(NSAttributedString(string: record.text + "\n", attributes: [
                .font: annotation.font ?? NSFont.systemFont(ofSize: 12),
                .foregroundColor: annotation.fontColor ?? NSColor.black
            ]))
        }
        return result
    }

    public static func visibleAnnotations(on page: PDFPage) throws -> [PDFPageTextRecord] {
        if let document = page.document { try PDFConversion.validate(document) }
        let crop = page.bounds(for: .cropBox)
        let transform = page.transform(for: .cropBox)
        let visible = page.annotations.enumerated().filter { _, annotation in
            annotation.shouldDisplay && MarkerCodec.finite(annotation.bounds) && annotation.bounds.intersects(crop)
                && annotation.value(forAnnotationKey: MarkerCodec.ownerKey) as? String != MarkerCodec.ownerValue
        }.sorted { lhs, rhs in
            let a = lhs.element.bounds.applying(transform), b = rhs.element.bounds.applying(transform)
            if a.maxY != b.maxY { return a.maxY > b.maxY }
            if a.minX != b.minX { return a.minX < b.minX }
            return lhs.offset < rhs.offset
        }
        return visible.compactMap { index, annotation -> PDFPageTextRecord? in
            if annotation.type == "FreeText", let value = annotation.contents, !value.isEmpty {
                return PDFPageTextRecord(text: value, label: "Text box", bounds: annotation.bounds, annotationIndex: index)
            }
            guard annotation.type == "Widget", !annotation.isPasswordField,
                  annotation.widgetFieldType == .text || annotation.widgetFieldType == .choice else { return nil }
            var values = annotation.value(forAnnotationKey: .widgetValue) as? [String]
                ?? annotation.widgetStringValue.map { [$0] } ?? []
            if annotation.widgetFieldType == .choice {
                values = values.map { value in
                    guard let index = annotation.values?.firstIndex(of: value), let choices = annotation.choices,
                          choices.indices.contains(index) else { return value }
                    return choices[index]
                }
            }
            let value = values.joined(separator: "; ")
            guard !value.isEmpty else { return nil }
            let kind = annotation.widgetFieldType == .choice ? "Choice field" : "Text field"
            let name = annotation.fieldName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return PDFPageTextRecord(text: value, label: name.isEmpty ? kind : "\(kind): \(name)",
                                     bounds: annotation.bounds, annotationIndex: index)
        }
    }
}
