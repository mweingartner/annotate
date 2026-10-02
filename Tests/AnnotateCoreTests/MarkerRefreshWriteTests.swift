import AppKit
import PDFKit
import Testing
@testable import AnnotateCore

/// `refreshAppearance` runs on load and after every edit. It creates a comment or popup only
/// when one is missing and writes only values that changed, because a write marks the
/// annotation for saving. These tests watch the writes directly, through a counting
/// annotation installed as the codec's factory, and check every repair still converges.
@Suite("Marker appearance refresh writes only what changed", .serialized)
@MainActor
struct MarkerRefreshWriteTests {
    private typealias Counting = CountingMarkerAnnotation

    private func mine(_ document: PDFDocument, _ marker: PDFMarker) -> [PDFAnnotation] {
        Fixtures.annotations(in: document).filter { BulkFixtures.owner(of: $0) == marker.id }
    }

    /// A healthy document of `count` markers across all four pages, two of them rotated and
    /// cropped, so the comment placement isn't the identity transform.
    private func healthy(_ count: Int, seed: UInt64) throws -> (PDFDocument, [PDFMarker]) {
        var random = BulkRandom(seed: seed)
        let document = try Fixtures.document()
        try #require(document.page(at: 1)).rotation = 90
        try #require(document.page(at: 2)).setBounds(CGRect(x: 30, y: 40, width: 500, height: 700), for: .cropBox)
        try #require(document.page(at: 2)).rotation = 270
        let markers = BulkFixtures.markers(count, in: document, random: &random, regions: 1...3)
        for marker in markers { try MarkerCodec.apply(marker, to: document) }
        return (document, markers)
    }

    @Test("Refreshing a healthy document writes nothing and adds nothing", arguments: Array(UInt64(1)...UInt64(4)))
    func healthyWritesNothing(seed: UInt64) throws {
        try Counting.installed {
            let (document, markers) = try healthy(16, seed: seed)
            let before = Fixtures.annotations(in: document)
            Counting.writes = []
            MarkerCodec.refreshAppearance(in: document)
            #expect(Counting.writes.isEmpty, "seed \(seed): \(Counting.writes.prefix(10))")
            #expect(Fixtures.annotations(in: document) == before)
            #expect(BulkFixtures.byID(MarkerCodec.markers(in: document)) == BulkFixtures.byID(markers))
        }
    }

    @Test("A reopened comment whose popup is on the page but not linked is relinked to that popup, not given another")
    func relinksExistingPopup() throws {
        let (document, markers) = try healthy(3, seed: 7)
        // Saved once and refreshed (as on load), then saved again: the popups are in the file.
        let once = try Fixtures.reopen(document)
        MarkerCodec.refreshAppearance(in: once)
        let reopened = try Fixtures.reopen(once)
        let marker = markers[1]
        let comment = try #require(mine(reopened, marker).first { $0.type == "Text" })
        let popup = try #require(mine(reopened, marker).first { $0.type == "Popup" })
        let count = Fixtures.annotations(in: reopened).count
        MarkerCodec.refreshAppearance(in: reopened)
        #expect(comment.popup === popup, "the popup already on the page is reused")
        #expect(Fixtures.annotations(in: reopened).count == count, "no second popup")
        MarkerCodec.refreshAppearance(in: reopened)
        #expect(comment.popup === popup && Fixtures.annotations(in: reopened).count == count)
        #expect(BulkFixtures.audit(reopened).isEmpty, "\(BulkFixtures.audit(reopened))")
    }

    @Test("A comment unlinked from its popup (which PDFKit then drops) gets a new popup, linked, and only that is written")
    func replacesDroppedPopup() throws {
        try Counting.installed {
            let (document, markers) = try healthy(3, seed: 7)
            let marker = markers[1]
            let comment = try #require(mine(document, marker).first { $0.type == "Text" })
            comment.popup = nil
            #expect(!mine(document, marker).contains { $0.type == "Popup" })
            Counting.writes = []
            MarkerCodec.refreshAppearance(in: document)
            let popups = mine(document, marker).filter { $0.type == "Popup" }
            #expect(popups.count == 1 && comment.popup === popups.first)
            // The writes to the existing comment: its popup link only. (A comment tag is made
            // alongside the popup and discarded; its own writes are construction.)
            #expect(Counting.writes.filter { $0 == "Text bounds" }.isEmpty)
            #expect(BulkFixtures.audit(document).isEmpty, "\(BulkFixtures.audit(document))")
            Counting.writes = []
            MarkerCodec.refreshAppearance(in: document)
            #expect(Counting.writes.isEmpty, "\(Counting.writes)")
        }
    }

    @Test("A moved comment and a recolored badge are put back; a second refresh writes nothing")
    func repairsThenSettles() throws {
        try Counting.installed {
            let (document, markers) = try healthy(4, seed: 8)
            let reference = try Fixtures.document()
            try #require(reference.page(at: 1)).rotation = 90
            try #require(reference.page(at: 2)).setBounds(CGRect(x: 30, y: 40, width: 500, height: 700), for: .cropBox)
            try #require(reference.page(at: 2)).rotation = 270
            for marker in markers { try MarkerCodec.apply(marker, to: reference) }
            let marker = markers[2]
            let comment = try #require(mine(document, marker).first { $0.type == "Text" })
            let badge = try #require(mine(document, marker).first { $0.type == "FreeText" })
            let expectedComment = try #require(mine(reference, marker).first { $0.type == "Text" })
            let expectedBounds = comment.bounds, expectedColor = comment.color
            comment.bounds = comment.bounds.offsetBy(dx: 40, dy: -25)
            comment.color = .black
            badge.fontColor = NSColor(srgbRed: 0.5, green: 0.1, blue: 0.9, alpha: 1)
            badge.color = NSColor(srgbRed: 0.1, green: 0.9, blue: 0.5, alpha: 1)

            Counting.writes = []
            MarkerCodec.refreshAppearance(in: document)
            #expect(Counting.writes.sorted() == ["FreeText color", "FreeText fontColor", "Text bounds", "Text color"])
            #expect(comment.bounds == expectedBounds && comment.bounds == expectedComment.bounds)
            #expect(comment.color.usingColorSpace(.sRGB) == expectedColor.usingColorSpace(.sRGB))
            #expect(badge.color.usingColorSpace(.sRGB) == marker.color.nsColor.usingColorSpace(.sRGB))
            #expect(badge.fontColor?.usingColorSpace(.sRGB) == marker.color.readableInkColor.usingColorSpace(.sRGB))

            Counting.writes = []
            MarkerCodec.refreshAppearance(in: document)
            #expect(Counting.writes.isEmpty, "\(Counting.writes)")
        }
    }

    @Test("Differences finer than a saved PDF keeps aren't written; anything coarser is", arguments: [
        (0.0, 0.0, false), (0.004, 0.0, false), (0.0, 0.0015, false), (0.02, 0.0, true), (0.0, 0.004, true)
    ])
    func tolerance(boundsShift: Double, colorShift: Double, written: Bool) throws {
        try Counting.installed {
            let (document, markers) = try healthy(1, seed: 9)
            let comment = try #require(mine(document, markers[0]).first { $0.type == "Text" })
            let bounds = comment.bounds
            let color = try #require(comment.color.usingColorSpace(.sRGB))
            comment.bounds = bounds.offsetBy(dx: boundsShift, dy: 0)
            comment.color = NSColor(srgbRed: max(0, color.redComponent - colorShift), green: color.greenComponent, blue: color.blueComponent, alpha: 1)
            Counting.writes = []
            MarkerCodec.refreshAppearance(in: document)
            #expect(!Counting.writes.isEmpty == written, "\(Counting.writes)")
            if written {
                #expect(abs(comment.bounds.minX - bounds.minX) < 0.001)
                #expect(abs((comment.color.usingColorSpace(.sRGB)?.redComponent ?? -1) - color.redComponent) < 0.001)
            }
        }
    }

    @Test("A badge whose colors are in another color space but match is left alone")
    func colorSpaceIndependent() throws {
        try Counting.installed {
            let (document, markers) = try healthy(1, seed: 10)
            let badge = try #require(mine(document, markers[0]).first { $0.type == "FreeText" })
            badge.color = try #require(markers[0].color.nsColor.usingColorSpace(.extendedSRGB))
            badge.fontColor = try #require(markers[0].color.readableInkColor.usingColorSpace(.displayP3))
            Counting.writes = []
            MarkerCodec.refreshAppearance(in: document)
            #expect(Counting.writes.isEmpty, "\(Counting.writes)")
        }
    }

    @Test("A marker missing both its comment and its popup gets one of each, linked, with readable contents")
    func bothMissing() throws {
        let (document, markers) = try healthy(3, seed: 11)
        let marker = markers[0]
        let page = try #require(document.page(at: marker.pageIndex))
        for annotation in mine(document, marker) where annotation.type == "Text" || annotation.type == "Popup" {
            annotation.popup = nil
            page.removeAnnotation(annotation)
        }
        MarkerCodec.refreshAppearance(in: document)
        let parts = mine(document, marker)
        let comments = parts.filter { $0.type == "Text" }, popups = parts.filter { $0.type == "Popup" }
        #expect(comments.count == 1 && popups.count == 1)
        #expect(comments.first?.popup === popups.first)
        #expect(comments.first?.contents == MarkerCodec.readableContents(for: marker))
        #expect(comments.first?.page === page && popups.first?.page === page)
        #expect(BulkFixtures.audit(document).isEmpty, "\(BulkFixtures.audit(document))")
        MarkerCodec.refreshAppearance(in: document)
        #expect(mine(document, marker).count == parts.count, "a second refresh adds nothing")
    }

    @Test("A legacy marker that kept its comment on the highlight loses it, on every page of the marker, once")
    func legacyHighlightContents() throws {
        try Counting.installed {
            let document = try Fixtures.document()
            var marker = try Fixtures.marker(in: document)
            marker.regions.append(PageRegion(pageIndex: 2, bounds: CGRect(x: 80, y: 90, width: 100, height: 14)))
            try MarkerCodec.apply(marker, to: document)
            for highlight in mine(document, marker) where highlight.type == "Highlight" {
                highlight.contents = MarkerCodec.readableContents(for: marker)
            }
            Counting.writes = []
            MarkerCodec.refreshAppearance(in: document)
            #expect(Counting.writes.filter { $0 == "Highlight contents" }.count == marker.regions.count)
            #expect(mine(document, marker).filter { $0.type == "Highlight" }.allSatisfy { $0.contents == nil })
            Counting.writes = []
            MarkerCodec.refreshAppearance(in: document)
            #expect(Counting.writes.isEmpty, "\(Counting.writes)")
        }
    }

    @Test("Saving, reopening and refreshing again and again keeps exactly one of every part")
    func stableAcrossSaves() throws {
        let (document, markers) = try healthy(8, seed: 12)
        var current = document
        var censuses: [[String]] = []
        for _ in 0..<4 {
            current = try Fixtures.reopen(current)
            MarkerCodec.refreshAppearance(in: current)
            MarkerCodec.refreshAppearance(in: current)
            #expect(BulkFixtures.audit(current).isEmpty, "\(BulkFixtures.audit(current).prefix(5))")
            #expect(BulkFixtures.byID(MarkerCodec.markers(in: current)) == BulkFixtures.byID(markers))
            censuses.append(Fixtures.annotations(in: current).map { $0.type ?? "?" }.sorted())
        }
        #expect(censuses.allSatisfy { $0 == censuses[0] }, "\(censuses)")
    }

    @Test("A restricted document is left exactly as it is")
    func restrictedUntouched() throws {
        let source = try Fixtures.document()
        let marker = try Fixtures.marker(in: source)
        try MarkerCodec.apply(marker, to: source)
        let page = try #require(source.page(at: marker.pageIndex))
        for annotation in mine(source, marker) where annotation.type == "Text" { annotation.popup = nil; page.removeAnnotation(annotation) }
        let data = try #require(source.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "owner", PDFDocumentWriteOption.userPasswordOption: "reader", PDFDocumentWriteOption.accessPermissionsOption: 0]))
        let restricted = try #require(PDFDocument(data: data))
        MarkerCodec.refreshAppearance(in: restricted)
        #expect(restricted.unlock(withPassword: "reader") && !restricted.allowsCommenting)
        let before = Fixtures.annotations(in: restricted).count
        MarkerCodec.refreshAppearance(in: restricted)
        #expect(Fixtures.annotations(in: restricted).count == before)
        #expect(!mine(restricted, marker).contains { $0.type == "Text" })
    }

    // MARK: - Non-functional

    @Test("Refreshing reads each marker annotation a fixed number of times and, healthy, writes none, at any size")
    func refreshScalesByCount() throws {
        func measure(_ count: Int) throws -> (reads: Double, writes: Int) {
            try Counting.installed {
                let (document, _) = try BulkFixtures.document(markers: count, seed: 51, regions: 1...2)
                let counted = Fixtures.annotations(in: document).filter { $0 is Counting }.count
                Counting.keyReads = 0; Counting.writes = []
                MarkerCodec.refreshAppearance(in: document)
                return (Double(Counting.keyReads) / Double(counted), Counting.writes.count)
            }
        }
        let small = try measure(50), large = try measure(800)
        print("refreshAppearance: \(small.reads) reads per marker annotation at 50 markers, \(large.reads) at 800")
        #expect(small.writes == 0 && large.writes == 0)
        #expect(large.reads < 8 && large.reads < small.reads * 1.5 + 1, "\(small.reads) → \(large.reads)")
    }

    @Test("Refreshing four times the markers takes about four times as long")
    func refreshTimeScales() throws {
        func time(_ count: Int) throws -> Double {
            let (document, _) = try BulkFixtures.document(markers: count, seed: 52, regions: 1...1)
            var best = Double.infinity
            for _ in 0..<3 {
                let start = ContinuousClock.now
                MarkerCodec.refreshAppearance(in: document)
                let elapsed = start.duration(to: .now)
                best = min(best, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            }
            return best
        }
        _ = try time(50)
        let small = try time(500), large = try time(2_000)
        print("refreshAppearance: \(small) s at 500 markers, \(large) s at 2,000 (ratio \(large / small))")
        #expect(large / small < 9, "ratio \(large / small)")
        #expect(large < 2, "\(large) s at 2,000 markers")
    }
}
