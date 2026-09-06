import AppKit
import CoreText
import PDFKit

/// Embeds artwork in PDF page content using Core Graphics. Original page content stays vector/text;
/// annotations remain editable. PDFKit Stamp subclasses do not reliably persist custom images.
@MainActor
enum PDFSignatureImageAnnotation {
    static func overlay(image: CGImage, bounds: CGRect, on page: PDFPage) throws -> PDFPage {
        try overlay(on: page) { context in
            let transform = page.transform(for: .cropBox)
            let displayBounds = bounds.applying(transform)
            let ratio = min(displayBounds.width / Double(image.width), displayBounds.height / Double(image.height))
            let width = Double(image.width) * ratio, height = Double(image.height) * ratio
            context.concatenate(transform.inverted())
            context.draw(image, in: CGRect(x: displayBounds.midX - width / 2, y: displayBounds.midY - height / 2, width: width, height: height))
        }
    }

    static func overlay(text: String, color: NSColor, bounds: CGRect, on page: PDFPage) throws -> PDFPage {
        try overlay(on: page) { context in
            let transform = page.transform(for: .cropBox)
            let displayed = bounds.applying(transform)
            let font = NSFont(name: "SnellRoundhand", size: 40) ?? NSFont.systemFont(ofSize: 40)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
            let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            let scale = min((displayed.width - 4) / max(1, ink.width), (displayed.height - 4) / max(1, ink.height))
            context.concatenate(transform.inverted())
            context.translateBy(x: displayed.midX - ink.width * scale / 2, y: displayed.midY - ink.height * scale / 2)
            context.scaleBy(x: scale, y: scale)
            context.textPosition = CGPoint(x: -ink.minX, y: -ink.minY)
            CTLineDraw(line, context)
        }
    }

    private static func overlay(on page: PDFPage, drawing: (CGContext) -> Void) throws -> PDFPage {
        guard let original = page.pageRef else { throw AnnotateError.exportFailed }
        let data = NSMutableData()
        var media = page.bounds(for: .mediaBox)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw AnnotateError.exportFailed }
        context.beginPDFPage(nil)
        context.drawPDFPage(original)
        context.saveGState()
        drawing(context)
        context.restoreGState()
        context.endPDFPage()
        context.closePDF()
        guard let output = PDFDocument(data: data as Data), let replacement = output.page(at: 0) else { throw AnnotateError.exportFailed }
        for box in [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
            replacement.setBounds(page.bounds(for: box), for: box)
        }
        replacement.rotation = page.rotation
        for annotation in page.annotations {
            guard let copied = annotation.copy() as? PDFAnnotation else { throw AnnotateError.annotationWriteFailed }
            replacement.addAnnotation(copied)
            if let name = annotation.fieldName { copied.fieldName = name }
        }
        return replacement
    }
}
