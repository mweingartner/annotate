import AppKit
import PDFKit
import Testing
@testable import AnnotateCore

@Suite("Page organization and marker identity", .serialized)
@MainActor
struct PageOrganizationTests {
    @Test("Reorder remaps multi-page markers, retains geometry and foreign annotations")
    func reorder() throws {
        let document = try Fixtures.document()
        var marker = try Fixtures.marker(in: document)
        marker.regions.append(PageRegion(pageIndex: 3, bounds: marker.regions[0].bounds))
        try MarkerCodec.apply(marker, to: document)
        let foreign = Fixtures.foreignAnnotation(on: try #require(document.page(at: 0)))
        let originalFirst = document.page(at: 0)?.string
        try PDFPageOrganizer.reorder(document, order: [3, 1, 2, 0])
        let reopened = try Fixtures.reopen(document)
        let moved = try #require(MarkerCodec.markers(in: reopened).first)
        #expect(moved.id == marker.id)
        #expect(moved.regions.map(\.pageIndex) == [0, 3])
        #expect(moved.regions.map(\.bounds) == marker.regions.map(\.bounds))
        #expect(reopened.page(at: 3)?.string == originalFirst)
        #expect(reopened.page(at: 3)?.annotations.contains { $0.contents == foreign.contents } == true)
    }

    @Test("Deleting an anchor preserves remaining regions and drops fully deleted markers")
    func deleteAnchors() throws {
        let document = try Fixtures.document()
        var marker = try Fixtures.marker(in: document)
        marker.regions.append(PageRegion(pageIndex: 3, bounds: marker.regions[0].bounds))
        try MarkerCodec.apply(marker, to: document)
        try PDFPageOrganizer.delete(document, pages: IndexSet(integer: 0))
        let kept = try #require(MarkerCodec.markers(in: try Fixtures.reopen(document)).first)
        #expect(kept.id == marker.id)
        #expect(kept.regions.count == 1)
        #expect(kept.pageIndex == 2)
        try PDFPageOrganizer.delete(document, pages: IndexSet(integer: 2))
        #expect(MarkerCodec.markers(in: try Fixtures.reopen(document)).isEmpty)
    }

    @Test("Merging the same PDF creates independent marker and form identities without changing the source")
    func mergeCollisions() throws {
        let document = try Fixtures.document()
        let marker = try Fixtures.marker(in: document)
        try MarkerCodec.apply(marker, to: document)
        try PDFFormEditor.create(in: document, region: PageRegion(pageIndex: 0, bounds: CGRect(x: 70, y: 80, width: 120, height: 30)), name: "Name", kind: .text)
        let source = try Fixtures.reopen(document)
        try PDFPageOrganizer.insert(source, into: document, at: 1)
        let reopened = try Fixtures.reopen(document)
        let markers = MarkerCodec.markers(in: reopened)
        #expect(reopened.pageCount == 8)
        #expect(markers.count == 2)
        #expect(Set(markers.map(\.id)).count == 2)
        #expect(markers.map(\.pageIndex) == [0, 1])
        #expect(Set(PDFFormEditor.fields(in: reopened).map(\.name)) == ["Name", "Name (import 2)"])
        #expect(source.pageCount == 4)
        #expect(MarkerCodec.markers(in: source) == [marker])
    }

    @Test("Extraction remaps markers to selected page indexes and split preserves total pages")
    func extractAndSplit() throws {
        let document = try Fixtures.document()
        var marker = try Fixtures.marker(in: document)
        marker.regions = [PageRegion(pageIndex: 3, bounds: marker.regions[0].bounds)]
        try MarkerCodec.apply(marker, to: document)
        let extracted = try PDFPageOrganizer.extract(document, pages: IndexSet([1, 3]))
        #expect(extracted.pageCount == 2)
        #expect(MarkerCodec.markers(in: try Fixtures.reopen(extracted)).first?.pageIndex == 1)
        let parts = try PDFPageOrganizer.split(document, every: 3)
        #expect(parts.map(\.pageCount) == [3, 1])
        #expect(MarkerCodec.markers(in: try Fixtures.reopen(parts[1])).first?.pageIndex == 0)
        #expect(document.pageCount == 4)
    }

    @Test("Rotation retains marker page-space geometry on cropped pages", arguments: [0, 90, 180, 270])
    func rotation(_ angle: Int) throws {
        let document = try Fixtures.geometryDocument(rotation: angle, crop: CGRect(x: 50, y: 70, width: 300, height: 350))
        let region = PageRegion(pageIndex: 0, bounds: CGRect(x: 100, y: 240, width: 100, height: 20))
        let marker = PDFMarker(categories: [.note], color: .palette[0], icon: "note.text", quote: "", note: "Crop", question: "", regions: [region])
        try MarkerCodec.apply(marker, to: document)
        try PDFPageOrganizer.rotate(document, pages: [0])
        let reopened = try Fixtures.reopen(document)
        #expect(reopened.page(at: 0)?.rotation == (angle + 90) % 360)
        #expect(reopened.page(at: 0)?.bounds(for: .cropBox) == CGRect(x: 50, y: 70, width: 300, height: 350))
        #expect(MarkerCodec.markers(in: reopened).first?.regions == [region])
    }

    @Test("Blank insertion preserves page size and shifts marker indexes")
    func blankInsertion() throws {
        let document = try Fixtures.document()
        let marker = try Fixtures.marker(in: document)
        try MarkerCodec.apply(marker, to: document)
        try PDFPageOrganizer.insertBlank(into: document, at: 0, size: CGSize(width: 300, height: 400))
        let reopened = try Fixtures.reopen(document)
        #expect(reopened.pageCount == 5)
        #expect(reopened.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 300, height: 400))
        #expect(MarkerCodec.markers(in: reopened).first?.pageIndex == 1)
    }

    @Test("Invalid page operations preserve original pages")
    func invalidOperations() throws {
        let document = try Fixtures.document()
        let original = document.string
        #expect(throws: (any Error).self) { try PDFPageOrganizer.reorder(document, order: [0, 0, 1, 2]) }
        #expect(throws: (any Error).self) { try PDFPageOrganizer.delete(document, pages: IndexSet(integersIn: 0..<4)) }
        #expect(throws: (any Error).self) { try PDFPageOrganizer.delete(document, pages: [50]) }
        #expect(document.string == original)
        #expect(document.pageCount == 4)
    }

    @Test("Page ranges validate bounds and reject malformed input", arguments: ["0", "5", "3-2", "1,", "1--2", "x", "1-99"])
    func badRanges(_ input: String) {
        #expect(throws: (any Error).self) { try PDFPageRange.parse(input, pageCount: 4) }
    }

    @Test("Page ranges support all, lists, en dashes, whitespace, and deduplication")
    func ranges() throws {
        #expect(try PDFPageRange.parse(" 1, 3–4, 3 ", pageCount: 4) == IndexSet([0, 2, 3]))
        #expect(try PDFPageRange.parse("all", pageCount: 4) == IndexSet(integersIn: 0..<4))
    }
}
