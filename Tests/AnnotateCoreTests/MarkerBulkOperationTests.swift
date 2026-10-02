import AppKit
import PDFKit
import Testing
@testable import AnnotateCore

/// SplitMix64: every generated document and operation sequence replays from its seed.
struct BulkRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 ^ 0x5851_F42D_4C95_7F2D }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A marker annotation that counts how often Annotate's own keys are read from it and which
/// of the properties `refreshAppearance` may change are written to it. Installed through
/// `MarkerCodec.makeAnnotation`, so it stands in for every highlight, badge and comment
/// (popups are made directly by the codec and aren't counted).
final class CountingMarkerAnnotation: PDFAnnotation {
    nonisolated(unsafe) static var keyReads = 0
    nonisolated(unsafe) static var writes: [String] = []
    private static let markerKeys: Set<String> = ["/AnnotateMarker", "/AnnotateMarkerID", "/AnnotateOwner"]

    override func value(forAnnotationKey key: PDFAnnotationKey) -> Any? {
        if Self.markerKeys.contains(key.rawValue) { Self.keyReads += 1 }
        return super.value(forAnnotationKey: key)
    }
    override var bounds: CGRect {
        get { super.bounds }
        set { Self.writes.append("\(type ?? "?") bounds"); super.bounds = newValue }
    }
    override var color: NSColor {
        get { super.color }
        set { Self.writes.append("\(type ?? "?") color"); super.color = newValue }
    }
    override var fontColor: NSColor? {
        get { super.fontColor }
        set { Self.writes.append("\(type ?? "?") fontColor"); super.fontColor = newValue }
    }
    override var popup: PDFAnnotation? {
        get { super.popup }
        set { Self.writes.append("\(type ?? "?") popup"); super.popup = newValue }
    }
    override var contents: String? {
        get { super.contents }
        set { Self.writes.append("\(type ?? "?") contents"); super.contents = newValue }
    }

    /// Runs `body` with every new marker annotation counted, then restores the app's factory.
    @MainActor
    static func installed<T>(_ body: () throws -> T) rethrows -> T {
        let previous = MarkerCodec.makeAnnotation
        MarkerCodec.makeAnnotation = { CountingMarkerAnnotation(bounds: $0, forType: $1, withProperties: nil) }
        defer { MarkerCodec.makeAnnotation = previous }
        keyReads = 0; writes = []
        return try body()
    }
}

/// Shared marker-document helpers for the bulk-operation and refresh suites.
@MainActor
enum BulkFixtures {
    static func owner(of annotation: PDFAnnotation) -> UUID? {
        guard annotation.value(forAnnotationKey: MarkerCodec.ownerKey) as? String == MarkerCodec.ownerValue else { return nil }
        return (annotation.value(forAnnotationKey: MarkerCodec.identifierKey) as? String).flatMap(UUID.init(uuidString:))
    }

    /// Markers with one to three regions on random pages (or `pages`), unique notes, and
    /// a deterministic creation date, so one seed always draws the same set.
    static func markers(_ count: Int, in document: PDFDocument, random: inout BulkRandom, pages: ClosedRange<Int>? = nil, regions: ClosedRange<Int> = 1...3) -> [PDFMarker] {
        (0..<count).map { index in
            let regions = (0..<Int.random(in: regions, using: &random)).map { _ -> PageRegion in
                let pageIndex = Int.random(in: pages ?? 0...(document.pageCount - 1), using: &random)
                let media = document.page(at: pageIndex)!.bounds(for: .mediaBox)
                let width = Double.random(in: 20...200, using: &random).rounded(), height = Double.random(in: 8...30, using: &random).rounded()
                let x = Double.random(in: media.minX...(media.maxX - width), using: &random)
                let y = Double.random(in: media.minY...(media.maxY - height), using: &random)
                return PageRegion(pageIndex: pageIndex, bounds: CGRect(x: x, y: y, width: width, height: height))
            }
            let categories: [Set<MarkerCategory>] = [[.important], [.revisit, .question], [.note], [.important, .note]]
            return PDFMarker(categories: categories[index % categories.count], color: MarkerColor.palette[index % MarkerColor.palette.count],
                             icon: ["star.fill", "flag.fill", "questionmark.circle", "pin"][index % 4],
                             quote: "Quote \(index)", note: "Note \(index) \(random.next() % 1_000)", question: index.isMultiple(of: 3) ? "Question \(index)?" : "",
                             regions: regions, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
        }
    }

    /// What is wrong with the owned annotations: every one belongs to a readable marker, and
    /// each marker has exactly one highlight per region (on that region's page, at its bounds)
    /// and exactly one badge, comment and popup, on its first page.
    static func audit(_ document: PDFDocument) -> [String] {
        let markers = MarkerCodec.markers(in: document)
        let known = Dictionary(uniqueKeysWithValues: markers.map { ($0.id, $0) })
        var problems: [String] = []
        var found: [UUID: [(page: Int, annotation: PDFAnnotation)]] = [:]
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] {
                guard let id = owner(of: annotation) else { continue }
                if known[id] == nil { problems.append("page \(index): orphan \(annotation.type ?? "?") of \(id)") }
                found[id, default: []].append((index, annotation))
            }
        }
        for marker in markers {
            let mine = found[marker.id] ?? []
            for type in ["FreeText", "Text", "Popup"] {
                let parts = mine.filter { $0.annotation.type == type }
                if parts.count != 1 || parts.first?.page != marker.pageIndex {
                    problems.append("\(marker.note): \(parts.count) \(type) on pages \(parts.map(\.page)), expected 1 on \(marker.pageIndex)")
                }
            }
            var highlights = mine.filter { $0.annotation.type == "Highlight" }
            for region in marker.regions {
                if let match = highlights.firstIndex(where: { $0.page == region.pageIndex && close($0.annotation.bounds, region.bounds) }) {
                    highlights.remove(at: match)
                } else { problems.append("\(marker.note): no highlight for \(region)") }
            }
            if !highlights.isEmpty { problems.append("\(marker.note): \(highlights.count) extra highlights") }
            let unknown = mine.filter { !["FreeText", "Text", "Popup", "Highlight"].contains($0.annotation.type ?? "") }
            if !unknown.isEmpty { problems.append("\(marker.note): unexpected \(unknown.map { $0.annotation.type ?? "?" })") }
        }
        return problems
    }

    static func close(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.5 && abs(lhs.minY - rhs.minY) < 0.5 && abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
    }

    static func byID(_ markers: [PDFMarker]) -> [PDFMarker] { markers.sorted { $0.id.uuidString < $1.id.uuidString } }

    /// A marker's content with its identifier blanked, as a sortable string: comparing these
    /// as multisets matches markers that `insert` gave fresh identifiers.
    static func content(_ marker: PDFMarker) -> String {
        // Categories are a set, whose encoded order differs between equal sets.
        let categories = marker.categories.map(\.rawValue).sorted().joined(separator: ",")
        let regions = marker.regions.map { "\($0.pageIndex):\($0.bounds.minX),\($0.bounds.minY),\($0.bounds.width),\($0.bounds.height)" }
        return [categories, "\(marker.color)", marker.icon, marker.quote, marker.note, marker.question,
                "\(marker.createdAt.timeIntervalSinceReferenceDate)", regions.joined(separator: ";")].joined(separator: "|")
    }

    /// A document of the four-page tour carrying `count` markers, added without the
    /// replacing scan so building a large one isn't itself quadratic.
    static func document(markers count: Int, seed: UInt64, regions: ClosedRange<Int> = 1...2) throws -> (PDFDocument, [PDFMarker]) {
        var random = BulkRandom(seed: seed)
        let document = try Fixtures.document()
        let markers = markers(count, in: document, random: &random, regions: regions)
        for marker in markers { try MarkerCodec.apply(marker, to: document, replacing: false) }
        return (document, markers)
    }
}

/// Page operations remove every marker's annotations in one pass and restore them without
/// another scan per marker. These tests hold that to an independent oracle: the markers that
/// come back are exactly the ones expected, with exact regions and metadata, and nothing is
/// duplicated or orphaned.
@Suite("Bulk marker removal and restore in page operations", .serialized)
@MainActor
struct MarkerBulkOperationTests {
    // MARK: - remove(ids:)

    @Test("Removing several markers at once removes all of their parts on every page and nothing else")
    func removeSeveral() throws {
        var random = BulkRandom(seed: 11)
        let document = try Fixtures.document()
        let markers = BulkFixtures.markers(5, in: document, random: &random, regions: 2...3)
        for marker in markers { try MarkerCodec.apply(marker, to: document) }
        let foreign = Fixtures.foreignAnnotation(on: try #require(document.page(at: 1)))
        // Another reader's annotation that carries a marker's identifier but not Annotate's
        // ownership is not the marker's.
        let impostor = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .square, withProperties: nil)
        impostor.setValue(markers[0].id.uuidString, forAnnotationKey: MarkerCodec.identifierKey)
        try #require(document.page(at: 2)).addAnnotation(impostor)
        let before = Fixtures.annotations(in: document).count

        MarkerCodec.remove(ids: [markers[0].id, markers[3].id], from: document)
        let left = Fixtures.annotations(in: document)
        #expect(!left.contains { [markers[0].id, markers[3].id].contains(BulkFixtures.owner(of: $0)) })
        #expect(left.contains { $0 === foreign } && left.contains { $0 === impostor })
        #expect(BulkFixtures.byID(MarkerCodec.markers(in: document)) == BulkFixtures.byID([markers[1], markers[2], markers[4]]))
        let removedParts = [markers[0], markers[3]].reduce(0) { $0 + $1.regions.count + 3 }
        #expect(left.count == before - removedParts)
        #expect(BulkFixtures.audit(document).isEmpty, "\(BulkFixtures.audit(document))")

        // Saving doesn't bring back a removed comment's popup.
        let reopened = try Fixtures.reopen(document)
        #expect(!Fixtures.annotations(in: reopened).contains { [markers[0].id, markers[3].id].contains(BulkFixtures.owner(of: $0)) })
        #expect(BulkFixtures.byID(MarkerCodec.markers(in: reopened)) == BulkFixtures.byID([markers[1], markers[2], markers[4]]))
    }

    @Test("Removing a marker removes its popup even when the popup has lost its comment")
    func removesOrphanPopup() throws {
        let document = try Fixtures.document()
        let marker = try Fixtures.marker(in: document)
        try MarkerCodec.apply(marker, to: document)
        let page = try #require(document.page(at: marker.pageIndex))
        // An owned popup with no comment, as a damaged file or another reader may leave.
        let popup = PDFAnnotation(bounds: CGRect(x: 300, y: 300, width: 240, height: 140), forType: .popup, withProperties: nil)
        popup.setValue(MarkerCodec.ownerValue, forAnnotationKey: MarkerCodec.ownerKey)
        popup.setValue(marker.id.uuidString, forAnnotationKey: MarkerCodec.identifierKey)
        try #require(document.page(at: 3)).addAnnotation(popup)
        MarkerCodec.remove(ids: [marker.id], from: document)
        #expect(!Fixtures.annotations(in: document).contains { BulkFixtures.owner(of: $0) == marker.id })
        #expect(!page.annotations.contains { $0.type == "Popup" })
    }

    @Test("Removing no markers, or a marker that isn't there, changes nothing; removing one by id matches removing a set of one")
    func removeEdgeCases() throws {
        var random = BulkRandom(seed: 12)
        let document = try Fixtures.document()
        let markers = BulkFixtures.markers(3, in: document, random: &random)
        for marker in markers { try MarkerCodec.apply(marker, to: document) }
        let all = Fixtures.annotations(in: document)
        MarkerCodec.remove(ids: [], from: document)
        MarkerCodec.remove(ids: [UUID()], from: document)
        #expect(Fixtures.annotations(in: document) == all)

        let twin = try Fixtures.document()
        for marker in markers { try MarkerCodec.apply(marker, to: twin) }
        MarkerCodec.remove(id: markers[1].id, from: document)
        MarkerCodec.remove(ids: [markers[1].id], from: twin)
        #expect(BulkFixtures.byID(MarkerCodec.markers(in: document)) == BulkFixtures.byID(MarkerCodec.markers(in: twin)))
        #expect(Fixtures.annotations(in: document).count == Fixtures.annotations(in: twin).count)
    }

    @Test("A document that doesn't allow commenting keeps its markers when asked to remove them")
    func removeRestricted() throws {
        let source = try Fixtures.document()
        let marker = try Fixtures.marker(in: source)
        try MarkerCodec.apply(marker, to: source)
        let data = try #require(source.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "owner", PDFDocumentWriteOption.userPasswordOption: "reader", PDFDocumentWriteOption.accessPermissionsOption: 0]))
        let restricted = try #require(PDFDocument(data: data))
        #expect(restricted.isLocked)
        MarkerCodec.remove(ids: [marker.id], from: restricted)
        #expect(restricted.unlock(withPassword: "reader"))
        #expect(!restricted.allowsCommenting)
        let count = Fixtures.annotations(in: restricted).count
        MarkerCodec.remove(ids: [marker.id], from: restricted)
        #expect(Fixtures.annotations(in: restricted).count == count)
        #expect(MarkerCodec.markers(in: restricted).map(\.id) == [marker.id])
    }

    @Test("Adding a removed marker without the replacing scan gives the same result as replacing it")
    func nonReplacingApply() throws {
        let (document, markers) = try BulkFixtures.document(markers: 6, seed: 13)
        let twin = try Fixtures.reopen(document)
        MarkerCodec.remove(ids: Set(markers.map(\.id)), from: twin)
        for marker in markers { try MarkerCodec.apply(marker, to: twin, replacing: false) }
        for marker in markers { try MarkerCodec.apply(marker, to: document) }
        #expect(BulkFixtures.byID(MarkerCodec.markers(in: twin)) == BulkFixtures.byID(markers))
        #expect(BulkFixtures.byID(MarkerCodec.markers(in: document)) == BulkFixtures.byID(markers))
        #expect(BulkFixtures.audit(twin).isEmpty, "\(BulkFixtures.audit(twin))")
        #expect(BulkFixtures.audit(document).isEmpty, "\(BulkFixtures.audit(document))")
        // A failed non-replacing apply leaves nothing behind.
        var invalid = markers[0]
        invalid.regions = [PageRegion(pageIndex: 99, bounds: CGRect(x: 1, y: 1, width: 5, height: 5))]
        let count = Fixtures.annotations(in: twin).count
        #expect(throws: (any Error).self) { try MarkerCodec.apply(invalid, to: twin, replacing: false) }
        #expect(Fixtures.annotations(in: twin).count == count)
    }

    // MARK: - Page operations against an oracle

    /// What a document should contain: each page's text, its foreign comments, and its markers.
    private struct Expected {
        var pages: [String]
        var foreign: [Int]
        var markers: [PDFMarker]
    }

    private func observed(_ document: PDFDocument) -> Expected {
        Expected(pages: (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" },
                 foreign: (0..<document.pageCount).map { index in
                     document.page(at: index)?.annotations.filter { $0.type == "Text" && BulkFixtures.owner(of: $0) == nil }.count ?? 0
                 },
                 markers: BulkFixtures.byID(MarkerCodec.markers(in: document)))
    }

    /// The page-renumbering rule, written independently of `PDFPageOrganizer.restore`: regions
    /// on dropped pages go, the rest keep their order within a page and are sorted by page.
    private func remapped(_ markers: [PDFMarker], _ mapping: [Int: Int]) -> [PDFMarker] {
        markers.compactMap { marker in
            var marker = marker
            let kept = marker.regions.enumerated().compactMap { offset, region in
                mapping[region.pageIndex].map { (offset, PageRegion(pageIndex: $0, bounds: region.bounds)) }
            }
            marker.regions = kept.sorted { ($0.1.pageIndex, $0.0) < ($1.1.pageIndex, $1.0) }.map(\.1)
            return marker.regions.isEmpty ? nil : marker
        }
    }

    private func compare(_ document: PDFDocument, _ expected: Expected, _ context: String) {
        let got = observed(document)
        #expect(got.pages == expected.pages, "\(context): page order")
        #expect(got.foreign == expected.foreign, "\(context): foreign comments")
        #expect(got.markers == BulkFixtures.byID(expected.markers), "\(context): markers")
        let problems = BulkFixtures.audit(document)
        #expect(problems.isEmpty, "\(context): \(problems.prefix(8))")
    }

    @Test("Random reorders, moves, deletions and insertions (blank pages and the document into itself) keep every marker exact",
          arguments: Array(UInt64(1)...UInt64(10)))
    func randomOperations(seed: UInt64) throws {
        var random = BulkRandom(seed: seed)
        let document = try Fixtures.document()
        for index in 0..<document.pageCount { _ = Fixtures.foreignAnnotation(on: try #require(document.page(at: index))) }
        let initial = BulkFixtures.markers(10, in: document, random: &random)
        for marker in initial { try MarkerCodec.apply(marker, to: document) }
        var expected = observed(document)
        #expect(expected.markers == BulkFixtures.byID(initial))
        var log: [String] = []
        for step in 0..<5 {
            let count = document.pageCount
            switch Int.random(in: 0..<5, using: &random) {
            case 0:
                let order = Array(0..<count).shuffled(using: &random)
                log.append("reorder \(order)")
                try PDFPageOrganizer.reorder(document, order: order)
                let mapping = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
                expected = Expected(pages: order.map { expected.pages[$0] }, foreign: order.map { expected.foreign[$0] }, markers: remapped(expected.markers, mapping))
            case 1:
                let page = Int.random(in: 0..<count, using: &random), destination = Int.random(in: 0..<count, using: &random)
                log.append("move \(page) to \(destination)")
                try PDFPageOrganizer.move(document, page: page, to: destination)
                var order = Array(0..<count)
                order.insert(order.remove(at: page), at: destination)
                let mapping = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
                expected = Expected(pages: order.map { expected.pages[$0] }, foreign: order.map { expected.foreign[$0] }, markers: remapped(expected.markers, mapping))
            case 2 where count > 1:
                let deleted = IndexSet(Array(0..<count).shuffled(using: &random).prefix(Int.random(in: 1...(count - 1), using: &random)))
                log.append("delete \(Array(deleted))")
                try PDFPageOrganizer.delete(document, pages: deleted)
                let kept = (0..<count).filter { !deleted.contains($0) }
                let mapping = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($0.element, $0.offset) })
                expected = Expected(pages: kept.map { expected.pages[$0] }, foreign: kept.map { expected.foreign[$0] }, markers: remapped(expected.markers, mapping))
            case 3 where count <= 8:
                let at = Int.random(in: 0...count, using: &random)
                log.append("insert itself at \(at)")
                let before = expected
                try PDFPageOrganizer.insert(document, into: document, at: at)
                let existing = remapped(before.markers, Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, $0 < at ? $0 : $0 + count) }))
                let incoming = remapped(before.markers, Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, at + $0) }))
                let all = MarkerCodec.markers(in: document)
                let fresh = all.filter { marker in !before.markers.contains { $0.id == marker.id } }
                #expect(Set(all.map(\.id)).count == all.count, "seed \(seed): identifiers stay unique")
                #expect(fresh.map(BulkFixtures.content).sorted() == incoming.map(BulkFixtures.content).sorted(), "seed \(seed) \(log): the inserted copies")
                expected = Expected(pages: Array(before.pages[..<at]) + before.pages + before.pages[at...],
                                    foreign: Array(before.foreign[..<at]) + before.foreign + before.foreign[at...],
                                    markers: existing + fresh)
            default:
                let at = Int.random(in: 0...count, using: &random)
                log.append("insert blank at \(at)")
                try PDFPageOrganizer.insertBlank(into: document, at: at)
                let blank = try #require(document.page(at: at)).string ?? ""
                let mapping = Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, $0 < at ? $0 : $0 + 1) })
                var pages = expected.pages, foreign = expected.foreign
                pages.insert(blank, at: at); foreign.insert(0, at: at)
                expected = Expected(pages: pages, foreign: foreign, markers: remapped(expected.markers, mapping))
            }
            compare(document, expected, "seed \(seed) step \(step) \(log)")
        }
        // Saved and reopened (the app refreshes appearances on load), the same holds.
        let reopened = try Fixtures.reopen(document)
        MarkerCodec.refreshAppearance(in: reopened)
        compare(reopened, expected, "seed \(seed) reopened \(log)")
    }

    // MARK: - Duplicates, leftovers and self-insertion

    @Test("A marker whose anchor is repeated in a damaged file comes back once, from its first anchor, with no stray copy")
    func duplicateAnchors() throws {
        let document = try Fixtures.document()
        var random = BulkRandom(seed: 21)
        let first = try #require(BulkFixtures.markers(1, in: document, random: &random, pages: 0...0).first)
        var repeated = try #require(BulkFixtures.markers(1, in: document, random: &random, pages: 2...2).first)
        repeated.id = first.id
        try MarkerCodec.apply(first, to: document, replacing: false)
        try MarkerCodec.apply(repeated, to: document, replacing: false)
        let other = try #require(BulkFixtures.markers(1, in: document, random: &random, pages: 1...1).first)
        try MarkerCodec.apply(other, to: document)
        #expect(MarkerCodec.markers(in: document).map(\.id).filter { $0 == first.id }.count == 1)

        try PDFPageOrganizer.reorder(document, order: [3, 2, 1, 0])
        var moved = first
        moved.regions = first.regions.map { PageRegion(pageIndex: 3 - $0.pageIndex, bounds: $0.bounds) }
        var otherMoved = other
        otherMoved.regions = other.regions.map { PageRegion(pageIndex: 3 - $0.pageIndex, bounds: $0.bounds) }
        #expect(BulkFixtures.byID(MarkerCodec.markers(in: document)) == BulkFixtures.byID([moved, otherMoved]))
        #expect(BulkFixtures.audit(document).isEmpty, "\(BulkFixtures.audit(document))")
        #expect(Fixtures.annotations(in: document).filter { BulkFixtures.owner(of: $0) == first.id }.count == moved.regions.count + 3)
    }

    @Test("Inserting a damaged file whose repeated anchor shares an existing marker's identifier keeps both markers whole and separate")
    func insertDuplicateAnchors() throws {
        let document = try Fixtures.document()
        var random = BulkRandom(seed: 22)
        let mine = try #require(BulkFixtures.markers(1, in: document, random: &random, pages: 1...1).first)
        try MarkerCodec.apply(mine, to: document)
        let source = try Fixtures.document()
        var theirs = try #require(BulkFixtures.markers(1, in: source, random: &random, pages: 0...0).first)
        theirs.id = mine.id
        var repeated = try #require(BulkFixtures.markers(1, in: source, random: &random, pages: 3...3).first)
        repeated.id = mine.id
        try MarkerCodec.apply(theirs, to: source, replacing: false)
        try MarkerCodec.apply(repeated, to: source, replacing: false)

        try PDFPageOrganizer.insert(source, into: document, at: 4)
        let markers = MarkerCodec.markers(in: document)
        #expect(document.pageCount == 8)
        #expect(markers.count == 2)
        #expect(markers.first { $0.id == mine.id } == mine, "the existing marker keeps its identifier and place")
        let imported = try #require(markers.first { $0.id != mine.id })
        var expectedImport = theirs
        expectedImport.id = imported.id
        expectedImport.regions = theirs.regions.map { PageRegion(pageIndex: $0.pageIndex + 4, bounds: $0.bounds) }
        #expect(imported == expectedImport, "only the first anchor is imported, under a new identifier")
        #expect(BulkFixtures.audit(document).isEmpty, "\(BulkFixtures.audit(document))")
        // The source is untouched.
        #expect(MarkerCodec.markers(in: source).map(\.id) == [mine.id])
        #expect(Fixtures.annotations(in: source).filter { BulkFixtures.owner(of: $0) == mine.id }.count == theirs.regions.count + repeated.regions.count + 6)
    }

    @Test("An unreadable leftover annotation sharing an incoming marker's identifier is cleared when that marker is inserted")
    func leftoverSharingIncomingIdentifier() throws {
        let document = try Fixtures.document()
        let source = try Fixtures.document()
        let incoming = try Fixtures.marker(in: source)
        try MarkerCodec.apply(incoming, to: source)
        // An owned annotation with the incoming identifier but no readable metadata, as a
        // crash or another tool might leave behind.
        let leftover = PDFAnnotation(bounds: CGRect(x: 30, y: 30, width: 40, height: 12), forType: .highlight, withProperties: nil)
        leftover.setValue(MarkerCodec.ownerValue, forAnnotationKey: MarkerCodec.ownerKey)
        leftover.setValue(incoming.id.uuidString, forAnnotationKey: MarkerCodec.identifierKey)
        try #require(document.page(at: 2)).addAnnotation(leftover)
        #expect(MarkerCodec.markers(in: document).isEmpty)

        try PDFPageOrganizer.insert(source, into: document, at: 0)
        // Inserted at the front, so the incoming marker keeps its page numbers.
        #expect(MarkerCodec.markers(in: document) == [incoming])
        #expect(!Fixtures.annotations(in: document).contains { $0 === leftover })
        #expect(BulkFixtures.audit(document).isEmpty, "\(BulkFixtures.audit(document))")
    }

    @Test("Inserting a document into itself duplicates its markers under new identifiers and keeps the originals in place",
          arguments: [0, 1, 4])
    func insertIntoItself(at insertion: Int) throws {
        var random = BulkRandom(seed: 23 + UInt64(insertion))
        let document = try Fixtures.document()
        let markers = BulkFixtures.markers(6, in: document, random: &random, regions: 1...3)
        for marker in markers { try MarkerCodec.apply(marker, to: document) }
        try PDFPageOrganizer.insert(document, into: document, at: insertion)
        #expect(document.pageCount == 8)
        let all = MarkerCodec.markers(in: document)
        #expect(all.count == 12)
        #expect(Set(all.map(\.id)).count == 12)
        let originals = BulkFixtures.byID(all.filter { marker in markers.contains { $0.id == marker.id } })
        let shifted = markers.map { marker -> PDFMarker in
            var marker = marker
            marker.regions = marker.regions.map { PageRegion(pageIndex: $0.pageIndex < insertion ? $0.pageIndex : $0.pageIndex + 4, bounds: $0.bounds) }
                .enumerated().sorted { ($0.element.pageIndex, $0.offset) < ($1.element.pageIndex, $1.offset) }.map(\.element)
            return marker
        }
        #expect(originals == BulkFixtures.byID(shifted))
        let copies = all.filter { marker in !markers.contains { $0.id == marker.id } }
        let expectedCopies = markers.map { marker -> PDFMarker in
            var marker = marker
            marker.regions = marker.regions.map { PageRegion(pageIndex: $0.pageIndex + insertion, bounds: $0.bounds) }
                .enumerated().sorted { ($0.element.pageIndex, $0.offset) < ($1.element.pageIndex, $1.offset) }.map(\.element)
            return marker
        }
        #expect(copies.map(BulkFixtures.content).sorted() == expectedCopies.map(BulkFixtures.content).sorted())
        #expect(BulkFixtures.audit(document).isEmpty, "\(BulkFixtures.audit(document))")
        let reopened = try Fixtures.reopen(document)
        MarkerCodec.refreshAppearance(in: reopened)
        #expect(BulkFixtures.byID(MarkerCodec.markers(in: reopened)) == BulkFixtures.byID(all))
        #expect(BulkFixtures.audit(reopened).isEmpty, "\(BulkFixtures.audit(reopened))")
    }

    // MARK: - Split

    @Test("Split parts carry exactly their pages' share of every marker and match extracting the same pages", arguments: [1, 2, 3, 4, 7])
    func split(every count: Int) throws {
        let (document, markers) = try BulkFixtures.document(markers: 12, seed: 31, regions: 1...3)
        let parts = try PDFPageOrganizer.split(document, every: count)
        #expect(parts.map(\.pageCount) == stride(from: 0, to: 4, by: count).map { min(count, 4 - $0) })
        for (part, start) in zip(parts, stride(from: 0, to: 4, by: count)) {
            let pages = start..<min(4, start + count)
            let mapping = Dictionary(uniqueKeysWithValues: pages.map { ($0, $0 - start) })
            // A part of every page is the document's bytes as they are: nothing is renumbered.
            let expected = pages.count == 4 ? markers : remapped(markers, mapping)
            #expect(BulkFixtures.byID(MarkerCodec.markers(in: part)) == BulkFixtures.byID(expected), "part from page \(start)")
            // Opened as a document, as the app would (a part of every page has only been through
            // saving, which drops in-memory popups until the refresh on load restores them).
            MarkerCodec.refreshAppearance(in: part)
            #expect(BulkFixtures.audit(part).isEmpty, "\(BulkFixtures.audit(part))")
            #expect((0..<part.pageCount).map { part.page(at: $0)?.string } == pages.map { document.page(at: $0)?.string })
            let extracted = try PDFPageOrganizer.extract(document, pages: IndexSet(integersIn: pages))
            #expect(BulkFixtures.byID(MarkerCodec.markers(in: extracted)) == BulkFixtures.byID(MarkerCodec.markers(in: part)))
        }
        // Parts are independent documents, and the source is unchanged.
        if parts.count > 1, parts[0].pageCount > 1 {
            try PDFPageOrganizer.delete(parts[0], pages: IndexSet(integer: 0))
            #expect(parts[1].pageCount == min(count, 4 - count))
        }
        #expect(BulkFixtures.byID(MarkerCodec.markers(in: document)) == BulkFixtures.byID(markers))
        #expect(document.pageCount == 4)
    }

    @Test("Split refuses a zero count, an empty document, and a source that doesn't allow copying, before any work")
    func splitRefusals() throws {
        #expect(throws: PDFPageOperationError.invalidOrder) { try PDFPageOrganizer.split(try Fixtures.document(), every: 0) }
        #expect(throws: PDFPageOperationError.invalidOrder) { try PDFPageOrganizer.split(try Fixtures.document(), every: -3) }
        #expect(throws: AnnotateError.self) { try PDFPageOrganizer.split(PDFDocument(), every: 1) }
        let data = try #require(SamplePDF.make().dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "owner", PDFDocumentWriteOption.userPasswordOption: "reader", PDFDocumentWriteOption.accessPermissionsOption: 0]))
        let restricted = try #require(PDFDocument(data: data))
        #expect(throws: PDFPageOperationError.sourceRestricted) { try PDFPageOrganizer.split(restricted, every: 1) }
        #expect(restricted.unlock(withPassword: "reader") && !restricted.allowsCopying)
        #expect(throws: PDFPageOperationError.sourceRestricted) { try PDFPageOrganizer.split(restricted, every: 2) }
    }

    // MARK: - Non-functional: page operations are linear in the markers

    /// Reads of Annotate's marker keys during one operation, per marker annotation in the
    /// document. The old per-marker scans read every annotation once per marker.
    private func readsPerAnnotation(markers count: Int, _ operation: (PDFDocument) throws -> Void) throws -> Double {
        try CountingMarkerAnnotation.installed {
            let (document, _) = try BulkFixtures.document(markers: count, seed: 41, regions: 1...1)
            let counted = Fixtures.annotations(in: document).filter { $0 is CountingMarkerAnnotation }.count
            #expect(counted == count * 3)
            CountingMarkerAnnotation.keyReads = 0
            try operation(document)
            #expect(MarkerCodec.markers(in: document).count == count)
            return Double(CountingMarkerAnnotation.keyReads) / Double(counted)
        }
    }

    @Test("Reorder, move, insert and delete read each marker annotation a fixed number of times, however many markers there are")
    func pageOperationReadsAreLinear() throws {
        let operations: [(String, (PDFDocument) throws -> Void)] = [
            ("reorder", { try PDFPageOrganizer.reorder($0, order: [3, 2, 1, 0]) }),
            ("move", { try PDFPageOrganizer.move($0, page: 0, to: 3) }),
            ("insert blank", { try PDFPageOrganizer.insertBlank(into: $0, at: 2) }),
            ("delete blank", { try PDFPageOrganizer.insertBlank(into: $0, at: 0); try PDFPageOrganizer.delete($0, pages: [0]) }),
            ("rotate", { try PDFPageOrganizer.rotate($0, pages: [0, 1]) })
        ]
        for (name, operation) in operations {
            let small = try readsPerAnnotation(markers: 40, operation), large = try readsPerAnnotation(markers: 320, operation)
            print("\(name): \(small) reads per marker annotation at 40 markers, \(large) at 320")
            // A quadratic scan reads each annotation once per marker: 40 and 320 times.
            #expect(large < 16, "\(name): \(large) reads per annotation at 320 markers")
            #expect(large < small * 1.5 + 1, "\(name): reads per annotation grew from \(small) to \(large)")
        }
    }

    /// The fastest of three runs, in seconds: the least disturbed by other work.
    private func fastest(_ runs: Int = 3, _ body: () throws -> Void) rethrows -> Double {
        var best = Double.infinity
        for _ in 0..<runs {
            let start = ContinuousClock.now
            try body()
            let elapsed = start.duration(to: .now)
            best = min(best, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        }
        return best
    }

    @Test("Moving a page with four times the markers takes about four times as long, not sixteen")
    func pageOperationTimeScales() throws {
        func time(_ count: Int) throws -> Double {
            let (document, _) = try BulkFixtures.document(markers: count, seed: 42, regions: 1...1)
            let data = try #require(document.dataRepresentation())
            return try fastest {
                let working = try #require(PDFDocument(data: data))
                try PDFPageOrganizer.move(working, page: 0, to: 3)
            }
        }
        _ = try time(50) // warm up
        let small = try time(250), large = try time(1_000)
        print("Move page: \(small) s at 250 markers, \(large) s at 1,000 (ratio \(large / small))")
        // Linear is about 4; the old quadratic restore was well over 10.
        #expect(large / small < 9, "ratio \(large / small)")
        #expect(large < 5, "\(large) s for 1,000 markers")
    }
}
