import AppKit
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

@MainActor
public enum PDFConversion {
    public static let maximumInputBytes = 512 * 1_024 * 1_024
    public static let importExtensions = ["pdf", "txt", "rtf", "rtfd", "doc", "docx", "odt", "png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "bmp", "gif", "webp"]

    public static func validate(_ document: PDFDocument, needsPrinting: Bool = false, needsModification: Bool = false) throws {
        guard !document.isLocked else { throw AnnotateError.lockedDocument }
        guard document.pageCount > 0 else { throw AnnotateError.emptyDocument }
        guard document.allowsCopying, !needsPrinting || document.allowsPrinting,
              !needsModification || document.allowsDocumentChanges else { throw PDFConversionError.permissionDenied }
    }

    /// Authorize against the actual source, then detach every page and annotation from UI mutations.
    public static func snapshot(document: PDFDocument, needsPrinting: Bool = false, needsModification: Bool = false) throws -> PDFDocument {
        try validate(document, needsPrinting: needsPrinting, needsModification: needsModification)
        guard let copy = document.copy() as? PDFDocument, copy !== document, copy.pageCount == document.pageCount,
              !copy.isLocked else { throw PDFConversionError.failed }
        return copy
    }

    public static func extractedText(from document: PDFDocument) throws -> NSAttributedString {
        try validate(document)
        let output = NSMutableAttributedString(string: "")
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { throw AnnotateError.invalidPage(index) }
            if index > 0 { output.append(NSAttributedString(string: "\n\u{000C}\n")) }
            output.append(try PDFPageText.attributedText(from: page))
        }
        guard !output.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PDFConversionError.noText }
        return output
    }

    public static func exportData(document: PDFDocument, format: PDFConversionFormat) throws -> Data {
        guard !format.isImage else { throw PDFConversionError.failed }
        if format == .pdf {
            try validate(document, needsPrinting: true)
            guard let data = document.dataRepresentation() else { throw PDFConversionError.failed }
            return data
        }
        if format == .xlsx { return try PDFOfficeExporter.spreadsheet(document) }
        if format == .pptx { return try PDFOfficeExporter.presentation(document) }
        let text = try extractedText(from: document)
        if format == .text { return Data(text.string.utf8) }
        let type: NSAttributedString.DocumentType
        switch format {
        case .docx: type = .officeOpenXML
        case .doc: type = .docFormat
        case .odt: type = .openDocument
        case .rtf: type = .rtf
        case .html: type = .html
        default: throw PDFConversionError.failed
        }
        return try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [
            .documentType: type, .characterEncoding: String.Encoding.utf8.rawValue
        ])
    }

    public static func compressedData(document: PDFDocument, level: PDFCompressionLevel, originalBytes: Int? = nil) throws -> PDFCompressionResult {
        try validate(document, needsPrinting: true, needsModification: true)
        guard let source = document.dataRepresentation() else { throw PDFConversionError.failed }
        // These options rewrite image resources; they do not rasterize the page or remove forms and annotations.
        let options: [PDFDocumentWriteOption: Any] = [
            .saveImagesAsJPEGOption: level != .lossless,
            .optimizeImagesForScreenOption: level == .compact
        ]
        guard let data = document.dataRepresentation(options: options),
              let result = PDFDocument(data: data), result.pageCount == document.pageCount else { throw PDFConversionError.failed }
        return PDFCompressionResult(data: data, originalBytes: originalBytes ?? source.count)
    }

    public static func displayedSize(of page: PDFPage) throws -> CGSize {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0,
              bounds.width <= 100_000, bounds.height <= 100_000 else { throw PDFConversionError.invalidPage }
        return abs(page.rotation % 180) == 90 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
    }

    public static func renderedImage(page: PDFPage, scale: Double = 2) throws -> CGImage {
        if let document = page.document { try validate(document, needsPrinting: true) }
        let size = try displayedSize(of: page)
        guard scale.isFinite, scale >= 0.5, scale <= 4 else { throw PDFConversionError.invalidPage }
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 32_000_000 else { throw PDFConversionError.invalidPage }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PDFConversionError.invalidImage }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        drawVisiblePage(page, to: context)
        guard let image = context.makeImage() else { throw PDFConversionError.invalidImage }
        return image
    }

    static func drawVisiblePage(_ page: PDFPage, to context: CGContext) {
        let oldValue = page.displaysAnnotations
        page.displaysAnnotations = true
        context.saveGState()
        defer {
            context.restoreGState()
            page.displaysAnnotations = oldValue
        }
        page.draw(with: .cropBox, to: context)
    }

    public static func imageData(page: PDFPage, format: PDFConversionFormat, scale: Double = 2) throws -> Data {
        guard format.isImage else { throw PDFConversionError.invalidImage }
        let image = try renderedImage(page: page, scale: scale)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, format.contentType.identifier as CFString, 1, nil) else {
            throw PDFConversionError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PDFConversionError.invalidImage }
        return output as Data
    }

    public static func importDocument(from url: URL) throws -> PDFDocument {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        guard (values.fileSize ?? 0) <= maximumInputBytes else { throw PDFConversionError.inputTooLarge }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let document = PDFDocument(url: url) else { throw PDFConversionError.failed }
            try validate(document, needsPrinting: true)
            return document
        }
        let documentType: NSAttributedString.DocumentType?
        switch ext {
        case "txt": documentType = .plain
        case "rtf": documentType = .rtf
        case "rtfd": documentType = .rtfd
        case "doc": documentType = .docFormat
        case "docx": documentType = .officeOpenXML
        case "odt": documentType = .openDocument
        default: documentType = nil
        }
        if let documentType {
            let text = try NSAttributedString(url: url, options: [.documentType: documentType], documentAttributes: nil)
            return try textDocument(text)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw PDFConversionError.unsupportedInput(url.lastPathComponent)
        }
        let document = PDFDocument()
        let frameCount = CGImageSourceGetCount(source)
        // TIFF pages are individual document pages; animated image files import their first frame.
        let count = ["tif", "tiff"].contains(ext) ? frameCount : 1
        guard count <= 10_000 else { throw PDFConversionError.inputTooLarge }
        for index in 0..<count {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 8_192]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
                  let page = PDFPage(image: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))) else {
                throw PDFConversionError.invalidImage
            }
            document.insert(page, at: document.pageCount)
        }
        return document
    }

    public static func textDocument(_ attributedText: NSAttributedString) throws -> PDFDocument {
        let text = NSMutableAttributedString(attributedString: attributedText)
        if text.length == 0 { text.append(NSAttributedString(string: " ")) }
        let fullRange = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            if value == nil { text.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: range) }
        }
        text.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            if value == nil { text.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &media, [kCGPDFContextCreator: "Annotate"] as CFDictionary) else {
            throw PDFConversionError.failed
        }
        var laidOutGlyphs = 0
        var pageCount = 0
        repeat {
            let container = NSTextContainer(size: CGSize(width: 516, height: 696))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            let glyphs = layout.glyphRange(for: container)
            guard glyphs.length > 0, NSMaxRange(glyphs) > laidOutGlyphs, pageCount < 10_000 else {
                context.closePDF()
                throw PDFConversionError.failed
            }
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(media)
            context.saveGState()
            context.translateBy(x: 0, y: media.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            layout.drawBackground(forGlyphRange: glyphs, at: CGPoint(x: 48, y: 48))
            layout.drawGlyphs(forGlyphRange: glyphs, at: CGPoint(x: 48, y: 48))
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
            laidOutGlyphs = NSMaxRange(glyphs)
            pageCount += 1
        } while laidOutGlyphs < layout.numberOfGlyphs
        context.closePDF()
        guard let document = PDFDocument(data: data as Data), document.pageCount > 0 else { throw PDFConversionError.failed }
        return document
    }
}
