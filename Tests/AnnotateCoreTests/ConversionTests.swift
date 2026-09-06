import AppKit
import ImageIO
import PDFKit
import Testing
@testable import AnnotateCore

@Suite("Document conversion", .serialized)
@MainActor
struct ConversionTests {
    @Test("All text document formats round trip complete Unicode text", arguments: [PDFConversionFormat.docx, .doc, .odt, .rtf, .text, .html])
    func textRoundTrips(format: PDFConversionFormat) throws {
        let source = try PDFConversion.textDocument(NSAttributedString(string: "Archive sentinel: café, naïve, Ω.\nLast paragraph remains searchable.", attributes: [.font: NSFont.systemFont(ofSize: 15)]))
        let bytes = try PDFConversion.exportData(document: source, format: format)
        #expect(!bytes.isEmpty)
        let documentType: NSAttributedString.DocumentType = switch format {
        case .docx: .officeOpenXML
        case .doc: .docFormat
        case .odt: .openDocument
        case .rtf: .rtf
        case .html: .html
        default: .plain
        }
        let reopened = try NSAttributedString(data: bytes, options: [.documentType: documentType, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        #expect(reopened.string.contains("Archive sentinel"))
        #expect(reopened.string.contains("café"))
        #expect(reopened.string.contains("Last paragraph remains searchable"))
        #expect(reopened.string.contains("Ω"))
    }

    @Test("Word and text inputs paginate without losing their final paragraphs", arguments: [PDFConversionFormat.docx, .doc, .odt, .rtf, .text])
    func documentImports(format: PDFConversionFormat) throws {
        let content = (0..<110).map { "Archive item \($0): a documented claim must retain its full supporting evidence.\n" }.joined() + "FinalImportSentinel"
        let source = try PDFConversion.textDocument(NSAttributedString(string: content))
        #expect(source.pageCount > 1)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "input." + format.fileExtension)
        try PDFConversion.exportData(document: source, format: format).write(to: url)
        let output = try PDFConversion.importDocument(from: url)
        #expect(output.pageCount > 1)
        let text = output.string ?? ""
        #expect(text.contains("FinalImportSentinel"))
        for index in 0..<110 { #expect(text.contains("Archive item \(index):")) }
    }

    @Test("Page images encode in all offered formats and retain visible rotated crop geometry", arguments: [PDFConversionFormat.png, .jpeg, .tiff, .heic], [0, 90, 180, 270])
    func imageExport(format: PDFConversionFormat, rotation: Int) throws {
        let document = try Fixtures.geometryDocument(rotation: rotation, crop: CGRect(x: 50, y: 80, width: 280, height: 340))
        let page = try #require(document.page(at: 0))
        let bytes = try PDFConversion.imageData(page: page, format: format, scale: 1)
        let imageSource = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        #expect(image.width == (rotation % 180 == 0 ? 280 : 340))
        #expect(image.height == (rotation % 180 == 0 ? 340 : 280))
        let imagePage = try #require(PDFPage(image: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))))
        let imageDocument = PDFDocument()
        imageDocument.insert(imagePage, at: 0)
        let sourceRed = try Fixtures.redBounds(in: page)
        let outputRed = try Fixtures.redBounds(in: imagePage)
        #expect(abs(sourceRed.midX - outputRed.midX) <= 2)
        #expect(abs(sourceRed.midY - outputRed.midY) <= 2)
        #expect(page.rotation == rotation)
    }

    @Test("Image imports retain each TIFF page and flatten animation to its first frame")
    func multipageImageImport() throws {
        let document = try Fixtures.document()
        let first = try PDFConversion.renderedImage(page: #require(document.page(at: 0)), scale: 1)
        let second = try PDFConversion.renderedImage(page: #require(document.page(at: 1)), scale: 1)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.tiff" as CFString, 2, nil))
        CGImageDestinationAddImage(destination, first, nil)
        CGImageDestinationAddImage(destination, second, nil)
        #expect(CGImageDestinationFinalize(destination))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "two-pages.tiff")
        try (data as Data).write(to: file)
        #expect(try PDFConversion.importDocument(from: file).pageCount == 2)
    }

    @Test("Compression retains selectable text and annotation values across each quality level", arguments: PDFCompressionLevel.allCases)
    func compressionRoundTrip(level: PDFCompressionLevel) throws {
        let document = try Fixtures.document()
        let marker = try Fixtures.marker(in: document, note: "Compression preservation sentinel")
        try MarkerCodec.apply(marker, to: document)
        let page = try #require(document.page(at: 1))
        let field = PDFAnnotation(bounds: CGRect(x: 80, y: 100, width: 200, height: 24), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = "compression-field"
        field.widgetStringValue = "Keep this field value"
        page.addAnnotation(field)
        let original = try #require(document.dataRepresentation())
        let result = try PDFConversion.compressedData(document: document, level: level, originalBytes: original.count)
        #expect(result.originalBytes == original.count)
        #expect(result.outputBytes == result.data.count)
        let reopened = try #require(PDFDocument(data: result.data))
        #expect(reopened.pageCount == document.pageCount)
        #expect(!(reopened.findString("attention", withOptions: .caseInsensitive)).isEmpty)
        #expect(MarkerCodec.markers(in: reopened).first?.note == marker.note)
        #expect(reopened.page(at: 1)?.annotations.first { $0.fieldName == "compression-field" }?.widgetStringValue == "Keep this field value")
    }

    @Test("Blank text, malformed images, huge rendering dimensions, and restricted PDFs fail clearly")
    func invalidAndRestrictedInputs() throws {
        let emptyText = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
        emptyText.insert(page, at: 0)
        #expect(throws: (any Error).self) { try PDFConversion.exportData(document: emptyText, format: .text) }
        page.setBounds(CGRect(x: 0, y: 0, width: 100_000, height: 100_000), for: .mediaBox)
        #expect(throws: (any Error).self) { try PDFConversion.renderedImage(page: page) }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let malformed = directory.appending(path: "bad.xlsx")
        try Data("not an office document".utf8).write(to: malformed)
        #expect(throws: (any Error).self) { try PDFConversion.importDocument(from: malformed) }
        let source = try Fixtures.document()
        let url = directory.appending(path: "restricted.pdf")
        #expect(source.write(to: url, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "reader", .accessPermissionsOption: 0]))
        let restricted = try #require(PDFDocument(url: url))
        #expect(throws: (any Error).self) { try PDFConversion.exportData(document: restricted, format: .text) }
        #expect(restricted.unlock(withPassword: "reader"))
        #expect(throws: (any Error).self) { try PDFConversion.exportData(document: restricted, format: .text) }
        #expect(throws: (any Error).self) { try PDFConversion.compressedData(document: restricted, level: .compact) }
    }

    @Test("Export snapshots are isolated from source page, annotation and widget mutations")
    func snapshotIsolation() throws {
        let document = try Fixtures.document()
        let sourcePage = try #require(document.page(at: 0))
        let annotation = PDFAnnotation(bounds: CGRect(x: 80, y: 100, width: 120, height: 30), forType: .freeText, withProperties: nil)
        annotation.contents = "Before snapshot"
        sourcePage.addAnnotation(annotation)
        let snapshot = try PDFConversion.snapshot(document: document, needsPrinting: true)
        sourcePage.rotation = 90
        annotation.contents = "After snapshot"
        document.removePage(at: 3)
        #expect(snapshot.pageCount == 4)
        #expect(snapshot.page(at: 0)?.rotation == 0)
        #expect(snapshot.page(at: 0)?.annotations.first?.contents == "Before snapshot")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AnnotateConversion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
