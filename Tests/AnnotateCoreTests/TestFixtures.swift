import AppKit
import CoreText
import PDFKit
import Testing
@testable import AnnotateCore

@MainActor
enum Fixtures {
    static func document() throws -> PDFDocument {
        let document = SamplePDF.make()
        #expect(document.pageCount == 4)
        return document
    }

    static func marker(in document: PDFDocument, text: String = "attention", note: String = "Check the original evidence.", question: String = "What would change this conclusion?") throws -> PDFMarker {
        let selection = try #require(document.findString(text, withOptions: .caseInsensitive).first)
        return PDFMarker(categories: [.important, .revisit],
            color: MarkerColor(red: 0.95, green: 0.68, blue: 0.16), icon: "star.fill",
            quote: selection.string ?? text, note: note, question: question,
            regions: MarkerCodec.regions(for: selection, in: document),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    static func annotations(in document: PDFDocument) -> [PDFAnnotation] {
        (0..<document.pageCount).flatMap { document.page(at: $0)?.annotations ?? [] }
    }

    static func reopen(_ document: PDFDocument) throws -> PDFDocument {
        let data = try #require(document.dataRepresentation())
        return try #require(PDFDocument(data: data))
    }

    static func foreignAnnotation(on page: PDFPage) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: CGRect(x: 300, y: 100, width: 25, height: 25), forType: .text, withProperties: nil)
        annotation.contents = "Another reader's annotation — preserve this."
        annotation.userName = "An external reader"
        page.addAnnotation(annotation)
        return annotation
    }

    static func geometryDocument(rotation: Int, crop: CGRect) throws -> PDFDocument {
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 400, height: 500)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(media)
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 75, y: 115, width: 40, height: 30))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 265, y: 365, width: 35, height: 25))
        context.textPosition = CGPoint(x: 100, y: 255)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Rotation sentinel", attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black
        ])), context)
        context.endPDFPage()
        context.closePDF()
        let document = try #require(PDFDocument(data: data as Data))
        let page = try #require(document.page(at: 0))
        page.setBounds(crop, for: .cropBox)
        page.rotation = rotation
        return try reopen(document)
    }

    static func redBounds(in page: PDFPage) throws -> CGRect {
        let image = page.thumbnail(of: CGSize(width: 300, height: 300), for: .cropBox)
        var proposed = CGRect(origin: .zero, size: image.size)
        let cgImage = try #require(image.cgImage(forProposedRect: &proposed, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.redComponent > 0.8, color.greenComponent < 0.3, color.blueComponent < 0.3 else { continue }
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        #expect(maxX >= minX && maxY >= minY, "The visible red sentinel must survive export.")
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
