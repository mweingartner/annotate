import AppKit
import CoreGraphics
import PDFKit
import Testing
@testable import AnnotateCore

@Suite("Shareable flattened PDFs", .serialized)
@MainActor
struct PDFExporterTests {
    @Test("Flattening retains searchable source text and full notes, and removes interactive annotations")
    func flattenRoundTrip() throws {
        let document = try Fixtures.document()
        let marker = try Fixtures.marker(in: document, note: "Evidence sentinel: revisit the primary source.", question: "Question sentinel: where is the underlying data?")
        try MarkerCodec.apply(marker, to: document)
        _ = Fixtures.foreignAnnotation(on: try #require(document.page(at: 0)))
        let originalCount = Fixtures.annotations(in: document).count
        let exported = try #require(PDFDocument(data: PDFExporter.flattenedData(document: document, markers: [marker])))
        #expect(exported.pageCount == document.pageCount + 1)
        #expect(Fixtures.annotations(in: exported).isEmpty)
        #expect(MarkerCodec.markers(in: exported).isEmpty)
        #expect(exported.findString("attention", withOptions: .caseInsensitive).count >= 6)
        #expect((exported.string ?? "").contains("Evidence sentinel"))
        #expect((exported.string ?? "").contains("Question sentinel"))
        #expect((exported.string ?? "").contains("Page 1"))
        #expect(Fixtures.annotations(in: document).count == originalCount)
        #expect(MarkerCodec.markers(in: document) == [marker])
        try assertNoAnnotationDictionaries(exported)
    }

    @Test("Excluding the index exports exactly the original number of pages")
    func omitIndex() throws {
        let document = try Fixtures.document()
        let marker = try Fixtures.marker(in: document, note: "Private supplemental sentinel")
        try MarkerCodec.apply(marker, to: document)
        let exported = try #require(PDFDocument(data: PDFExporter.flattenedData(document: document, markers: [marker], includeNotes: false)))
        #expect(exported.pageCount == document.pageCount)
        #expect(!(exported.string ?? "").contains("Private supplemental sentinel"))
        #expect(Fixtures.annotations(in: exported).isEmpty)
    }

    @Test("Foreign sticky-note text remains readable after its popup is flattened away")
    func foreignNoteAppendix() throws {
        let document = try Fixtures.document()
        let page = try #require(document.page(at: 2))
        let foreign = Fixtures.foreignAnnotation(on: page)
        foreign.contents = "ExternalReviewSentinel: retain the existing reader comment."
        let exported = try #require(PDFDocument(data: PDFExporter.flattenedData(document: document, markers: [])))
        #expect(exported.pageCount == document.pageCount + 1)
        let indexText = exported.page(at: document.pageCount)?.string ?? ""
        #expect(indexText.contains("ExternalReviewSentinel"))
        #expect(indexText.contains("Page 3"))
        #expect(Fixtures.annotations(in: exported).isEmpty)
        try assertNoAnnotationDictionaries(exported)
    }

    @Test("Long notes paginate through their final sentence without dropping text")
    func longNotePagination() throws {
        let document = try Fixtures.document()
        let sections = (0..<220).map { "Evidence item \($0): every claim needs an original source and a clear account of uncertainty." }
        let note = "BeginningOfLongNote\n" + sections.joined(separator: "\n") + "\nEndingOfLongNote"
        let marker = try Fixtures.marker(in: document, note: note, question: "FinalQuestionSentinel")
        try MarkerCodec.apply(marker, to: document)
        let exported = try #require(PDFDocument(data: PDFExporter.flattenedData(document: document, markers: [marker])))
        #expect(exported.pageCount > document.pageCount + 3)
        let text = exported.string ?? ""
        #expect(text.contains("BeginningOfLongNote"))
        #expect(text.contains("EndingOfLongNote"))
        #expect(text.contains("FinalQuestionSentinel"))
        for index in 0..<220 {
            #expect(text.contains("Evidence item \(index):"), "Note item \(index) must survive pagination.")
        }
        #expect(Fixtures.annotations(in: exported).isEmpty)
    }

    @Test("The notes index identifies every page of a multi-page marker")
    func indexPageReferences() throws {
        let document = try Fixtures.document()
        let matches = document.findString("attention", withOptions: .caseInsensitive)
        let combined = PDFSelection(document: document)
        combined.add(try #require(matches.first))
        combined.add(try #require(matches.last))
        var marker = try Fixtures.marker(in: document)
        marker.regions = MarkerCodec.regions(for: combined, in: document)
        try MarkerCodec.apply(marker, to: document)
        let exported = try #require(PDFDocument(data: PDFExporter.flattenedData(document: document, markers: [marker])))
        let indexText = exported.page(at: 4)?.string ?? ""
        #expect(indexText.contains("Pages 1, 4"))
    }

    @Test("Cropped and rotated pages keep their dimensions, visible geometry, and searchable text", arguments: [0, 90, 180, 270], [false, true])
    func transformedPages(rotation: Int, cropped: Bool) throws {
        let crop = cropped ? CGRect(x: 50, y: 80, width: 280, height: 340) : CGRect(x: 0, y: 0, width: 400, height: 500)
        let document = try Fixtures.geometryDocument(rotation: rotation, crop: crop)
        let originalPage = try #require(document.page(at: 0))
        let sourceBounds = try Fixtures.redBounds(in: originalPage)
        let exported = try #require(PDFDocument(data: PDFExporter.flattenedData(document: document, markers: [])))
        let page = try #require(exported.page(at: 0))
        let quarterTurn = rotation == 90 || rotation == 270
        #expect(abs(page.bounds(for: .mediaBox).width - (quarterTurn ? crop.height : crop.width)) < 0.1)
        #expect(abs(page.bounds(for: .mediaBox).height - (quarterTurn ? crop.width : crop.height)) < 0.1)
        #expect(page.rotation == 0)
        #expect((page.string ?? "").contains("Rotation sentinel"))
        let outputBounds = try Fixtures.redBounds(in: page)
        #expect(abs(outputBounds.midX - sourceBounds.midX) <= 2)
        #expect(abs(outputBounds.midY - sourceBounds.midY) <= 2)
        #expect(abs(outputBounds.width - sourceBounds.width) <= 2)
        #expect(abs(outputBounds.height - sourceBounds.height) <= 2)
        #expect(originalPage.rotation == rotation)
        #expect(originalPage.bounds(for: .cropBox) == crop)
    }

    @Test("Visible highlights are baked into content and source display flags are restored")
    func highlightAppearance() throws {
        let document = try Fixtures.geometryDocument(rotation: 0, crop: CGRect(x: 0, y: 0, width: 400, height: 500))
        let page = try #require(document.page(at: 0))
        var marker = try Fixtures.marker(in: document, text: "Rotation sentinel")
        marker.color = MarkerColor(red: 1, green: 0, blue: 0)
        try MarkerCodec.apply(marker, to: document)
        let originalBounds = try Fixtures.redBounds(in: page)
        page.displaysAnnotations = false
        let exported = try #require(PDFDocument(data: PDFExporter.flattenedData(document: document, markers: [marker], includeNotes: false)))
        #expect(!page.displaysAnnotations)
        let flattenedPage = try #require(exported.page(at: 0))
        let exportedBounds = try Fixtures.redBounds(in: flattenedPage)
        #expect(abs(originalBounds.maxY - exportedBounds.maxY) <= 2)
        #expect(abs(originalBounds.minY - exportedBounds.minY) <= 2)
        #expect(flattenedPage.annotations.isEmpty)
    }

    @Test("Empty documents are rejected with a useful error")
    func emptyDocument() {
        #expect(throws: (any Error).self) {
            try PDFExporter.flattenedData(document: PDFDocument(), markers: [])
        }
    }

    @Test("Password locks and document permission restrictions are honored")
    func permissions() throws {
        let document = try Fixtures.document()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("annotate-restricted-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(document.write(to: url, withOptions: [
            .ownerPasswordOption: "owner-password", .userPasswordOption: "reader-password", .accessPermissionsOption: 0
        ]))
        let restricted = try #require(PDFDocument(url: url))
        #expect(restricted.isLocked)
        #expect(throws: (any Error).self) { try PDFExporter.flattenedData(document: restricted, markers: []) }
        #expect(restricted.unlock(withPassword: "reader-password"))
        #expect(!restricted.allowsPrinting)
        #expect(!restricted.allowsCopying)
        #expect(throws: (any Error).self) { try PDFExporter.flattenedData(document: restricted, markers: []) }
        let marker = try Fixtures.marker(in: document)
        #expect(throws: (any Error).self) { try MarkerCodec.apply(marker, to: restricted) }
        #expect(Fixtures.annotations(in: restricted).isEmpty)
    }

    private func assertNoAnnotationDictionaries(_ document: PDFDocument) throws {
        let data = try #require(document.dataRepresentation())
        let provider = try #require(CGDataProvider(data: data as CFData))
        let cgDocument = try #require(CGPDFDocument(provider))
        for index in 1...cgDocument.numberOfPages {
            let page = try #require(cgDocument.page(at: index))
            let dictionary = try #require(page.dictionary)
            var annotations: CGPDFArrayRef?
            let hasAnnotations = CGPDFDictionaryGetArray(dictionary, "Annots", &annotations)
            #expect(!hasAnnotations || annotations.map { CGPDFArrayGetCount($0) == 0 } == true)
        }
    }
}
