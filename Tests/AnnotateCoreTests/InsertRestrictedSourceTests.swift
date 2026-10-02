import AppKit
import PDFKit
import Testing
@testable import AnnotateCore

/// Inserting pages from a PDF that forbids commenting: its markers' annotations come along
/// with the pages (they can't be removed from it), and must end up as exactly one set.
@Suite("Inserting pages from a source that forbids commenting", .serialized)
@MainActor
struct InsertRestrictedSourceTests {
    private func ownedIDs(on page: PDFPage) -> [String] {
        page.annotations.filter { $0.value(forAnnotationKey: MarkerCodec.ownerKey) as? String == MarkerCodec.ownerValue }
            .compactMap { $0.value(forAnnotationKey: MarkerCodec.identifierKey) as? String }
    }

    /// `base` saved with an owner password, allowing copying and assembly but not commenting.
    private func restricted(_ base: PDFDocument) throws -> PDFDocument {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let permissions = CGPDFAccessPermissions([.allowsLowQualityPrinting, .allowsHighQualityPrinting, .allowsDocumentAssembly,
                                                  .allowsContentCopying, .allowsContentAccessibility])
        #expect(base.write(to: url, withOptions: [.ownerPasswordOption: "owner", .accessPermissionsOption: permissions.rawValue]))
        let data = try Data(contentsOf: url)
        return try #require(PDFDocument(data: data))
    }

    @Test("Each marker arrives once, with one set of annotations")
    func distinctMarkers() throws {
        let base = try Fixtures.document()
        let theirs = try Fixtures.marker(in: base, note: "Theirs")
        try MarkerCodec.apply(theirs, to: base)
        let source = try restricted(base)
        try #require(!source.allowsCommenting && source.allowsCopying && source.allowsDocumentAssembly)
        let document = try Fixtures.document()
        let originalCount = document.pageCount
        var mine = try Fixtures.marker(in: document, note: "Mine"); mine.id = UUID()
        try MarkerCodec.apply(mine, to: document)

        try PDFPageOrganizer.insert(source, into: document, at: originalCount)
        let reopened = try Fixtures.reopen(document)
        let markers = MarkerCodec.markers(in: reopened)
        #expect(markers.map(\.note).sorted() == ["Mine", "Theirs"])
        // Exactly as many owned annotations as one copy of each marker makes.
        let inserted = try #require(reopened.page(at: originalCount + theirs.pageIndex))
        let original = try #require(base.page(at: theirs.pageIndex))
        #expect(ownedIDs(on: inserted).count == ownedIDs(on: original).count)
    }

    @Test("A source marker sharing an identifier with one of yours, inserted in front, never hides yours")
    func collidingMarker() throws {
        let base = try Fixtures.document()
        let theirs = try Fixtures.marker(in: base, note: "Theirs")
        try MarkerCodec.apply(theirs, to: base)
        let source = try restricted(base)
        let document = try Fixtures.document()
        var mine = try Fixtures.marker(in: document, note: "Mine"); mine.id = theirs.id
        try MarkerCodec.apply(mine, to: document)

        try PDFPageOrganizer.insert(source, into: document, at: 0)
        let reopened = try Fixtures.reopen(document)
        let markers = MarkerCodec.markers(in: reopened)
        #expect(markers.map(\.note).sorted() == ["Mine", "Theirs"])
        #expect(markers.first { $0.note == "Mine" }?.id == mine.id)
        // Removing your marker leaves theirs, and removes nothing else of yours.
        MarkerCodec.remove(id: mine.id, from: reopened)
        #expect(MarkerCodec.markers(in: reopened).map(\.note) == ["Theirs"])
    }
}
