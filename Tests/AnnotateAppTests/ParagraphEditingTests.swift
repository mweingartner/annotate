import AnnotateCore
import AppKit
import CoreText
import PDFKit
import Testing
@testable import AnnotateApp

@Suite("Editing a paragraph in place", .serialized)
@MainActor
struct ParagraphEditingTests {
    private let paragraph = "Some ideas deserve more than a bookmark. Annotate lets you attach meaning to an exact passage: something important, a thought to revisit, a question to investigate, or a note in your own words."

    @Test("A point on a wrapped line finds its whole paragraph and nothing else")
    func findsParagraph() throws {
        let pdf = SamplePDF.make()
        let page = try #require(pdf.page(at: 0))
        let line = try #require(pdf.findString("an exact", withOptions: []).first)
        let point = CGPoint(x: line.bounds(for: page).midX, y: line.bounds(for: page).midY)
        let found = try #require(ParagraphText.selection(at: point, on: page))
        let text = try #require(found.string)
        #expect(text.split(whereSeparator: \.isWhitespace) == paragraph.split(whereSeparator: \.isWhitespace))
        #expect(!text.contains("A better way to return"))
        #expect(!text.contains("Select a few words"))
    }

    @Test("A point between lines of text finds nothing")
    func missesWhitespace() throws {
        let pdf = SamplePDF.make()
        let page = try #require(pdf.page(at: 0))
        #expect(ParagraphText.selection(at: CGPoint(x: 2, y: 2), on: page) == nil)
    }

    @Test("Line geometry: same-size stacked lines continue; headings, gaps and columns break", arguments: [
        (CGRect(x: 72, y: 700, width: 400, height: 14), CGRect(x: 72, y: 683, width: 380, height: 14), true),
        (CGRect(x: 90, y: 700, width: 380, height: 14), CGRect(x: 72, y: 683, width: 400, height: 14), true),   // first-line indent
        (CGRect(x: 72, y: 700, width: 300, height: 24), CGRect(x: 72, y: 680, width: 400, height: 14), false),  // heading above body
        (CGRect(x: 72, y: 700, width: 400, height: 14), CGRect(x: 72, y: 650, width: 400, height: 14), false),  // paragraph gap
        (CGRect(x: 72, y: 700, width: 200, height: 14), CGRect(x: 320, y: 683, width: 200, height: 14), false), // next column
        (CGRect(x: 72, y: 700, width: 0, height: 14), CGRect(x: 72, y: 683, width: 400, height: 14), false),    // degenerate
    ])
    func continuation(upper: CGRect, lower: CGRect, expected: Bool) {
        #expect(ParagraphText.continues(upper, into: lower) == expected)
    }

    @Test("Joining lines keeps one space per line end and every character's attributes")
    func joinsLines() {
        let bold = NSFont.boldSystemFont(ofSize: 12)
        let text = NSMutableAttributedString(string: "First line \nsecond\r\nthird  and\n", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        text.addAttribute(.font, value: bold, range: NSRange(location: 12, length: 6))
        let joined = ParagraphText.joiningLines(text)
        #expect(joined.string == "First line second third  and ")
        #expect(joined.attribute(.font, at: 11, effectiveRange: nil) as? NSFont == bold)
    }

    @Test("Clicking a paragraph in Edit opens it as one reflowing block with the caret at the click")
    func clickEditsParagraph() throws {
        _ = NSApplication.shared
        let owner = AnnotateDocument()
        let pdf = SamplePDF.make()
        owner.model.load(pdf, owner: owner)
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { owner.model.discardPendingLiveText(); window.close() }
        view.document = pdf; view.model = owner.model; owner.model.pdfView = view
        view.layoutDocumentView()
        owner.model.showTool(.edit)
        let page = try #require(pdf.page(at: 0))
        let target = try #require(pdf.findString("Annotate lets", withOptions: []).first)
        let pagePoint = CGPoint(x: target.bounds(for: page).minX + 1, y: target.bounds(for: page).midY)
        let windowPoint = view.convert(view.convert(pagePoint, from: page), to: nil)
        view.editParagraph(at: windowPoint)
        let session = try #require(owner.model.liveEdit)
        #expect(!session.text.contains("\n"))
        #expect(session.text.split(whereSeparator: \.isWhitespace) == paragraph.split(whereSeparator: \.isWhitespace))
        let field = try #require(view.liveTextView)
        let caret = field.selectedRange()
        #expect(caret.length == 0)
        let annotateIndex = (session.text as NSString).range(of: "Annotate lets").location
        #expect(abs(caret.location - annotateIndex) <= 1)
        // Rewrapped lines keep the paragraph's original distance between lines.
        let found = try #require(ParagraphText.selection(at: pagePoint, on: page))
        let pitch = try #require(ParagraphText.linePitch(of: found, on: page))
        let font = try #require(session.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let style = try #require(session.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        // A fixed line height (MatchedLayout) reproduces the pitch; MatchedLayoutTests
        // checks the resulting baselines exactly.
        _ = font
        #expect(style.minimumLineHeight > 0 && style.minimumLineHeight == style.maximumLineHeight)
        #expect(abs(style.minimumLineHeight - pitch) < 2)
    }

    @Test("Line pitch keeps the first line in place and spaces the rest")
    func keepsPitch() throws {
        let font = NSFont.systemFont(ofSize: 12)
        let text = NSAttributedString(string: "One paragraph", attributes: [.font: font])
        let natural = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        let spaced = ParagraphText.keepingLinePitch(natural + 6, in: text)
        let style = try #require(spaced.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(abs(style.lineSpacing - 6) < 0.01)
        #expect(style.paragraphSpacingBefore == 0)
        // A pitch tighter than the font's own lines never produces negative spacing.
        let tight = ParagraphText.keepingLinePitch(natural - 4, in: text)
        #expect((tight.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing == 0)
        #expect(ParagraphText.keepingLinePitch(.nan, in: text) === text)
    }

    private func editingFixture(_ text: String) throws -> (AnnotateDocument, SelectionPDFView, NSWindow) {
        _ = NSApplication.shared
        let owner = AnnotateDocument()
        let pdf = try PDFConversion.textDocument(NSAttributedString(string: text,
            attributes: [.font: try #require(NSFont(name: "Helvetica", size: 16))]))
        owner.model.load(pdf, owner: owner)
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.document = pdf; view.model = owner.model; owner.model.pdfView = view
        view.layoutDocumentView()
        owner.model.showTool(.edit)
        return (owner, view, window)
    }

    @Test("Text that outgrows its block grows downward into empty page space and is applied")
    func growsIntoEmptySpace() throws {
        let (owner, view, window) = try editingFixture("A short closing line.")
        defer { owner.model.discardPendingLiveText(); window.close() }
        let pdf = try #require(owner.model.pdfDocument)
        view.setCurrentSelection(try #require(pdf.findString("A short closing line.", withOptions: []).first), animate: false)
        owner.model.beginLiveText(replacingSelection: true)
        let session = try #require(owner.model.liveEdit)
        let before = session.appliedBounds
        session.text = "A short closing line that has become a much longer sentence, long enough to need a second and a third line."
        #expect(!session.nativeUpdateFailed)
        #expect(session.appliedBounds.height > before.height)
        #expect(abs(session.appliedBounds.maxY - before.maxY) < 0.01, "The top edge stays put")
        #expect(owner.model.pdfDocument?.string?.contains("third") == true)
    }

    @Test("Text that outgrows its block never grows over the text below; the overflow is reported")
    func neverCoversText() throws {
        let (owner, view, window) = try editingFixture("Original sentence remains selectable.\nNeighboring paragraph stays intact.")
        defer { owner.model.discardPendingLiveText(); window.close() }
        let pdf = try #require(owner.model.pdfDocument)
        view.setCurrentSelection(try #require(pdf.findString("Original sentence remains selectable.", withOptions: []).first), animate: false)
        owner.model.beginLiveText(replacingSelection: true)
        let session = try #require(owner.model.liveEdit)
        let before = session.appliedBounds
        session.text = "Original sentence remains selectable, and now it is long enough to wrap onto the line below it."
        #expect(session.nativeUpdateFailed)
        #expect(session.appliedBounds == before)
        #expect(owner.model.pdfDocument?.findString("Neighboring paragraph stays intact.", withOptions: []).count == 1)
    }
}
