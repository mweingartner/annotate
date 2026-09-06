import AppKit
import CoreGraphics
import CoreText
import PDFKit
import Vision

public struct PDFOCRResult: Sendable {
    public let data: Data
    public let text: String
    public let recognizedPageCount: Int
    public let retainedTextPageCount: Int
    public let recognizedLineCount: Int
}

public struct PDFOCROptions: Sendable {
    public var languages: [String]
    public var recognizeEveryPage: Bool
    public init(languages: [String] = [], recognizeEveryPage: Bool = false) {
        self.languages = languages
        self.recognizeEveryPage = recognizeEveryPage
    }
}

@MainActor
public enum PDFOCR {
    /// Produces a separate searchable PDF. The default retains vector content and existing selectable text.
    /// Interactive annotations become visible page content, matching a printed copy.
    public static func recognize(document sourceDocument: PDFDocument, options: PDFOCROptions = PDFOCROptions(),
                                 progress: ((_ completed: Int, _ total: Int) -> Void)? = nil) async throws -> PDFOCRResult {
        let document = try PDFConversion.snapshot(document: sourceDocument, needsPrinting: true)
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, [kCGPDFContextCreator: "Annotate · Apple Vision OCR"] as CFDictionary) else {
            throw PDFConversionError.failed
        }
        var closed = false
        defer { if !closed { context.closePDF() } }
        let recognizer = PDFOCRRecognizer()
        var recognizedPages = 0
        var retainedPages = 0
        var recognizedLines = 0
        var texts: [String] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            progress?(index, document.pageCount)
            guard let page = document.page(at: index) else { throw AnnotateError.invalidPage(index) }
            let size = try PDFConversion.displayedSize(of: page)
            let existing = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var lines: [PDFOCRLine] = []
            var scan: CGImage?
            let cropSize = page.bounds(for: .cropBox).size
            let rotation = ((page.rotation % 360) + 360) % 360
            guard [0, 90, 180, 270].contains(rotation) else { throw PDFConversionError.invalidPage }
            if existing.isEmpty || options.recognizeEveryPage {
                // Recognize in the original crop orientation, then rotate the invisible text with the source page.
                // This also handles PDFs whose /Rotate is a quarter turn without making the words unrecognizable.
                let originalRotation = page.rotation
                page.rotation = 0
                do { scan = try PDFConversion.renderedImage(page: page, scale: 2) }
                catch { page.rotation = originalRotation; throw error }
                page.rotation = originalRotation
                if let scan { lines = try await recognizer.recognize(image: scan, languages: options.languages) }
                recognizedPages += 1
                recognizedLines += lines.count
                texts.append(lines.map(\.text).joined(separator: "\n"))
            } else {
                retainedPages += 1
                texts.append(existing)
            }
            var bounds = CGRect(origin: .zero, size: size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &bounds, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(bounds)
            if options.recognizeEveryPage, let scan {
                context.saveGState()
                applyPageRotation(rotation, cropSize: cropSize, to: context)
                context.draw(scan, in: CGRect(origin: .zero, size: cropSize))
                context.restoreGState()
            } else {
                PDFConversion.drawVisiblePage(page, to: context)
            }
            context.saveGState()
            applyPageRotation(rotation, cropSize: cropSize, to: context)
            for line in lines {
                let box = CGRect(x: line.bounds.minX * cropSize.width, y: line.bounds.minY * cropSize.height,
                                 width: line.bounds.width * cropSize.width, height: line.bounds.height * cropSize.height)
                drawInvisibleText(line.text, in: box, context: context)
            }
            context.restoreGState()
            context.endPDFPage()
            progress?(index + 1, document.pageCount)
            await Task.yield()
        }
        context.closePDF()
        closed = true
        guard let result = PDFDocument(data: output as Data), result.pageCount == document.pageCount else {
            throw PDFConversionError.failed
        }
        return PDFOCRResult(data: output as Data, text: texts.joined(separator: "\n\u{000C}\n"),
                            recognizedPageCount: recognizedPages, retainedTextPageCount: retainedPages,
                            recognizedLineCount: recognizedLines)
    }

    private static func applyPageRotation(_ rotation: Int, cropSize: CGSize, to context: CGContext) {
        switch rotation {
        case 90:
            context.translateBy(x: 0, y: cropSize.width)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: cropSize.width, y: cropSize.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: cropSize.height, y: 0)
            context.rotate(by: .pi / 2)
        default: break
        }
    }

    private static func drawInvisibleText(_ text: String, in rect: CGRect, context: CGContext) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        guard bounds.width > 0, bounds.height > 0 else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / bounds.width, y: rect.height / bounds.height)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: -bounds.minX, y: -bounds.minY)
        context.setTextDrawingMode(.invisible)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
