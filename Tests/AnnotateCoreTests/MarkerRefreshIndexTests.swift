import AppKit
import PDFKit
import Testing
@testable import AnnotateCore

/// SplitMix64: every generated document replays from its seed.
private struct RefreshRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 ^ 0xD1B5_4A32_D192_ED03 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// `refreshAppearance` reads each page's owned annotations once, by marker, instead of
/// scanning the page for every marker. These tests hold it to the behaviour of the old
/// scan: a damaged older appearance converges to exactly what `apply` writes today, a
/// healthy one is left as it is, and foreign annotations are never touched.
@Suite("Marker appearance refresh by per-page index", .serialized)
@MainActor
struct MarkerRefreshIndexTests {
    private static let palette = MarkerColor.palette

    /// Markers with one to three regions each, on any of the document's pages, so many
    /// markers span pages and several share each page.
    private func markers(_ count: Int, in document: PDFDocument, random: inout RefreshRandom, pages: ClosedRange<Int>? = nil) -> [PDFMarker] {
        (0..<count).map { index in
            let regions = (0..<Int.random(in: 1...3, using: &random)).map { _ -> PageRegion in
                let pageIndex = Int.random(in: pages ?? 0...(document.pageCount - 1), using: &random)
                let media = document.page(at: pageIndex)!.bounds(for: .mediaBox)
                let width = Double.random(in: 20...200, using: &random), height = Double.random(in: 8...30, using: &random)
                let x = Double.random(in: media.minX...(media.maxX - width), using: &random)
                let y = Double.random(in: media.minY...(media.maxY - height), using: &random)
                return PageRegion(pageIndex: pageIndex, bounds: CGRect(x: x, y: y, width: width, height: height))
            }
            return PDFMarker(categories: [.important], color: Self.palette[index % Self.palette.count], icon: "star.fill",
                             quote: "Quote \(index)", note: "Note \(index)", question: index.isMultiple(of: 2) ? "Question \(index)?" : "",
                             regions: regions, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
        }
    }

    private func byID(_ markers: [PDFMarker]) -> [PDFMarker] { markers.sorted { $0.id.uuidString < $1.id.uuidString } }

    private func owned(_ annotation: PDFAnnotation) -> UUID? {
        guard annotation.value(forAnnotationKey: MarkerCodec.ownerKey) as? String == MarkerCodec.ownerValue else { return nil }
        return (annotation.value(forAnnotationKey: MarkerCodec.identifierKey) as? String).flatMap(UUID.init(uuidString:))
    }

    private func color(_ color: NSColor?) -> String {
        guard let rgb = color?.usingColorSpace(.deviceRGB) else { return "-" }
        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent].map { String(format: "%.3f", $0) }.joined(separator: ",")
    }

    /// Every annotation on every page, as a sorted description of what a reader would see
    /// and what identifies it. Popups are described through the annotation that owns them.
    private func snapshot(_ document: PDFDocument) -> [[String]] {
        (0..<document.pageCount).map { index in
            (document.page(at: index)?.annotations ?? []).map { annotation in
                let bounds = annotation.bounds
                var parts = [annotation.type ?? "?", owned(annotation)?.uuidString ?? "foreign", annotation.contents ?? "",
                             String(format: "%.2f %.2f %.2f %.2f", bounds.minX, bounds.minY, bounds.width, bounds.height), color(annotation.color)]
                if annotation.type == "FreeText" { parts.append(color(annotation.fontColor)) }
                if annotation.type == "Text" {
                    let popup = annotation.popup
                    parts.append(popup.map { "popup \(String(format: "%.2f %.2f", $0.bounds.minX, $0.bounds.minY)) on page" + ($0.page === annotation.page ? "" : " elsewhere") } ?? "no popup")
                }
                return parts.joined(separator: " | ")
            }.sorted()
        }
    }

    /// The lines that differ, page by page, so a failing seed shows what changed.
    private func difference(_ got: [[String]], _ want: [[String]]) -> String {
        zip(got, want).enumerated().flatMap { page, pair in
            Set(pair.0).symmetricDifference(Set(pair.1)).sorted().map { "page \(page) \(Set(pair.0).contains($0) ? "got" : "want"): \($0)" }
        }.joined(separator: "\n")
    }

    /// Damage the way older Annotate versions or other readers leave markers: comment tags
    /// missing, popups missing, comments stored on highlights, badges with unreadable ink.
    private func damage(_ document: PDFDocument, _ markers: [PDFMarker], random: inout RefreshRandom) {
        for marker in markers {
            let kind = Int.random(in: 0..<5, using: &random)
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                for annotation in page.annotations where owned(annotation) == marker.id {
                    switch (kind, annotation.type) {
                    case (0, "Text"): annotation.popup = nil; page.removeAnnotation(annotation)
                    case (0, "Highlight"), (3, "Highlight"): annotation.contents = MarkerCodec.readableContents(for: marker)
                    case (1, "Popup"): page.removeAnnotation(annotation)
                    case (2, "FreeText"): annotation.fontColor = .black; annotation.color = NSColor.black.withAlphaComponent(0.9)
                    case (3, "Text"): annotation.popup = nil; page.removeAnnotation(annotation)
                    default: break
                    }
                }
            }
        }
    }

    private func fixture(seed: UInt64, count: Int) throws -> (fresh: PDFDocument, damaged: PDFDocument, markers: [PDFMarker], random: RefreshRandom) {
        var random = RefreshRandom(seed: seed)
        let base = try Fixtures.document()
        // Each page carries a foreign comment the refresh must leave alone.
        for index in 0..<base.pageCount { _ = Fixtures.foreignAnnotation(on: try #require(base.page(at: index))) }
        let data = try #require(base.dataRepresentation())
        let fresh = try #require(PDFDocument(data: data)), damaged = try #require(PDFDocument(data: data))
        let markers = markers(count, in: fresh, random: &random)
        for marker in markers {
            try MarkerCodec.apply(marker, to: fresh)
            try MarkerCodec.apply(marker, to: damaged)
        }
        return (fresh, damaged, markers, random)
    }

    @Test("A damaged multi-page, multi-region appearance converges to what apply writes, and stays there", arguments: Array(UInt64(1)...UInt64(12)))
    func damagedConvergesToFresh(seed: UInt64) throws {
        var (fresh, damaged, markers, random) = try fixture(seed: seed, count: 14)
        let expected = snapshot(fresh)
        damage(damaged, markers, random: &random)
        #expect(MarkerCodec.markers(in: damaged).count == markers.count, "seed \(seed): damage keeps every marker's metadata")

        MarkerCodec.refreshAppearance(in: damaged)
        let refreshed = snapshot(damaged)
        #expect(refreshed == expected, "seed \(seed): \(difference(refreshed, expected))")
        MarkerCodec.refreshAppearance(in: damaged)
        #expect(snapshot(damaged) == refreshed, "seed \(seed): a second refresh changes nothing")
        #expect(byID(MarkerCodec.markers(in: damaged)) == byID(markers), "seed \(seed)")
        // Every owned highlight on every page, including a marker's later pages, carries no
        // contents (they would make PDFKit draw an unaddressable comment).
        let highlights = Fixtures.annotations(in: damaged).filter { $0.type == "Highlight" && owned($0) != nil }
        #expect(highlights.count == markers.reduce(0) { $0 + $1.regions.count })
        #expect(highlights.allSatisfy { $0.contents?.isEmpty ?? true }, "seed \(seed)")
        // Exactly one comment and one popup per marker, on the marker's own page.
        for marker in markers {
            let page = try #require(damaged.page(at: marker.pageIndex))
            let mine = Fixtures.annotations(in: damaged).filter { owned($0) == marker.id }
            #expect(mine.filter { $0.type == "Text" }.count == 1 && mine.filter { $0.type == "Popup" }.count == 1, "seed \(seed) marker \(marker.note)")
            #expect(mine.filter { $0.type == "Text" || $0.type == "Popup" || $0.type == "FreeText" }.allSatisfy { $0.page === page })
        }
        let reopened = try Fixtures.reopen(damaged)
        #expect(byID(MarkerCodec.markers(in: reopened)) == byID(markers), "seed \(seed): survives saving")
    }

    @Test("Refreshing a healthy document changes nothing", arguments: Array(UInt64(100)...UInt64(105)))
    func healthyUnchanged(seed: UInt64) throws {
        let (fresh, _, _, _) = try fixture(seed: seed, count: 10)
        let before = snapshot(fresh), annotations = Fixtures.annotations(in: fresh)
        MarkerCodec.refreshAppearance(in: fresh)
        #expect(snapshot(fresh) == before, "seed \(seed)")
        #expect(Fixtures.annotations(in: fresh) == annotations, "seed \(seed): no annotation added or removed")
    }

    @Test("A foreign annotation carrying a marker's identifier is never treated as the marker's")
    func foreignWithMarkerIdentifier() throws {
        var (_, damaged, markers, random) = try fixture(seed: 7, count: 4)
        damage(damaged, markers, random: &random)
        // Another reader's comment and highlight claim the first marker's identifier but not
        // Annotate's ownership.
        let marker = try #require(markers.first)
        let page = try #require(damaged.page(at: marker.pageIndex))
        let impostor = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 20, height: 20), forType: .text, withProperties: nil)
        impostor.contents = "Impostor"
        impostor.setValue(marker.id.uuidString, forAnnotationKey: MarkerCodec.identifierKey)
        page.addAnnotation(impostor)
        let highlight = PDFAnnotation(bounds: CGRect(x: 40, y: 40, width: 40, height: 10), forType: .highlight, withProperties: nil)
        highlight.contents = "Foreign highlight"
        highlight.setValue(marker.id.uuidString, forAnnotationKey: MarkerCodec.identifierKey)
        highlight.setValue("someone.else", forAnnotationKey: MarkerCodec.ownerKey)
        page.addAnnotation(highlight)
        // PDFKit gives a new Text annotation a popup of its own; the refresh must not swap it.
        let impostorBounds = impostor.bounds, impostorPopup = impostor.popup
        MarkerCodec.refreshAppearance(in: damaged)
        #expect(impostor.contents == "Impostor" && impostor.bounds == impostorBounds && impostor.popup === impostorPopup)
        #expect(highlight.contents == "Foreign highlight")
        #expect(page.annotations.filter { $0.type == "Text" && owned($0) == marker.id }.count == 1)
    }

    @Test("An identifier spelled in lower case still belongs to its marker")
    func lowercaseIdentifier() throws {
        // The old scan compared identifiers as UUIDs, not strings; the index must too.
        let document = try Fixtures.document()
        let marker = try Fixtures.marker(in: document)
        try MarkerCodec.apply(marker, to: document)
        for annotation in Fixtures.annotations(in: document) where owned(annotation) == marker.id {
            annotation.setValue(marker.id.uuidString.lowercased(), forAnnotationKey: MarkerCodec.identifierKey)
            if annotation.type == "Text" { annotation.popup = nil; annotation.page?.removeAnnotation(annotation) }
            if annotation.type == "Highlight" { annotation.contents = "Legacy" }
        }
        MarkerCodec.refreshAppearance(in: document)
        let mine = Fixtures.annotations(in: document).filter { owned($0) == marker.id }
        #expect(mine.filter { $0.type == "Text" }.count == 1)
        #expect(mine.filter { $0.type == "Popup" }.count == 1, "the existing popup is reused, not duplicated")
        #expect(mine.filter { $0.type == "Highlight" }.allSatisfy { $0.contents?.isEmpty ?? true })
    }

    @Test("Hundreds of damaged markers on one page refresh quickly and correctly")
    func manyMarkersOnOnePage() throws {
        var (fresh, damaged, markers, random) = try fixture(seed: 4242, count: 0)
        markers = self.markers(400, in: fresh, random: &random, pages: 0...0)
        for marker in markers {
            try MarkerCodec.apply(marker, to: fresh)
            try MarkerCodec.apply(marker, to: damaged)
        }
        damage(damaged, markers, random: &random)
        let clock = ContinuousClock(), start = clock.now
        MarkerCodec.refreshAppearance(in: damaged)
        let time = clock.now - start
        #expect(snapshot(damaged) == snapshot(fresh))
        #expect(time < .seconds(5), "\(time)")
    }
}
