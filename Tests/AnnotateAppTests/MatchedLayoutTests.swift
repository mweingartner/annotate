import AnnotateCore
import AppKit
import PDFKit
import Testing
@testable import AnnotateApp

/// Edited text must sit exactly where the original did: same baselines, margins,
/// alignment and font. Each test edits a paragraph in place and compares every line.
@Suite("Edited text matches the original layout", .serialized)
@MainActor
struct MatchedLayoutTests {
    private struct Line { let text: String; let box: CGRect }

    private func lines(around point: CGPoint, on page: PDFPage) -> [Line] {
        (ParagraphText.selection(at: point, on: page)?.selectionsByLine() ?? []).map { Line(text: $0.string ?? "", box: $0.bounds(for: page)) }
    }

    /// Edits the paragraph containing `word` by appending " Z", and returns its lines
    /// before and after, with the session.
    private func edit(_ pdf: PDFDocument, at word: String) throws -> (before: [Line], after: [Line], session: LiveTextEdit, owner: AnnotateDocument, window: NSWindow) {
        _ = NSApplication.shared
        let owner = AnnotateDocument()
        owner.model.load(pdf, owner: owner)
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.document = pdf; view.model = owner.model; owner.model.pdfView = view
        view.layoutDocumentView()
        owner.model.showTool(.edit)
        let page = try #require(pdf.page(at: 0))
        let hit = try #require(pdf.findString(word, withOptions: []).first).bounds(for: page)
        let point = CGPoint(x: hit.midX, y: hit.midY)
        let before = lines(around: point, on: page)
        view.editParagraph(at: view.convert(view.convert(point, from: page), to: nil))
        let session = try #require(owner.model.liveEdit)
        session.text += " Z"
        #expect(!session.nativeUpdateFailed, "\(session.nativeFailureMessage ?? "")")
        let edited = try #require(owner.model.pdfDocument?.page(at: 0))
        let after = lines(around: CGPoint(x: before[0].box.midX, y: before[0].box.midY), on: edited)
        return (before, after, session, owner, window)
    }

    private func document(_ text: String, font: NSFont, configure: (NSMutableParagraphStyle) -> Void) throws -> PDFDocument {
        let style = NSMutableParagraphStyle()
        configure(style)
        return try PDFConversion.textDocument(NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: style]))
    }

    private let body = "Reading closely means noticing the argument beneath the prose. A careful reader returns to the passages that carry weight and asks what evidence supports them, which assumptions they rest on, and where the reasoning might bend."

    @Test("Ragged-left text keeps every baseline and left edge exactly, and its line breaks")
    func raggedLeft() throws {
        let result = try edit(SamplePDF.make(), at: "Annotate lets")
        defer { result.owner.model.discardPendingLiveText(); result.window.close() }
        #expect(result.after.count == result.before.count)
        for (before, after) in zip(result.before, result.after) {
            #expect(abs(after.box.minY - before.box.minY) < 0.05, "baseline moved on \(before.text)")
            #expect(abs(after.box.minX - before.box.minX) < 0.05, "left edge moved on \(before.text)")
        }
        // Unchanged lines break where they did.
        for (before, after) in zip(result.before.dropLast(), result.after.dropLast()) {
            #expect(after.text.trimmingCharacters(in: .whitespacesAndNewlines) == before.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @Test("Justified text stays justified to the same margins, at the same line pitch")
    func justified() throws {
        let pdf = try document(body, font: try #require(NSFont(name: "Times New Roman", size: 13))) {
            $0.alignment = .justified; $0.lineSpacing = 5
        }
        let result = try edit(pdf, at: "careful reader")
        defer { result.owner.model.discardPendingLiveText(); result.window.close() }
        #expect(result.session.alignment == .justified)
        #expect(result.after.count == result.before.count)
        for (before, after) in zip(result.before, result.after) {
            #expect(abs(after.box.minY - before.box.minY) < 0.05)
            #expect(abs(after.box.minX - before.box.minX) < 0.05)
        }
        for (before, after) in zip(result.before.dropLast(), result.after.dropLast()) {
            #expect(abs(after.box.maxX - before.box.maxX) < 0.1, "justified line no longer reaches the margin")
        }
    }

    /// Paragraphs set by CoreText straight into a PDF page, as Pages and TextEdit do.
    private func framedDocument(_ paragraphs: [String], font: NSFont, style: NSParagraphStyle, column: CGRect) throws -> PDFDocument {
        let body = NSMutableAttributedString()
        for paragraph in paragraphs {
            body.append(NSAttributedString(string: paragraph + "\n", attributes: [.font: font, .paragraphStyle: style]))
        }
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(body), CFRange(), CGPath(rect: column, transform: nil), nil)
        CTFrameDraw(frame, context)
        context.endPDFPage(); context.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }

    @Test("Indented, justified paragraphs set by CoreText stay justified to their column, with the same line breaks")
    func justifiedAndIndented() throws {
        let style = NSMutableParagraphStyle()
        style.alignment = .justified; style.lineSpacing = 4; style.firstLineHeadIndent = 18
        let pdf = try framedDocument([body, "Marginal notes are a conversation with the author. They record a question, a disagreement, or a connection to something read years before, and they make the second reading faster and richer than the first."],
                                     font: try #require(NSFont(name: "Times New Roman", size: 14)), style: style,
                                     column: CGRect(x: 90, y: 300, width: 432, height: 420))
        let result = try edit(pdf, at: "careful reader")
        defer { result.owner.model.discardPendingLiveText(); result.window.close() }
        #expect(result.session.alignment == .justified)
        #expect(abs(result.session.appliedBounds.maxX - 522) < 0.05, "the block must end at the column")
        #expect(result.after.count == result.before.count)
        for (before, after) in zip(result.before, result.after) {
            #expect(abs(after.box.minY - before.box.minY) < 0.05)
            #expect(abs(after.box.minX - before.box.minX) < 0.05)
        }
        for (before, after) in zip(result.before.dropLast(), result.after.dropLast()) {
            #expect(after.text.trimmingCharacters(in: .whitespaces) == before.text.trimmingCharacters(in: .whitespaces))
            #expect(abs(after.box.maxX - before.box.maxX) < 1, "justified line no longer reaches the column")
        }
        // The next paragraph is untouched.
        let next = try #require(result.owner.model.pdfDocument?.findString("Marginal notes", withOptions: []).first)
        #expect(next.string == "Marginal notes")
    }

    @Test("Right-aligned and centred text keep their alignment and edges", arguments: [NSTextAlignment.right, .center])
    func alignedText(alignment: NSTextAlignment) throws {
        let pdf = try document(body, font: try #require(NSFont(name: "Helvetica", size: 12))) { $0.alignment = alignment }
        let result = try edit(pdf, at: "careful reader")
        defer { result.owner.model.discardPendingLiveText(); result.window.close() }
        #expect(result.session.alignment == alignment)
        for (before, after) in zip(result.before.dropLast(), result.after.dropLast()) {
            #expect(abs(after.box.minY - before.box.minY) < 0.05)
            if alignment == .right { #expect(abs(after.box.maxX - before.box.maxX) < 0.1) }
            else { #expect(abs(after.box.midX - before.box.midX) < 0.1) }
        }
    }

    @Test("A first-line indent is kept")
    func indented() throws {
        let pdf = try document(body, font: try #require(NSFont(name: "Georgia", size: 12))) {
            $0.firstLineHeadIndent = 24; $0.lineSpacing = 2
        }
        let result = try edit(pdf, at: "careful reader")
        defer { result.owner.model.discardPendingLiveText(); result.window.close() }
        let style = try #require(result.session.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(abs(style.firstLineHeadIndent - 24) < 0.1)
        for (before, after) in zip(result.before, result.after) {
            #expect(abs(after.box.minX - before.box.minX) < 0.05)
            #expect(abs(after.box.minY - before.box.minY) < 0.05)
        }
    }

    @Test("The edit keeps the original font and size")
    func keepsFont() throws {
        let pdf = try document(body, font: try #require(NSFont(name: "Georgia-Italic", size: 14))) { _ in }
        let result = try edit(pdf, at: "careful reader")
        defer { result.owner.model.discardPendingLiveText(); result.window.close() }
        #expect(result.session.font.fontName == "Georgia-Italic")
        #expect(abs(result.session.font.pointSize - 14) < 0.01)
    }

    @Test("A new text box takes the font and colour of the text beside it")
    func newTextTakesNearbyStyle() throws {
        _ = NSApplication.shared
        let text = NSAttributedString(string: body, attributes: [.font: try #require(NSFont(name: "Georgia", size: 15)),
                                                                   .foregroundColor: NSColor(srgbRed: 0.2, green: 0.3, blue: 0.6, alpha: 1)])
        let pdf = try PDFConversion.textDocument(text)
        let owner = AnnotateDocument()
        owner.model.load(pdf, owner: owner)
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        view.document = pdf; view.model = owner.model; owner.model.pdfView = view
        defer { owner.model.discardPendingLiveText() }
        let page = try #require(pdf.page(at: 0))
        let paragraph = try #require(pdf.findString("Reading closely", withOptions: []).first).bounds(for: page)
        owner.model.toolSelection = PageRegion(pageIndex: 0, bounds: CGRect(x: paragraph.minX, y: paragraph.minY - 200, width: 200, height: 30))
        owner.model.beginLiveText(replacingSelection: false)
        let session = try #require(owner.model.liveEdit)
        #expect(session.font.familyName == "Georgia")
        #expect(abs(session.font.pointSize - 15) < 0.01)
        let color = try #require(session.color.usingColorSpace(.sRGB))
        #expect(abs(color.blueComponent - 0.6) < 0.05)
    }

    @Test("Alignment reading: a single line is left; shared edges and centres are recognised")
    func alignmentReading() {
        func layout(_ lines: [(Double, Double)]) -> PDFNativeTextLayout {
            PDFNativeTextLayout(lines: lines.enumerated().map { .init(start: $1.0, end: $1.1, baseline: 700 - Double($0) * 14) },
                                characterSpacing: 0)
        }
        #expect(layout([(72, 300)]).alignment(fontSize: 12) == .left)
        #expect(layout([(72, 500), (72, 500), (72, 300)]).alignment(fontSize: 12) == .justified)
        // A glyph overhanging the column by most of a point is still justified…
        #expect(layout([(90, 522.75), (72, 521.98), (72, 522), (72, 300)]).alignment(fontSize: 14) == .justified)
        #expect(layout([(90, 522.75), (72, 521.98), (72, 522), (72, 300)]).justifiedMargin == 522)
        // …but a ragged line a few points short is not.
        #expect(layout([(72, 500), (72, 470), (72, 300)]).alignment(fontSize: 12) == .left)
        #expect(layout([(100, 500), (150, 500), (300, 500)]).alignment(fontSize: 12) == .right)
        #expect(layout([(100, 400), (150, 350), (200, 300)]).alignment(fontSize: 12) == .center)
        // Lines centred on the same point are centred even when nearly equal in length…
        #expect(layout([(52.2, 559.8), (50.5, 561.5)]).alignment(fontSize: 12) == .center)
        // …while ragged lines whose centres merely come close are left-aligned.
        #expect(layout([(72, 559.8), (72, 548)]).alignment(fontSize: 12) == .left)
        #expect(layout([(96, 500), (72, 500), (72, 300)]).firstLineIndent == 24)
        #expect(layout([(72, 500), (72, 480)]).linePitch == 14)
    }

    @Test("Only the first paragraph takes the first-line indent, even when all share one style")
    func indentOnlyFirstParagraph() throws {
        let style = NSMutableParagraphStyle()
        let text = NSAttributedString(string: "First paragraph line\nSecond line kept\nThird line kept",
                                      attributes: [.font: try #require(NSFont(name: "Helvetica", size: 12)), .paragraphStyle: style])
        let layout = PDFNativeTextLayout(lines: [.init(start: 96, end: 400, baseline: 700), .init(start: 72, end: 380, baseline: 686),
                                                 .init(start: 72, end: 300, baseline: 672)], characterSpacing: 0)
        let styled = MatchedLayout.styled(text, like: layout, rewrapping: false)
        let first = try #require(styled.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let second = try #require(styled.attribute(.paragraphStyle, at: 22, effectiveRange: nil) as? NSParagraphStyle)
        let third = try #require(styled.attribute(.paragraphStyle, at: 40, effectiveRange: nil) as? NSParagraphStyle)
        #expect(first.firstLineHeadIndent == 24)
        #expect(second.firstLineHeadIndent == 0)
        #expect(third.firstLineHeadIndent == 0)
    }
}
