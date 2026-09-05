import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit

@MainActor
public enum PDFExporter {
    /// Creates an ordinary PDF whose visible annotations are page drawing commands.
    /// Text and vector artwork remain vector content when supported by the source PDF.
    /// Full marker text is appended because a flattened sticky note cannot be opened.
    public static func flattenedData(document: PDFDocument, markers: [PDFMarker], includeNotes: Bool = true) throws -> Data {
        guard !document.isLocked else { throw AnnotateError.lockedDocument }
        guard document.allowsPrinting, document.allowsCopying else { throw AnnotateError.exportNotAllowed }
        guard document.pageCount > 0 else { throw AnnotateError.emptyDocument }
        for marker in markers { try MarkerCodec.validate(marker, in: document) }

        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { throw AnnotateError.exportFailed }
        let attributes: [String: Any] = [
            kCGPDFContextCreator as String: "Annotate",
            kCGPDFContextTitle as String: "Annotated PDF"
        ]
        guard let context = CGContext(consumer: consumer, mediaBox: nil, attributes as CFDictionary) else {
            throw AnnotateError.exportFailed
        }

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { throw AnnotateError.invalidPage(index) }
            let bounds = page.bounds(for: .cropBox)
            guard MarkerCodec.finite(bounds), bounds.width > 0, bounds.height > 0,
                  bounds.width <= 1_000_000, bounds.height <= 1_000_000 else { throw AnnotateError.invalidPage(index) }
            let quarterTurn = abs(page.rotation % 180) == 90
            let size = quarterTurn ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
            let outputBounds = CGRect(origin: .zero, size: size)
            beginPage(in: context, bounds: outputBounds)
            context.saveGState()
            context.setFillColor(NSColor.white.cgColor)
            context.fill(outputBounds)
            // PDFPage performs the crop-origin translation and page rotation itself.
            // A PDF CGContext records its content and annotation drawing as vectors;
            // it never copies source annotation dictionaries into the exported page.
            let wasDisplayingAnnotations = page.displaysAnnotations
            page.displaysAnnotations = true
            page.draw(with: .cropBox, to: context)
            page.displaysAnnotations = wasDisplayingAnnotations
            context.restoreGState()
            context.endPDFPage()
        }

        if includeNotes {
            let existing = existingComments(in: document, excluding: markers)
            if !markers.isEmpty || !existing.isEmpty {
                try appendIndex(MarkerCodec.ordered(markers, in: document), existing: existing, to: context)
            }
        }
        context.closePDF()
        guard output.length > 0, let result = PDFDocument(data: output as Data), result.pageCount >= document.pageCount else {
            throw AnnotateError.exportFailed
        }
        // Fail visibly if the system renderer ever starts carrying interactive objects
        // through this drawing route; this method promises a flattened share copy.
        for index in 0..<result.pageCount {
            guard let page = result.page(at: index), page.annotations.isEmpty else { throw AnnotateError.exportFailed }
        }
        return output as Data
    }

    private static func beginPage(in context: CGContext, bounds: CGRect) {
        var box = bounds
        let data = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox as String: data] as CFDictionary)
    }

    private struct ExistingComment {
        var pageIndex: Int
        var text: String
    }

    private static func existingComments(in document: PDFDocument, excluding markers: [PDFMarker]) -> [ExistingComment] {
        let knownIDs = Set(markers.map(\.id))
        var comments: [ExistingComment] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let parentComments = Set(page.annotations.filter { $0.type != "Popup" }.compactMap(\.contents))
            for annotation in page.annotations {
                if annotation.value(forAnnotationKey: MarkerCodec.ownerKey) as? String == MarkerCodec.ownerValue,
                   let rawID = annotation.value(forAnnotationKey: MarkerCodec.identifierKey) as? String,
                   let id = UUID(uuidString: rawID), knownIDs.contains(id) { continue }
                guard let contents = annotation.contents,
                      !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                // Keep standalone popup text, but avoid repeating an identical
                // comment already carried by its ordinary annotation on this page.
                if annotation.type == "Popup", parentComments.contains(contents) { continue }
                comments.append(ExistingComment(pageIndex: index, text: contents))
            }
        }
        return comments
    }

    private static func appendIndex(_ markers: [PDFMarker], existing: [ExistingComment], to context: CGContext) throws {
        let text = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 8
        paragraph.lineBreakMode = .byWordWrapping
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ]
        let heading: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ]
        for (index, marker) in markers.enumerated() {
            let pages = Set(marker.regions.map { $0.pageIndex + 1 }).sorted().map(String.init).joined(separator: ", ")
            let pageLabel = Set(marker.regions.map(\.pageIndex)).count == 1 ? "Page" : "Pages"
            let categories = MarkerCategory.allCases.filter { marker.categories.contains($0) }.map(\.title).joined(separator: " · ")
            text.append(NSAttributedString(string: "\(index + 1). \(categories) — \(pageLabel) \(pages)\n", attributes: heading))
            if !marker.quote.isEmpty { text.append(NSAttributedString(string: "Passage: \(marker.quote)\n", attributes: body)) }
            if !marker.note.isEmpty { text.append(NSAttributedString(string: "Note: \(marker.note)\n", attributes: body)) }
            if !marker.question.isEmpty { text.append(NSAttributedString(string: "Question: \(marker.question)\n", attributes: body)) }
            if marker.quote.isEmpty, marker.note.isEmpty, marker.question.isEmpty {
                text.append(NSAttributedString(string: "Location marker\n", attributes: body))
            }
            text.append(NSAttributedString(string: "\n", attributes: body))
        }
        for (offset, comment) in existing.enumerated() {
            text.append(NSAttributedString(string: "\(markers.count + offset + 1). Existing annotation — Page \(comment.pageIndex + 1)\n", attributes: heading))
            text.append(NSAttributedString(string: comment.text + "\n\n", attributes: body))
        }
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let bodyBounds = CGRect(x: 48, y: 52, width: 516, height: 662)
        var cursor = 0
        var indexPage = 1
        while cursor < text.length {
            let path = CGPath(rect: bodyBounds, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: cursor, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0, visible.location == cursor else { throw AnnotateError.exportFailed }
            beginPage(in: context, bounds: bounds)
            context.saveGState()
            context.setFillColor(NSColor.white.cgColor)
            context.fill(bounds)
            drawLine("Annotation index", at: CGPoint(x: 48, y: 744), font: .systemFont(ofSize: 21, weight: .bold), context: context)
            drawLine("Original document page numbers are listed with each marker.", at: CGPoint(x: 48, y: 726), font: .systemFont(ofSize: 9), context: context)
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
            drawLine("Annotate · Index \(indexPage)", at: CGPoint(x: 48, y: 28), font: .systemFont(ofSize: 9), context: context)
            context.restoreGState()
            context.endPDFPage()
            cursor += visible.length
            indexPage += 1
        }
    }

    private static func drawLine(_ text: String, at point: CGPoint, font: NSFont, context: CGContext) {
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        context.textMatrix = .identity
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
