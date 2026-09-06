import AppKit
import PDFKit

/// Visible electronic signatures. These do not establish certificate identity or cryptographic integrity.
@MainActor
public enum PDFSignatureEditor {
    public static let ownerKey = PDFAnnotationKey(rawValue: "/AnnotateElectronicSignature")

    public static func typed(_ text: String, in document: PDFDocument, regions: [PageRegion], color: NSColor = .black) throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 200 else { throw PDFSignatureError.emptySignature }
        let pages = try validate(regions, in: document)
        if pages.contains(where: { $0.rotation % 360 != 0 }), !document.allowsDocumentChanges { throw PDFFormError.creationRestricted }
        for (page, region) in zip(pages, regions) {
            if page.rotation % 360 != 0 {
                guard let current = document.page(at: region.pageIndex) else { throw AnnotateError.invalidPage(region.pageIndex) }
                let replacement = try PDFSignatureImageAnnotation.overlay(text: clean, color: color, bounds: region.bounds, on: current)
                document.removePage(at: region.pageIndex)
                document.insert(replacement, at: region.pageIndex)
                continue
            }
            let annotation = PDFAnnotation(bounds: region.bounds, forType: .freeText, withProperties: nil)
            let font = NSFont(name: "SnellRoundhand", size: 40) ?? NSFont.systemFont(ofSize: 40)
            let measured = (clean as NSString).size(withAttributes: [.font: font])
            let scale = min((region.bounds.width - 4) / max(1, measured.width), (region.bounds.height - 4) / max(1, measured.height))
            let fittedFont = NSFont(descriptor: font.fontDescriptor, size: max(1, 40 * scale)) ?? font
            annotation.font = fittedFont
            annotation.fontColor = color
            annotation.color = .clear
            annotation.contents = clean
            annotation.alignment = .center
            let border = PDFBorder()
            border.lineWidth = 0
            annotation.border = border
            identify(annotation)
            page.addAnnotation(annotation)
            PDFContentEditor.setTextAppearance(annotation, font: fittedFont, color: color)
        }
    }

    /// Strokes use normalized top-left coordinates in the signature drawing area.
    public static func drawn(_ strokes: [[CGPoint]], in document: PDFDocument, regions: [PageRegion], color: NSColor = .black) throws {
        guard strokes.contains(where: { $0.count >= 2 }), strokes.flatMap({ $0 }).allSatisfy({
            $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)
        }) else { throw PDFSignatureError.emptySignature }
        let pages = try validate(regions, in: document)
        for (page, region) in zip(pages, regions) {
            let annotation = PDFAnnotation(bounds: region.bounds, forType: .ink, withProperties: nil)
            annotation.color = color
            let border = PDFBorder()
            border.lineWidth = 1.5
            annotation.border = border
            let transform = page.transform(for: .cropBox)
            let displayed = region.bounds.applying(transform)
            for stroke in strokes where stroke.count >= 2 {
                let path = NSBezierPath()
                for (index, point) in stroke.enumerated() {
                    let displayedPoint = CGPoint(x: displayed.minX + 2 + point.x * (displayed.width - 4), y: displayed.minY + 2 + (1 - point.y) * (displayed.height - 4))
                    let pagePoint = displayedPoint.applying(transform.inverted())
                    let local = CGPoint(x: pagePoint.x - region.bounds.minX, y: pagePoint.y - region.bounds.minY)
                    if index == 0 { path.move(to: local) } else { path.line(to: local) }
                }
                annotation.add(path)
            }
            identify(annotation)
            page.addAnnotation(annotation)
        }
    }

    public static func image(_ image: NSImage, in document: PDFDocument, regions: [PageRegion]) throws {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard image.size.width > 0, image.size.height > 0,
              let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { throw PDFSignatureError.invalidImage }
        _ = try validate(regions, in: document)
        guard document.allowsDocumentChanges else { throw PDFFormError.creationRestricted }
        // Prepare every output page before mutating the document. Repeated regions on one page
        // accumulate against the previous prepared page rather than dropping earlier signatures.
        var prepared: [Int: PDFPage] = [:]
        for region in regions {
            guard let page = prepared[region.pageIndex] ?? document.page(at: region.pageIndex) else { throw AnnotateError.invalidPage(region.pageIndex) }
            prepared[region.pageIndex] = try PDFSignatureImageAnnotation.overlay(image: cgImage, bounds: region.bounds, on: page)
        }
        for (index, page) in prepared.sorted(by: { $0.key < $1.key }) {
            document.removePage(at: index)
            document.insert(page, at: index)
        }
    }

    private static func validate(_ regions: [PageRegion], in document: PDFDocument) throws -> [PDFPage] {
        guard !document.isLocked else { throw AnnotateError.lockedDocument }
        guard document.allowsCommenting else { throw AnnotateError.commentingNotAllowed }
        guard !regions.isEmpty else { throw PDFSignatureError.emptySignature }
        return try regions.map { try PDFFormEditor.validate($0, in: document) }
    }

    private static func identify(_ annotation: PDFAnnotation) {
        annotation.setValue("electronic-v1", forAnnotationKey: ownerKey)
        annotation.userName = "Annotate electronic signature"
        annotation.shouldDisplay = true
        annotation.shouldPrint = true
        annotation.modificationDate = .now
    }
}
