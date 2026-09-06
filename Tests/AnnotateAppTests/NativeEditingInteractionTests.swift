import AnnotateCore
import AppKit
import PDFKit
import Testing
@testable import AnnotateApp

@Suite("Direct native PDF editing interactions", .serialized)
@MainActor
struct NativeEditingInteractionTests {
    private func fixture() throws -> (AnnotateDocument, SelectionPDFView) {
        _ = NSApplication.shared
        let owner = AnnotateDocument()
        let pdf = try PDFConversion.textDocument(NSAttributedString(string: "Original sentence remains selectable.\nNeighboring paragraph stays intact.",
            attributes: [.font: NSFont(name: "Helvetica", size: 16)!]))
        owner.model.load(pdf, owner: owner)
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 900))
        view.document = pdf; view.model = owner.model; owner.model.pdfView = view
        return (owner, view)
    }

    @Test("Entering Edit keeps a reading selection and selecting in Edit opens native typography", arguments: [false, true])
    func directSelection(alreadyEditing: Bool) throws {
        let (owner, view) = try fixture()
        let model = owner.model, original = try #require(model.pdfDocument)
        let selection = try #require(original.findString("Original sentence", withOptions: []).first)
        if alreadyEditing { model.showTool(.edit) }
        view.setCurrentSelection(selection, animate: false)
        if alreadyEditing { model.captureSelection(selection) }
        else { model.captureSelection(selection); model.showTool(.edit) }
        let session = try #require(model.liveEdit)
        #expect(session.text == "Original sentence")
        #expect(session.isExistingContent)
        #expect(abs(session.font.pointSize - 16) < 0.01)
        #expect(model.pdfDocument === original)
        #expect(view.liveTextView?.isRichText == true)
        #expect(model.draft == nil)
        model.discardPendingLiveText()
    }

    @Test("Recovering pending text preserves native form values changed during the edit")
    func pendingEditAndForm() throws {
        let (owner, view) = try fixture()
        let model = owner.model
        let pdf = try #require(model.pdfDocument)
        try PDFFormEditor.create(in: pdf, region: PageRegion(pageIndex: 0, bounds: CGRect(x: 50, y: 80, width: 240, height: 28)),
            name: "Reviewer", kind: .text)
        model.toolSelection = PageRegion(pageIndex: 0, bounds: CGRect(x: 50, y: 150, width: 300, height: 55))
        model.beginLiveText(replacingSelection: false)
        let session = try #require(model.liveEdit)
        session.text = String(repeating: "overflow ", count: 300)
        #expect(session.nativeUpdateFailed)
        let current = try #require(model.pdfDocument)
        let previous = PDFFormEditor.fields(in: current)
        try PDFFormEditor.fill(in: current, field: try #require(previous.first), value: "Retain this value")
        model.recordNativeFormChange(previous: previous)
        session.text = "Recovered native text"
        #expect(!session.nativeUpdateFailed)
        #expect(PDFFormEditor.fields(in: try #require(model.pdfDocument)).first?.value == "Retain this value")
        let reopened = try #require(PDFDocument(data: owner.data(ofType: "com.adobe.pdf")))
        #expect(PDFFormEditor.fields(in: reopened).first?.value == "Retain this value")
        #expect(reopened.findString("Recovered native text", withOptions: []).count == 1)
        #expect(reopened.findString("Neighboring paragraph", withOptions: []).count == 1)
        withExtendedLifetime(view) {}
    }

    @Test("Zoom conversion preserves mixed typography and paragraph metrics round trip")
    func zoomedTypography() throws {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4; paragraph.headIndent = 12; paragraph.paragraphSpacing = 6
        let source = NSMutableAttributedString(string: "First Second", attributes: [.font: NSFont(name: "Times-Roman", size: 16)!,
            .paragraphStyle: paragraph, .foregroundColor: NSColor.blue, .kern: 0.5])
        source.addAttribute(.font, value: NSFont(name: "Courier-Bold", size: 22)!, range: NSRange(location: 6, length: 6))
        let displayed = LiveTextLayout.scaled(source, by: 1.75)
        let restored = LiveTextLayout.scaled(displayed, by: 1 / 1.75)
        #expect(restored.isEqual(to: source))
        #expect((displayed.attribute(.font, at: 7, effectiveRange: nil) as? NSFont)?.pointSize == 38.5)
    }

    @Test("Canvas font size and viewport stay aligned with PDF points across live updates", arguments: [0.7, 1.4])
    func canvasScaleAndScroll(scale: Double) throws {
        let (owner, view) = try fixture()
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(view)
        view.displayMode = .singlePageContinuous
        view.autoScales = false; view.scaleFactor = scale
        view.layoutDocumentView(); view.layoutSubtreeIfNeeded()
        let model = owner.model
        model.toolSelection = PageRegion(pageIndex: 0, bounds: CGRect(x: 50, y: 100, width: 350, height: 70))
        model.beginLiveText(replacingSelection: false)
        let session = try #require(model.liveEdit)
        let field = try #require(view.liveTextView)
        let page = try #require(model.pdfDocument?.page(at: 0))
        let displayedFont = try #require(field.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let actualStart = field.convert(CGPoint.zero, to: view)
        let actualEnd = field.convert(CGPoint(x: displayedFont.pointSize, y: 0), to: view)
        let expectedStart = view.convert(CGPoint.zero, from: page)
        let expectedEnd = view.convert(CGPoint(x: session.font.pointSize, y: 0), from: page)
        #expect(abs(hypot(actualEnd.x - actualStart.x, actualEnd.y - actualStart.y)
            - hypot(expectedEnd.x - expectedStart.x, expectedEnd.y - expectedStart.y)) < 0.5)
        let scroll = try #require(view.documentView?.enclosingScrollView)
        let origin = scroll.contentView.bounds.origin
        session.text = "A steady page while typing"
        #expect(!session.nativeUpdateFailed)
        let restored = try #require(view.documentView?.enclosingScrollView?.contentView.bounds.origin)
        #expect(abs(restored.x - origin.x) < 0.5)
        #expect(abs(restored.y - origin.y) < 0.5)
    }
}
