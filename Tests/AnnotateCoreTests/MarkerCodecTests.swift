import AppKit
import PDFKit
import Testing
@testable import AnnotateCore

@Suite("Marker persistence and geometry", .serialized)
@MainActor
struct MarkerCodecTests {
    @Test("The tour contains selectable text, repeated search hits, and no pre-existing marks")
    func selectableTour() throws {
        let document = try Fixtures.document()
        #expect((document.string ?? "").contains("A place for your attention"))
        let matches = document.findString("attention", withOptions: .caseInsensitive)
        #expect(matches.count >= 6)
        #expect(Set(matches.compactMap { $0.pages.first.map(document.index(for:)) }).count == 4)
        #expect(Fixtures.annotations(in: document).isEmpty)
        #expect(MarkerCodec.markers(in: document).isEmpty)
    }

    @Test("Categories, color, icon, text and exact locations survive saving and reopening a real PDF")
    func roundTrip() throws {
        let document = try Fixtures.document()
        let marker = try Fixtures.marker(in: document, note: "日本語 — café — a useful note", question: "Why this passage?")
        try MarkerCodec.apply(marker, to: document)
        #expect(MarkerCodec.markers(in: document) == [marker])
        let reopened = try Fixtures.reopen(document)
        #expect(MarkerCodec.markers(in: reopened) == [marker])
        let visible = Fixtures.annotations(in: reopened)
        #expect(visible.contains { $0.type == "Highlight" })
        #expect(visible.contains { $0.type == "FreeText" })
        #expect(visible.contains { ($0.contents ?? "").contains("日本語") })
        #expect(visible.contains { ($0.contents ?? "").contains(marker.question) })
    }

    @Test("Replacing and deleting a marker preserves foreign annotations and other markers")
    func replaceAndDelete() throws {
        let document = try Fixtures.document()
        let page = try #require(document.page(at: 0))
        let foreign = Fixtures.foreignAnnotation(on: page)
        var first = try Fixtures.marker(in: document)
        let second = try Fixtures.marker(in: document, text: "A specific question")
        try MarkerCodec.apply(first, to: document)
        try MarkerCodec.apply(second, to: document)
        let beforeCount = Fixtures.annotations(in: document).count
        first.note = "A revised note"
        first.color = MarkerColor(red: 0.2, green: 0.5, blue: 0.8)
        first.categories = [.question, .note]
        try MarkerCodec.apply(first, to: document)
        #expect(Fixtures.annotations(in: document).count == beforeCount)
        #expect(Set(MarkerCodec.markers(in: document).map(\.id)) == [first.id, second.id])
        #expect(MarkerCodec.markers(in: document).first { $0.id == first.id } == first)
        MarkerCodec.remove(id: first.id, from: document)
        #expect(MarkerCodec.markers(in: document) == [second])
        #expect(page.annotations.contains { $0 === foreign })
        #expect(foreign.contents == "Another reader's annotation — preserve this.")
        MarkerCodec.remove(id: UUID(), from: document)
        #expect(MarkerCodec.markers(in: document) == [second])
    }

    @Test("A multi-line selection produces separate tight line rectangles")
    func multilineRegions() throws {
        let document = try Fixtures.document()
        let page = try #require(document.page(at: 1))
        let text = try #require(page.string)
        let start = (text as NSString).range(of: "This paragraph spans")
        let end = (text as NSString).range(of: "complete passage.")
        try #require(start.location != NSNotFound && end.location != NSNotFound)
        let range = NSRange(location: start.location, length: NSMaxRange(end) - start.location)
        let selection = try #require(page.selection(for: range))
        let regions = MarkerCodec.regions(for: selection, in: document)
        #expect(regions.count >= 3)
        #expect(regions.allSatisfy { $0.pageIndex == 1 && $0.bounds.height < 25 && $0.bounds.width > 0 })
        for region in regions {
            #expect(page.bounds(for: .mediaBox).contains(region.bounds))
        }
        #expect(regions.map(\.bounds).reduce(CGRect.null) { $0.union($1) }.height > regions[0].bounds.height * 2)
    }

    @Test("Noncontiguous multi-page selections retain all page locations")
    func multipageRegions() throws {
        let document = try Fixtures.document()
        let matches = document.findString("attention", withOptions: .caseInsensitive)
        let first = try #require(matches.first)
        let last = try #require(matches.last)
        let combined = PDFSelection(document: document)
        combined.add(first)
        combined.add(last)
        let regions = MarkerCodec.regions(for: combined, in: document)
        #expect(Set(regions.map(\.pageIndex)) == [0, 3])
        var marker = try Fixtures.marker(in: document)
        marker.regions = regions
        try MarkerCodec.apply(marker, to: document)
        #expect(MarkerCodec.markers(in: try Fixtures.reopen(document)) == [marker])
    }

    @Test("An empty selection produces no usable regions")
    func emptySelection() throws {
        let document = try Fixtures.document()
        #expect(MarkerCodec.regions(for: PDFSelection(document: document), in: document).isEmpty)
    }

    @Test("Traversal follows page position rather than marker creation time")
    func readingOrder() throws {
        let document = try Fixtures.document()
        let matches = document.findString("attention", withOptions: .caseInsensitive).filter { $0.pages.first === document.page(at: 0) }
        #expect(matches.count >= 2)
        var upper = try Fixtures.marker(in: document)
        upper.regions = MarkerCodec.regions(for: try #require(matches.first), in: document)
        upper.createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        var lower = try Fixtures.marker(in: document)
        lower.regions = MarkerCodec.regions(for: try #require(matches.last), in: document)
        lower.createdAt = Date(timeIntervalSince1970: 1_600_000_000)
        try MarkerCodec.apply(lower, to: document)
        try MarkerCodec.apply(upper, to: document)
        #expect(MarkerCodec.markers(in: document).map(\.id) == [upper.id, lower.id])
    }

    @Test("An oversized note is rejected without replacing saved work")
    func oversizedReplacement() throws {
        let document = try Fixtures.document()
        let original = try Fixtures.marker(in: document)
        try MarkerCodec.apply(original, to: document)
        var replacement = original
        replacement.note = String(repeating: "é", count: 540_000)
        #expect(throws: (any Error).self) { try MarkerCodec.apply(replacement, to: document) }
        #expect(MarkerCodec.markers(in: document) == [original])
    }

    @Test("A foreign annotation with a coincident marker identifier is preserved")
    func foreignIdentifier() throws {
        let document = try Fixtures.document()
        let marker = try Fixtures.marker(in: document)
        let page = try #require(document.page(at: 0))
        let foreign = Fixtures.foreignAnnotation(on: page)
        let foreignCount = page.annotations.count
        foreign.setValue(marker.id.uuidString, forAnnotationKey: MarkerCodec.identifierKey)
        foreign.setValue("another.application", forAnnotationKey: MarkerCodec.ownerKey)
        try MarkerCodec.apply(marker, to: document)
        MarkerCodec.remove(id: marker.id, from: document)
        #expect(page.annotations.count == foreignCount)
        #expect(page.annotations.first === foreign)
    }

    @Test("Invalid replacement is rejected before the original marker is changed", arguments: ["page", "bounds", "color", "empty", "categories"])
    func invalidReplacement(reason: String) throws {
        let document = try Fixtures.document()
        let original = try Fixtures.marker(in: document)
        try MarkerCodec.apply(original, to: document)
        let annotationCount = Fixtures.annotations(in: document).count
        var invalid = original
        switch reason {
        case "page": invalid.regions = [PageRegion(pageIndex: 999, bounds: original.regions[0].bounds)]
        case "bounds": invalid.regions = [PageRegion(pageIndex: 0, bounds: CGRect(x: 5, y: 5, width: -1, height: 20))]
        case "color": invalid.color.red = .nan
        case "empty": invalid.regions = []
        default: invalid.categories = []
        }
        #expect(throws: (any Error).self) { try MarkerCodec.apply(invalid, to: document) }
        #expect(MarkerCodec.markers(in: document) == [original])
        #expect(Fixtures.annotations(in: document).count == annotationCount)
    }

    @Test("Corrupt or unsupported metadata is ignored without removing visible annotations", arguments: ["invalid", "version", "oversized", "wrongType", "missing", "category", "page"])
    func malformedMetadata(reason: String) throws {
        let document = try Fixtures.document()
        let marker = try Fixtures.marker(in: document)
        try MarkerCodec.apply(marker, to: document)
        let metadataKey = PDFAnnotationKey(rawValue: "/AnnotateMarker")
        let annotation = try #require(Fixtures.annotations(in: document).first { $0.value(forAnnotationKey: metadataKey) != nil })
        let originalCount = Fixtures.annotations(in: document).count
        let payload = try #require(annotation.value(forAnnotationKey: metadataKey) as? String)
        var json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        switch reason {
        case "invalid": annotation.setValue("{not json", forAnnotationKey: metadataKey)
        case "oversized": annotation.setValue(String(repeating: "x", count: 1_100_000), forAnnotationKey: metadataKey)
        case "wrongType": annotation.setValue(42, forAnnotationKey: metadataKey)
        case "missing": annotation.removeValue(forAnnotationKey: metadataKey)
        default:
            if reason == "version" { json["version"] = 999 }
            else {
                var value = try #require(json["marker"] as? [String: Any])
                if reason == "category" { value["categories"] = ["not-a-real-category"] }
                else {
                    var regions = try #require(value["regions"] as? [[String: Any]])
                    regions[0]["pageIndex"] = 999
                    value["regions"] = regions
                }
                json["marker"] = value
            }
            let altered = try JSONSerialization.data(withJSONObject: json)
            annotation.setValue(String(decoding: altered, as: UTF8.self), forAnnotationKey: metadataKey)
        }
        #expect(MarkerCodec.markers(in: document).isEmpty)
        #expect(Fixtures.annotations(in: document).count == originalCount)
    }
}
