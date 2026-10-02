import AnnotateCore
import AppKit
import PDFKit
import Testing
@testable import AnnotateApp

/// A page operation reuses the bytes it worked from as its undo snapshot instead of
/// serializing the document a second time. Undo must still give back exactly the document
/// as it was before the operation, and redo exactly the one after it.
@Suite("Page operation undo restores the exact document", .serialized)
@MainActor
struct PageOperationUndoTests {
    /// Everything a reader could see change: pages in order with their text, size and
    /// rotation, and every annotation with its owner, contents, bounds and color.
    private struct State: Equatable {
        let pages: [String]
        let annotations: [[String]]
        let markers: [PDFMarker]
    }

    private func state(_ model: ReaderModel) throws -> State {
        try state(of: try #require(model.pdfDocument), markers: model.markers)
    }

    /// The document as undo should bring it back: its bytes reopened, as the app loads them.
    /// (Undo restores a saved snapshot, before and after this change; a reopened popup reports
    /// its comment's contents and colors come back rounded, so the live document isn't the
    /// right comparison for annotations. Its markers and pages are, and are checked too.)
    private func reloaded(_ model: ReaderModel) throws -> State {
        let data = try #require(model.pdfDocument?.dataRepresentation())
        let pdf = try #require(PDFDocument(data: data))
        MarkerCodec.refreshAppearance(in: pdf)
        return try state(of: pdf, markers: MarkerCodec.markers(in: pdf))
    }

    private func state(of pdf: PDFDocument, markers: [PDFMarker]) throws -> State {
        let pages = (0..<pdf.pageCount).map { index -> String in
            let page = pdf.page(at: index)
            return "\(page?.string ?? "") | \(page?.bounds(for: .mediaBox) ?? .null) | \(page?.rotation ?? -1)"
        }
        let annotations = (0..<pdf.pageCount).map { index in
            (pdf.page(at: index)?.annotations ?? []).map { annotation -> String in
                let owner = annotation.value(forAnnotationKey: MarkerCodec.identifierKey) as? String ?? "foreign"
                let rgb = annotation.color.usingColorSpace(.sRGB)
                let color = rgb.map { String(format: "%.3f %.3f %.3f", $0.redComponent, $0.greenComponent, $0.blueComponent) } ?? "-"
                let bounds = annotation.bounds
                return "\(annotation.type ?? "?") \(owner) \(annotation.contents ?? "") \(String(format: "%.2f %.2f %.2f %.2f", bounds.minX, bounds.minY, bounds.width, bounds.height)) \(color)"
            }.sorted()
        }
        return State(pages: pages, annotations: annotations, markers: markers)
    }

    /// What differs between two states, line by line, so a failure says what changed.
    private func difference(_ got: State, _ want: State) -> String {
        var lines: [String] = []
        if got.pages != want.pages { lines.append("pages: got \(got.pages) want \(want.pages)") }
        for (index, pair) in zip(got.annotations, want.annotations).enumerated() where pair.0 != pair.1 {
            let a = Set(pair.0), b = Set(pair.1)
            lines.append("page \(index) got only: \(a.subtracting(b).sorted()) want only: \(b.subtracting(a).sorted())")
        }
        if got.annotations.count != want.annotations.count { lines.append("page count \(got.annotations.count) vs \(want.annotations.count)") }
        if got.markers != want.markers { lines.append("markers: got \(got.markers.map { "\($0.note)@\($0.regions.map(\.pageIndex))" }) want \(want.markers.map { "\($0.note)@\($0.regions.map(\.pageIndex))" })") }
        return lines.joined(separator: "\n")
    }

    private func check(_ model: ReaderModel, equals want: State, _ context: String) throws {
        let got = try state(model)
        #expect(got == want, "\(context): \(difference(got, want))")
    }

    /// The tour with three markers (one spanning pages) and another reader's comment.
    private func loaded() throws -> (AnnotateDocument, UndoManager) {
        _ = NSApplication.shared
        let pdf = SamplePDF.make()
        var random = BulkRandomApp(seed: 3)
        for index in 0..<3 {
            var regions = [PageRegion(pageIndex: index, bounds: CGRect(x: 72 + Double(random.next() % 100), y: 300, width: 120, height: 14))]
            if index == 1 { regions.append(PageRegion(pageIndex: 3, bounds: CGRect(x: 90, y: 500, width: 80, height: 14))) }
            try MarkerCodec.apply(PDFMarker(categories: [.important, .note], color: MarkerColor.palette[index], icon: "star.fill",
                                            quote: "Quote \(index)", note: "Note \(index)", question: "", regions: regions,
                                            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))), to: pdf)
        }
        let comment = PDFAnnotation(bounds: CGRect(x: 400, y: 120, width: 24, height: 24), forType: .text, withProperties: nil)
        comment.contents = "Another reader's note"
        try #require(pdf.page(at: 2)).addAnnotation(comment)
        // Through saving once, as an opened file would be.
        let saved = try #require(pdf.dataRepresentation())
        let reopened = try #require(PDFDocument(data: saved))
        let owner = AnnotateDocument()
        owner.model.load(reopened, owner: owner)
        let undo = try #require(owner.undoManager)
        undo.removeAllActions()
        undo.groupsByEvent = false
        return (owner, undo)
    }

    @Test("Undo and redo of each page operation give back the exact documents before and after it",
          arguments: ["move", "move back", "delete", "insert blank", "rotate"])
    func undoRedo(_ operation: String) throws {
        let (owner, undo) = try loaded()
        let model = owner.model
        #expect(model.markers.count == 3)
        let live = try state(model), before = try reloaded(model)
        #expect(live.markers == before.markers && live.pages == before.pages)
        undo.beginUndoGrouping()
        switch operation {
        case "move": model.movePage(0, to: 3)
        case "move back": model.movePage(3, to: 1)
        case "delete": model.deletePages(IndexSet([0, 2]))
        case "insert blank": model.goToPage(2); model.insertBlankPage()
        default: model.rotatePages(IndexSet([1, 3]), clockwise: true)
        }
        undo.endUndoGrouping()
        #expect(model.errorMessage == nil)
        let after = try reloaded(model)
        #expect(after != before)
        #expect(undo.canUndo)
        undo.undo()
        try check(model, equals: before, "\(operation): undo")
        #expect(model.markers == live.markers, "\(operation): undo gives back the exact markers")
        undo.redo()
        try check(model, equals: after, "\(operation): redo")
        undo.undo()
        try check(model, equals: before, "\(operation): undo again")
        #expect(model.markers == live.markers)
        owner.close()
    }

    @Test("Two page operations undo one at a time, each back to the document it started from")
    func twoOperations() throws {
        let (owner, undo) = try loaded()
        let model = owner.model
        let first = try reloaded(model)
        undo.beginUndoGrouping(); model.movePage(0, to: 2); undo.endUndoGrouping()
        let second = try reloaded(model)
        undo.beginUndoGrouping(); model.deletePages(IndexSet(integer: 3)); undo.endUndoGrouping()
        let third = try reloaded(model)
        #expect(Set([first, second, third].map { "\($0.pages)" }).count == 3)
        undo.undo()
        try check(model, equals: second, "second")
        undo.undo()
        try check(model, equals: first, "first")
        undo.redo(); undo.redo()
        try check(model, equals: third, "third")
        owner.close()
    }

    @Test("A page operation that fails registers no undo and keeps the document")
    func failedRegistersNothing() throws {
        let (owner, undo) = try loaded()
        let model = owner.model
        let before = try state(model), document = model.pdfDocument
        undo.beginUndoGrouping()
        model.deletePages(IndexSet(integersIn: 0..<4))
        model.movePage(9, to: 0)
        undo.endUndoGrouping()
        #expect(model.errorMessage != nil)
        #expect(model.pdfDocument === document)
        try check(model, equals: before, "before")
        // The empty group may be registered, but undoing it changes nothing.
        if undo.canUndo { undo.undo() }
        try check(model, equals: before, "before")
        owner.close()
    }
}

/// SplitMix64 for the app tests' fixtures.
struct BulkRandomApp: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
