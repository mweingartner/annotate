import AnnotateCore
import AppKit
import CoreText
import PDFKit
import Testing
@testable import AnnotateApp

/// Editing a paragraph so it gains or loses lines moves the content below it by exactly
/// that height, as far as the first wide gap, and moves annotations with it.
@Suite("Minimal reflow while editing", .serialized)
@MainActor
struct ReflowEditingTests {
    private let first = "The paragraph being edited runs over two lines at this width, so adding words gives it a third."
    private let second = "The next paragraph sits right below and must move with it, keeping the same gap as before."
    /// Enough words to need a whole extra line at this width.
    private let added = " These added words are long enough to need a whole extra line of their own, and then some more."
    private let third = "This paragraph follows a wide gap that absorbs the change, so it stays exactly where it was."

    /// Paragraphs set by CoreText, one per frame, with a wide gap before the third.
    private func document() throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let font = try #require(NSFont(name: "Helvetica", size: 12))
        let style = NSMutableParagraphStyle(); style.lineSpacing = 3
        var top: CGFloat = 720
        for (index, paragraph) in [first, second, third].enumerated() {
            let text = NSAttributedString(string: paragraph, attributes: [.font: font, .paragraphStyle: style, .ligature: 0])
            let setter = CTFramesetterCreateWithAttributedString(text)
            let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: 360, height: 1000), nil)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(x: 72, y: top - size.height, width: 360, height: size.height), transform: nil), nil), context)
            top -= size.height + (index == 1 ? 90 : 10)
        }
        context.endPDFPage(); context.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }

    @MainActor private struct Harness {
        let owner: AnnotateDocument
        let view: SelectionPDFView
        let window: NSWindow
        var model: ReaderModel { owner.model }
        func close() { owner.model.discardPendingLiveText(); window.close() }
    }

    private func open(_ pdf: PDFDocument, editing: Bool = true) -> Harness {
        _ = NSApplication.shared
        let owner = AnnotateDocument()
        owner.model.load(pdf, owner: owner)
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.document = pdf; view.model = owner.model; owner.model.pdfView = view
        view.layoutDocumentView()
        if editing { owner.model.showTool(.edit) }
        return Harness(owner: owner, view: view, window: window)
    }

    private func bounds(_ phrase: String, in document: PDFDocument?) throws -> CGRect {
        let document = try #require(document)
        let page = try #require(document.page(at: 0))
        return try #require(document.findString(phrase, withOptions: []).first).bounds(for: page)
    }

    private func edit(_ harness: Harness, at phrase: String) throws -> LiveTextEdit {
        let pdf = try #require(harness.model.pdfDocument)
        let page = try #require(pdf.page(at: 0))
        let hit = try bounds(phrase, in: pdf)
        harness.view.editParagraph(at: harness.view.convert(harness.view.convert(CGPoint(x: hit.midX, y: hit.midY), from: page), to: nil))
        return try #require(harness.model.liveEdit)
    }

    @Test("A paragraph that gains a line pushes the next one down by that line; the one past the wide gap stays")
    func growsAndPushes() throws {
        let harness = open(try document())
        defer { harness.close() }
        let secondBefore = try bounds("The next paragraph", in: harness.model.pdfDocument)
        let thirdBefore = try bounds("This paragraph follows", in: harness.model.pdfDocument)
        let session = try edit(harness, at: "being edited")
        let before = session.appliedBounds
        session.text += added
        #expect(!session.nativeUpdateFailed, "\(session.nativeFailureMessage ?? "")")
        let grew = session.appliedBounds.height - before.height
        #expect(grew > 5, "the block should have gained a line")
        let secondAfter = try bounds("The next paragraph", in: harness.model.pdfDocument)
        let thirdAfter = try bounds("This paragraph follows", in: harness.model.pdfDocument)
        #expect(abs((secondBefore.minY - secondAfter.minY) - grew) < 0.05, "moved \(secondBefore.minY - secondAfter.minY), grew \(grew)")
        #expect(abs(secondAfter.minX - secondBefore.minX) < 0.05)
        #expect(abs(thirdAfter.minY - thirdBefore.minY) < 0.05, "past the wide gap nothing moves")
        // The gap between the edited paragraph and the next is what it was.
        #expect(secondAfter.maxY < session.appliedBounds.minY + 0.5)
    }

    @Test("A change that keeps the line count moves nothing below it")
    func sameLinesMoveNothing() throws {
        let harness = open(try document())
        defer { harness.close() }
        let secondBefore = try bounds("The next paragraph", in: harness.model.pdfDocument)
        let session = try edit(harness, at: "being edited")
        let before = session.appliedBounds
        session.text = session.text.replacingOccurrences(of: "adding words", with: "adding more")
        #expect(!session.nativeUpdateFailed)
        #expect(session.appliedBounds == before)
        let secondAfter = try bounds("The next paragraph", in: harness.model.pdfDocument)
        #expect(abs(secondAfter.minY - secondBefore.minY) < 0.01)
    }

    @Test("Removing the added words pulls the next paragraph back to where it was")
    func shrinksAndPulls() throws {
        let harness = open(try document())
        defer { harness.close() }
        let secondBefore = try bounds("The next paragraph", in: harness.model.pdfDocument)
        let session = try edit(harness, at: "being edited")
        let original = session.text
        session.text += added
        session.text = original
        #expect(!session.nativeUpdateFailed)
        let secondAfter = try bounds("The next paragraph", in: harness.model.pdfDocument)
        #expect(abs(secondAfter.minY - secondBefore.minY) < 0.05)
    }

    @Test("A marker on the moved paragraph moves with it, in its annotations and its saved regions")
    func markerMoves() throws {
        let harness = open(try document(), editing: false)
        defer { harness.close() }
        let pdf = try #require(harness.model.pdfDocument)
        let selection = try #require(pdf.findString("next paragraph", withOptions: []).first)
        harness.model.pdfView?.setCurrentSelection(selection, animate: false)
        harness.model.captureSelection(selection)
        harness.model.saveDraft()
        let marker = try #require(harness.model.markers.first)
        let regionBefore = try #require(marker.regions.first).bounds
        harness.view.clearSelection()
        harness.model.showTool(.edit)
        let session = try edit(harness, at: "being edited")
        let before = session.appliedBounds
        session.text += added
        let grew = session.appliedBounds.height - before.height
        let moved = try #require(harness.model.markers.first { $0.id == marker.id })
        let regionAfter = try #require(moved.regions.first).bounds
        #expect(abs((regionBefore.minY - regionAfter.minY) - grew) < 0.05, "\(regionBefore) → \(regionAfter)")
        let highlight = try #require(harness.model.pdfDocument?.page(at: 0)?.annotations.first {
            $0.type == "Highlight" && $0.value(forAnnotationKey: MarkerCodec.identifierKey) as? String == marker.id.uuidString
        })
        #expect(abs(highlight.bounds.minY - regionAfter.minY) < 0.05)
    }

    @Test("A block placed by hand keeps its geometry and never moves the content below")
    func manualGeometryStopsReflow() throws {
        let harness = open(try document())
        defer { harness.close() }
        let secondBefore = try bounds("The next paragraph", in: harness.model.pdfDocument)
        let session = try edit(harness, at: "being edited")
        session.bounds = session.appliedBounds
        #expect(session.reflowGap == nil)
        session.text += added
        let secondAfter = try bounds("The next paragraph", in: harness.model.pdfDocument)
        #expect(abs(secondAfter.minY - secondBefore.minY) < 0.05)
    }

    /// The edited paragraph, then paragraphs 10 pt apart down to the page's foot: no gap
    /// anywhere absorbs a new line.
    private func crowdedDocument() throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let font = try #require(NSFont(name: "Helvetica", size: 12))
        let style = NSMutableParagraphStyle(); style.lineSpacing = 3
        var top: CGFloat = 720, index = 0
        while top > 70 {
            let text = NSAttributedString(string: index == 0 ? first : "Filler paragraph \(index) " + second,
                                          attributes: [.font: font, .paragraphStyle: style, .ligature: 0])
            let setter = CTFramesetterCreateWithAttributedString(text)
            let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: 360, height: 1000), nil)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(x: 72, y: top - size.height, width: 360, height: size.height), transform: nil), nil), context)
            top -= size.height + 10; index += 1
        }
        context.endPDFPage(); context.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }

    @Test("A shorter paragraph pulls the next one up; growing it again pushes it back down past where it began")
    func shrinksThenGrows() throws {
        let harness = open(try document())
        defer { harness.close() }
        let secondBefore = try bounds("The next paragraph", in: harness.model.pdfDocument)
        let thirdBefore = try bounds("This paragraph follows", in: harness.model.pdfDocument)
        let session = try edit(harness, at: "being edited")
        let original = session.appliedBounds
        session.text = "Now just one short line."
        #expect(!session.nativeUpdateFailed, "\(session.nativeFailureMessage ?? "")")
        let lost = original.height - session.appliedBounds.height
        #expect(lost > 5, "the block lost a line")
        #expect(abs(session.appliedBounds.maxY - original.maxY) < 0.01, "the top stays put")
        let pulled = try bounds("The next paragraph", in: harness.model.pdfDocument)
        #expect(abs((pulled.minY - secondBefore.minY) - lost) < 0.05, "pulled up \(pulled.minY - secondBefore.minY), lost \(lost)")
        session.text = first + added
        #expect(!session.nativeUpdateFailed, "\(session.nativeFailureMessage ?? "")")
        let grew = session.appliedBounds.height - original.height
        #expect(grew > 5)
        let pushed = try bounds("The next paragraph", in: harness.model.pdfDocument)
        #expect(abs((secondBefore.minY - pushed.minY) - grew) < 0.05, "pushed down \(secondBefore.minY - pushed.minY), grew \(grew)")
        // Each keystroke measures from the original page, so moves never accumulate.
        for _ in 0..<3 { session.text += " x"; session.text.removeLast(2) }
        let settled = try bounds("The next paragraph", in: harness.model.pdfDocument)
        #expect(abs(settled.minY - pushed.minY) < 0.05)
        #expect(abs(try bounds("This paragraph follows", in: harness.model.pdfDocument).minY - thirdBefore.minY) < 0.05)
    }

    @Test("Successive edits: a paragraph grown in one edit can be shrunk back in the next, and what follows returns")
    func successiveSessions() throws {
        let harness = open(try document())
        defer { harness.close() }
        let secondBefore = try bounds("The next paragraph", in: harness.model.pdfDocument)
        let session = try edit(harness, at: "being edited")
        let original = session.text
        session.text += added
        #expect(!session.nativeUpdateFailed)
        #expect(harness.model.finishLiveText())
        let moved = try bounds("The next paragraph", in: harness.model.pdfDocument)
        #expect(secondBefore.minY - moved.minY > 5)
        // A new edit of the same paragraph, now three lines drawn from the earlier edit.
        let again = try edit(harness, at: "being edited")
        #expect(again.reflowGap != nil, "reflow is on for the edited paragraph too")
        again.text = original
        #expect(!again.nativeUpdateFailed, "\(again.nativeFailureMessage ?? "")")
        #expect(again.reflowRefusal == nil, "\(again.reflowRefusal ?? "")")
        let back = try bounds("The next paragraph", in: harness.model.pdfDocument)
        #expect(abs(back.minY - secondBefore.minY) < 0.5, "\(secondBefore) → \(moved) → \(back)")
    }

    @Test("Undo after a reflowing edit puts the paragraph and everything it moved back")
    func undoRestores() throws {
        let harness = open(try document())
        defer { harness.close() }
        let undo = try #require(harness.owner.undoManager)
        undo.groupsByEvent = false
        let secondBefore = try bounds("The next paragraph", in: harness.model.pdfDocument)
        let session = try edit(harness, at: "being edited")
        undo.beginUndoGrouping()
        session.text += added
        undo.endUndoGrouping()
        #expect(!session.nativeUpdateFailed)
        #expect(secondBefore.minY - (try bounds("The next paragraph", in: harness.model.pdfDocument)).minY > 5)
        #expect(undo.canUndo)
        undo.undo()
        #expect(harness.model.liveEdit == nil)
        #expect(abs(try bounds("The next paragraph", in: harness.model.pdfDocument).minY - secondBefore.minY) < 0.05)
        #expect(harness.model.pdfDocument?.findString("whole extra line", withOptions: []).isEmpty == true)
    }

    @Test("Links, notes and markup on moved content move with it; those on content that stays don't")
    func annotationsFollowTheirText() throws {
        let harness = open(try document())
        defer { harness.close() }
        let pdf = try #require(harness.model.pdfDocument)
        let page = try #require(pdf.page(at: 0))
        let secondBefore = try bounds("The next paragraph", in: pdf), thirdBefore = try bounds("This paragraph follows", in: pdf)
        let square = PDFAnnotation(bounds: secondBefore.insetBy(dx: -2, dy: -2), forType: .square, withProperties: nil)
        let link = PDFAnnotation(bounds: thirdBefore, forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com")
        // A note in the margin beside the moved paragraph is not on moved content.
        let margin = PDFAnnotation(bounds: CGRect(x: 520, y: secondBefore.minY, width: 20, height: 20), forType: .text, withProperties: nil)
        for annotation in [square, link, margin] { page.addAnnotation(annotation) }
        let session = try edit(harness, at: "being edited")
        let before = session.appliedBounds
        session.text += added
        #expect(!session.nativeUpdateFailed)
        let grew = session.appliedBounds.height - before.height
        let annotations = try #require(harness.model.pdfDocument?.page(at: 0)?.annotations)
        let movedSquare = try #require(annotations.first { $0.type == "Square" })
        let movedLink = try #require(annotations.first { $0.type == "Link" })
        let note = try #require(annotations.first { $0.type == "Text" })
        #expect(abs((square.bounds.minY - movedSquare.bounds.minY) - grew) < 0.05, "\(square.bounds) → \(movedSquare.bounds)")
        #expect(abs(movedSquare.bounds.minX - square.bounds.minX) < 0.01 && abs(movedSquare.bounds.height - square.bounds.height) < 0.01)
        #expect(abs(movedLink.bounds.minY - link.bounds.minY) < 0.01, "past the wide gap nothing moves")
        // PDFKit sizes a note's icon to 24 pt from its top-left corner when the page is saved.
        #expect(abs(note.bounds.maxY - margin.bounds.maxY) < 0.01, "outside the column nothing moves: \(margin.bounds) → \(note.bounds)")
        // Moving them again on the next keystroke measures from the original, not the moved position.
        session.text += " More."
        let later = try #require(harness.model.pdfDocument?.page(at: 0)?.annotations.first { $0.type == "Square" })
        let grewLater = session.appliedBounds.height - before.height
        #expect(abs((square.bounds.minY - later.bounds.minY) - grewLater) < 0.05)
    }

    @Test("When the content below can't make room, the edit says why and the page is left as it was")
    func refusalExplainsAndLeavesThePage() throws {
        let harness = open(try crowdedDocument())
        defer { harness.close() }
        let secondBefore = try bounds("Filler paragraph 1 ", in: harness.model.pdfDocument)
        let session = try edit(harness, at: "being edited")
        let original = session.text, block = session.appliedBounds
        session.text += added
        #expect(session.nativeUpdateFailed)
        #expect(session.reflowRefusal == "The text needs more room, and the content below it can't move further down the page.")
        #expect(session.nativeFailureMessage == session.reflowRefusal, "the reason is what the inspector shows")
        #expect(harness.model.errorMessage == nil, "text that doesn't fit shows on the block, not in a banner")
        #expect(session.appliedBounds == block)
        #expect(abs(try bounds("Filler paragraph 1 ", in: harness.model.pdfDocument).minY - secondBefore.minY) < 0.01)
        // Taking the words out again clears the reason.
        session.text = original
        #expect(!session.nativeUpdateFailed)
        #expect(session.reflowRefusal == nil)
        #expect(session.nativeFailureMessage == nil)
    }

    // MARK: - The edit's own geometry

    private let pageBox = CGRect(x: 0, y: 0, width: 612, height: 792)

    private func session(_ text: String, bounds: CGRect) throws -> LiveTextEdit {
        let font = try #require(NSFont(name: "Helvetica", size: 12))
        return LiveTextEdit(identifier: "reflow", pageIndex: 0, text: text, font: font, color: .black, bounds: bounds,
                            pageBounds: pageBox, isExistingContent: true)
    }

    @Test("Reflow needs a positive, finite line gap", arguments: [0.0, -3, .nan, .infinity])
    func reflowNeedsAGap(gap: Double) throws {
        let edit = try session("Short text", bounds: CGRect(x: 72, y: 600, width: 300, height: 40))
        edit.enableReflow(minimumGap: gap)
        #expect(edit.reflowGap == nil)
        #expect(edit.reflowedBounds() == nil)
    }

    @Test("The reflowed block keeps its top, left edge and width, and changes height by exactly the text's change")
    func reflowedBoundsTrackTheText() throws {
        let bounds = CGRect(x: 72, y: 600, width: 300, height: 40)
        let edit = try session("Short text", bounds: bounds)
        edit.enableReflow(minimumGap: 14)
        #expect(edit.reflowGap == 14)
        #expect(edit.reflowedBounds() == bounds, "the same text gives the same block")
        let base = try #require(edit.heightFittedBounds()).height
        edit.text = "Short text, and now enough further words to wrap onto a second line and then a third line at this width."
        let fitted = try #require(edit.heightFittedBounds())
        #expect(fitted.height > base)
        let grown = try #require(edit.reflowedBounds())
        #expect(grown.maxY == bounds.maxY && grown.minX == bounds.minX && grown.width == bounds.width)
        #expect(abs(grown.height - (bounds.height + fitted.height - base)) < 1e-9)
        // Settling at the new size announces nothing and keeps reflow on.
        var changes = 0
        edit.changed = { changes += 1 }
        edit.settleBounds(grown)
        #expect(changes == 0)
        #expect(edit.appliedBounds == grown && edit.bounds == grown)
        #expect(edit.reflowGap == 14)
        #expect(edit.reflowedBounds() == grown, "still measured from the original block")
        edit.settleBounds(grown)
        #expect(changes == 0)
    }

    @Test("A reflowed block that would leave the page is refused, even when the text alone would fit")
    func reflowedBoundsStayOnThePage() throws {
        // A tall block around one line: the block grows by the text's change from its own height.
        let edit = try session("One line", bounds: CGRect(x: 72, y: 10, width: 300, height: 40))
        edit.enableReflow(minimumGap: 14)
        edit.text = "One line, then enough further words to wrap onto a second line and a third line at this width."
        #expect(edit.heightFittedBounds() != nil, "the text itself still fits above the page's foot")
        #expect(edit.reflowedBounds() == nil)
    }

    @Test("Moving or resizing the block by hand turns reflow off", arguments: 0..<3)
    func handGeometryTurnsReflowOff(change: Int) throws {
        let edit = try session("Short text", bounds: CGRect(x: 72, y: 600, width: 300, height: 40))
        edit.enableReflow(minimumGap: 14)
        switch change {
        case 0: edit.x = 80
        case 1: edit.height = 60
        default: edit.fitHeightToText()
        }
        #expect(edit.reflowGap == nil)
    }
}
