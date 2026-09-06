import AppKit
import PDFKit
import Testing
@testable import AnnotateCore

@Suite("Content editing and sanitization", .serialized)
@MainActor
struct ContentEditorTests {
    @Test("Editable text and standard markup survive PDF serialization")
    func annotationPersistence() throws {
        let document = try Fixtures.document()
        let region = PageRegion(pageIndex: 0, bounds: CGRect(x: 80, y: 200, width: 200, height: 80))
        try PDFContentEditor.addText("Live changes 123", in: region, document: document, font: .systemFont(ofSize: 18), color: .blue, identifier: "live-test")
        try PDFContentEditor.addMarkup(.underline, regions: [region], document: document, color: .red)
        let reopened = try Fixtures.reopen(document)
        let annotations = try #require(reopened.page(at: 0)).annotations
        let text = try #require(annotations.first { $0.value(forAnnotationKey: PDFContentEditor.editIDKey) as? String == "live-test" })
        #expect(text.contents == "Live changes 123")
        #expect(text.font?.pointSize == 18)
        #expect(annotations.contains { $0.type == "Underline" })
    }

    @Test("Replacement removes old text, retains other pages, and preserves outside marker metadata")
    func replaceText() throws {
        let document = try Fixtures.document()
        let marker = try Fixtures.marker(in: document)
        try MarkerCodec.apply(marker, to: document)
        let selected = try #require(document.findString("specific question", withOptions: .caseInsensitive).first)
        let page = try #require(selected.pages.first)
        let region = PageRegion(pageIndex: document.index(for: page), bounds: selected.bounds(for: page))
        let unaffectedIndex = region.pageIndex == 0 ? 1 : 0
        let unaffected = document.page(at: unaffectedIndex)?.string
        let replaced = try PDFContentEditor.replaceArea(region, in: document)
        try PDFContentEditor.addText("A revised question", in: replaced, document: document, font: .systemFont(ofSize: 14), color: .black)
        let reopened = try Fixtures.reopen(document)
        #expect(reopened.pageCount == 4)
        #expect(reopened.page(at: unaffectedIndex)?.string == unaffected)
        let remainingText = reopened.page(at: region.pageIndex)?.string ?? ""
        #expect(remainingText.isEmpty)
        #expect(MarkerCodec.markers(in: reopened).contains { $0.id == marker.id })
        #expect(reopened.page(at: region.pageIndex)?.annotations.contains { $0.contents == "A revised question" } == true)
    }

    @Test("Redaction discards hidden text, annotation comments and metadata throughout the export")
    func hiddenDataRemoved() throws {
        let document = try Fixtures.document()
        let marker = try Fixtures.marker(in: document, note: "SECRET-ANNOTATION-492")
        try MarkerCodec.apply(marker, to: document)
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "SECRET-TITLE-873", PDFDocumentAttribute.authorAttribute: "SECRET-AUTHOR-501"]
        let selected = try #require(document.findString("attention", withOptions: .caseInsensitive).first)
        let page = try #require(selected.pages.first)
        let region = PageRegion(pageIndex: document.index(for: page), bounds: selected.bounds(for: page))
        let bytes = try PDFContentEditor.redactedData(document: document, regions: [region])
        let result = try #require(PDFDocument(data: bytes))
        #expect(result.pageCount == document.pageCount)
        #expect((result.string ?? "").isEmpty)
        #expect(Fixtures.annotations(in: result).isEmpty)
        #expect(MarkerCodec.markers(in: result).isEmpty)
        #expect(result.documentAttributes?[PDFDocumentAttribute.titleAttribute] == nil)
        #expect(!bytes.contains(Data("SECRET-ANNOTATION-492".utf8)))
        #expect(!bytes.contains(Data("SECRET-TITLE-873".utf8)))
        #expect(!bytes.contains(Data("SECRET-AUTHOR-501".utf8)))
        #expect(!(document.string ?? "").isEmpty)
        #expect(MarkerCodec.markers(in: document).count == 1)
    }

    @Test("Removed area is black in the actual image pixels for every page rotation", arguments: [0, 90, 180, 270])
    func redactionPixels(rotation: Int) throws {
        let document = try Fixtures.geometryDocument(rotation: rotation, crop: CGRect(x: 50, y: 80, width: 300, height: 350))
        let page = try #require(document.page(at: 0))
        let area = CGRect(x: 70, y: 110, width: 50, height: 40)
        let (image, _) = try PDFContentEditor.raster(page, erase: [area], fill: .black, scale: 2)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let point = CGPoint(x: area.midX, y: area.midY).applying(page.transform(for: .cropBox))
        let x = Int(point.x * 2), y = image.height - 1 - Int(point.y * 2)
        let pixel = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        #expect(pixel.redComponent < 0.03 && pixel.greenComponent < 0.03 && pixel.blueComponent < 0.03)
        // A red sentinel would be recoverable from image extraction if we merely overlaid a PDF rectangle.
        var redPixels = 0
        for row in 0..<bitmap.pixelsHigh {
            for column in 0..<bitmap.pixelsWide {
                let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB)
                if (color?.redComponent ?? 0) > 0.8 && (color?.greenComponent ?? 1) < 0.2 && (color?.blueComponent ?? 1) < 0.2 { redPixels += 1 }
            }
        }
        #expect(redPixels == 0)
    }

    @Test("Invalid redaction region fails before output")
    func invalidRegion() throws {
        let document = try Fixtures.document()
        #expect(throws: PDFContentError.self) {
            _ = try PDFContentEditor.redactedData(document: document, regions: [PageRegion(pageIndex: 0, bounds: CGRect(x: -10, y: 20, width: 50, height: 50))])
        }
    }
}
