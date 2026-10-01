import AppKit
import CoreGraphics
import PDFKit

public enum PDFContentError: LocalizedError {
    case permission, invalidArea, tooLarge, renderingFailed, emptyText
    public var errorDescription: String? {
        switch self {
        case .permission: "This PDF does not permit this editing or export operation."
        case .invalidArea: "Select a valid area inside one PDF page."
        case .tooLarge: "This page exceeds the safe image size for this operation."
        case .renderingFailed: "The edited PDF page could not be rendered."
        case .emptyText: "Enter text to place on the page."
        }
    }
}

/// Region replacement and sanitization never hide source content beneath a PDF rectangle.
/// Removed pixels are overwritten in an RGBA bitmap before a new PDF image is created.
@MainActor
public enum PDFContentEditor {
    public static let editIDKey = PDFAnnotationKey(rawValue: "AnnotateEditID")

    public static func checkedPage(_ region: PageRegion, in document: PDFDocument) throws -> PDFPage {
        guard !document.isLocked, let page = document.page(at: region.pageIndex),
              MarkerCodec.finite(region.bounds), region.bounds.width >= 1, region.bounds.height >= 1,
              page.bounds(for: .cropBox).contains(region.bounds) else { throw PDFContentError.invalidArea }
        return page
    }

    @discardableResult
    public static func addText(_ text: String, in region: PageRegion, document: PDFDocument,
                               font: NSFont, color: NSColor, identifier: String = UUID().uuidString) throws -> PDFAnnotation {
        guard document.allowsCommenting, !document.isLocked else { throw PDFContentError.permission }
        let page = try checkedPage(region, in: document)
        let annotation = PDFAnnotation(bounds: region.bounds, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = font
        annotation.fontColor = color
        annotation.color = .clear
        let border = PDFBorder(); border.lineWidth = 0; annotation.border = border
        annotation.shouldPrint = true
        annotation.setValue(identifier, forAnnotationKey: editIDKey)
        page.addAnnotation(annotation)
        setTextAppearance(annotation, font: font, color: color)
        return annotation
    }

    /// PDFKit writes an appearance stream but does not consistently write /DA from font setters.
    /// Preserve the standard editable appearance description so other readers recover font and size.
    public static func setTextAppearance(_ annotation: PDFAnnotation, font: NSFont, color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        let name = font.fontName.hasPrefix(".") ? "Helvetica" : font.fontName
        let pdfName = name.utf8.map { byte -> String in
            if (33...126).contains(byte), ![UInt8(35), 37, 40, 41, 47, 60, 62, 91, 93, 123, 125].contains(byte) {
                return String(UnicodeScalar(byte))
            }
            let hex = String(byte, radix: 16, uppercase: true)
            return "#" + (hex.count == 1 ? "0" : "") + hex
        }.joined()
        // Leading whitespace prevents AnnotationKit from treating a slash-leading NSString as a PDF Name.
        annotation.setValue(" /\(pdfName) \(font.pointSize) Tf \(rgb.redComponent) \(rgb.greenComponent) \(rgb.blueComponent) rg", forAnnotationKey: .defaultAppearance)
    }

    public static func addMarkup(_ subtype: PDFAnnotationSubtype, regions: [PageRegion], document: PDFDocument,
                                 color: NSColor, lineWidth: Double = 2) throws {
        guard document.allowsCommenting, !document.isLocked else { throw PDFContentError.permission }
        for region in regions { _ = try checkedPage(region, in: document) }
        for region in regions {
            let page = try checkedPage(region, in: document)
            let annotation = PDFAnnotation(bounds: region.bounds, forType: subtype, withProperties: nil)
            annotation.color = color
            let border = PDFBorder(); border.lineWidth = min(30, max(0.5, lineWidth)); annotation.border = border
            annotation.shouldPrint = true
            annotation.setValue(UUID().uuidString, forAnnotationKey: editIDKey)
            page.addAnnotation(annotation)
        }
    }

    /// Rebuilds only the affected page, removing the selected source content. Other pages remain intact.
    /// The affected page's original text layer and foreign interactive annotations become pixels.
    /// Owned markers outside the replacement area retain their metadata and adjusted coordinates.
    public static func replaceArea(_ region: PageRegion, in document: PDFDocument,
                                   fill: NSColor = .white, image: NSImage? = nil) throws -> PageRegion {
        guard document.allowsDocumentChanges, document.allowsPrinting, document.allowsCopying else {
            throw PDFContentError.permission
        }
        let source = try checkedPage(region, in: document)
        let transform = source.transform(for: .cropBox)
        var markers = MarkerCodec.markers(in: document)
        let owned = source.annotations.filter { $0.value(forAnnotationKey: MarkerCodec.ownerKey) as? String == MarkerCodec.ownerValue }
        let visibility = owned.map(\.shouldDisplay)
        for annotation in owned { annotation.shouldDisplay = false }
        let rendered: (CGImage, CGSize)
        do {
            rendered = try raster(source, erase: [region.bounds], fill: fill, replacement: image, scale: 2)
        } catch {
            for (annotation, visible) in zip(owned, visibility) { annotation.shouldDisplay = visible }
            throw error
        }
        for (annotation, visible) in zip(owned, visibility) { annotation.shouldDisplay = visible }
        let bytes = try imagePDF([(rendered.0, rendered.1)])
        guard let replacement = PDFDocument(data: bytes)?.page(at: 0) else { throw PDFContentError.renderingFailed }
        // Remove metadata first, including repeated metadata on other pages of multipage markers.
        for marker in markers { MarkerCodec.remove(id: marker.id, from: document) }
        document.removePage(at: region.pageIndex)
        document.insert(replacement, at: region.pageIndex)
        for index in markers.indices {
            let before = markers[index].regions.count
            markers[index].regions = markers[index].regions.compactMap { old in
                guard old.pageIndex == region.pageIndex else { return old }
                guard !old.bounds.intersects(region.bounds) else { return nil }
                return PageRegion(pageIndex: old.pageIndex, bounds: old.bounds.applying(transform))
            }
            // A marker that touched the erased area no longer quotes it: the quote would
            // keep the erased words in the file's marker metadata and comment.
            if markers[index].regions.count < before { markers[index].quote = "" }
            if !markers[index].regions.isEmpty { try MarkerCodec.apply(markers[index], to: document) }
        }
        return PageRegion(pageIndex: region.pageIndex, bounds: region.bounds.applying(transform))
    }

    /// Entirely fresh image-only output. No source dictionaries, text, metadata or attachments are copied.
    public static func redactedData(document: PDFDocument, regions: [PageRegion], scale: Double = 2) throws -> Data {
        guard !document.isLocked, document.allowsCopying, document.allowsPrinting else { throw PDFContentError.permission }
        guard !regions.isEmpty, document.pageCount > 0 else { throw PDFContentError.invalidArea }
        for region in regions { _ = try checkedPage(region, in: document) }
        // Stream pages to the PDF context instead of retaining the whole document as decoded bitmaps.
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw PDFContentError.renderingFailed }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { throw PDFContentError.invalidArea }
            let (image, size) = try raster(page, erase: regions.filter { $0.pageIndex == index }.map(\.bounds), fill: .black, scale: scale)
            drawImagePage(image, size: size, into: context)
        }
        context.closePDF()
        guard let result = PDFDocument(data: output as Data), result.pageCount == document.pageCount,
              (0..<result.pageCount).allSatisfy({ result.page(at: $0)?.annotations.isEmpty == true }) else {
            throw PDFContentError.renderingFailed
        }
        return output as Data
    }

    /// Responsive counterpart for the application. A detached snapshot prevents native widget changes
    /// between yields from changing later pages of the same exported copy.
    public static func redactedData(document source: PDFDocument, regions: [PageRegion], scale: Double = 2,
                                    progress: (_ completed: Int, _ total: Int) -> Void) async throws -> Data {
        let document = try PDFConversion.snapshot(document: source, needsPrinting: true)
        guard !regions.isEmpty else { throw PDFContentError.invalidArea }
        for region in regions { _ = try checkedPage(region, in: document) }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw PDFContentError.renderingFailed }
        var closed = false
        defer { if !closed { context.closePDF() } }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            progress(index, document.pageCount)
            guard let page = document.page(at: index) else { throw PDFContentError.invalidArea }
            let (image, size) = try raster(page, erase: regions.filter { $0.pageIndex == index }.map(\.bounds), fill: .black, scale: scale)
            drawImagePage(image, size: size, into: context)
            progress(index + 1, document.pageCount)
            await Task.yield()
        }
        try Task.checkCancellation()
        context.closePDF()
        closed = true
        guard let result = PDFDocument(data: output as Data), result.pageCount == document.pageCount,
              (0..<result.pageCount).allSatisfy({ result.page(at: $0)?.annotations.isEmpty == true }) else {
            throw PDFContentError.renderingFailed
        }
        return output as Data
    }

    static func raster(_ page: PDFPage, erase: [CGRect], fill: NSColor, replacement: NSImage? = nil,
                       scale: Double) throws -> (CGImage, CGSize) {
        let box = page.bounds(for: .cropBox)
        guard MarkerCodec.finite(box), box.width > 0, box.height > 0, scale.isFinite, scale >= 1, scale <= 4 else {
            throw PDFContentError.invalidArea
        }
        let rotated = abs(page.rotation % 180) == 90
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let width = ceil(size.width * scale), height = ceil(size.height * scale)
        guard width <= 16384, height <= 16384, width * height <= 40_000_000 else { throw PDFContentError.tooLarge }
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PDFContentError.renderingFailed }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        let show = page.displaysAnnotations
        page.displaysAnnotations = true
        page.draw(with: .cropBox, to: context)
        page.displaysAnnotations = show
        let transform = page.transform(for: .cropBox)
        // Expand by one pixel and disable antialiasing so boundaries cannot retain source edge pixels.
        context.setShouldAntialias(false)
        context.setBlendMode(.copy)
        for area in erase {
            let target = area.applying(transform).insetBy(dx: -1 / scale, dy: -1 / scale)
            context.setFillColor(fill.cgColor)
            context.fill(target)
            if let replacement {
                var proposed = CGRect(origin: .zero, size: replacement.size)
                guard let cg = replacement.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
                    throw PDFContentError.renderingFailed
                }
                context.setBlendMode(.normal)
                context.draw(cg, in: area.applying(transform))
                context.setBlendMode(.copy)
            }
        }
        guard let image = context.makeImage() else { throw PDFContentError.renderingFailed }
        return (image, size)
    }

    static func imagePDF(_ images: [(CGImage, CGSize)]) throws -> Data {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw PDFContentError.renderingFailed }
        for (image, size) in images { drawImagePage(image, size: size, into: context) }
        context.closePDF()
        return output as Data
    }

    private static func drawImagePage(_ image: CGImage, size: CGSize, into context: CGContext) {
        var box = CGRect(origin: .zero, size: size)
        let media = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox as String: media] as CFDictionary)
        context.draw(image, in: box)
        context.endPDFPage()
    }
}
