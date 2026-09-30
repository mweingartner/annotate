import AnnotateCore
import AppKit
import PDFKit
import Testing
@testable import AnnotateApp

/// Clicks, Escape and presentation of the in-place text editor. Events are only sent
/// where SelectionPDFView handles them itself: a synthetic event that reaches PDFKit's
/// own mouseDown would block in its tracking loop.
@Suite("In-place editor: clicks, Escape and presentation", .serialized)
@MainActor
struct LiveEditorInteractionTests {
    @MainActor private struct Fixture {
        let owner: AnnotateDocument
        let view: SelectionPDFView
        let window: NSWindow
        var model: ReaderModel { owner.model }
        var pdf: PDFDocument { owner.model.pdfDocument! }
    }

    private func fixture(markers: [String] = []) throws -> Fixture {
        _ = NSApplication.shared
        let owner = AnnotateDocument()
        let pdf = SamplePDF.make()
        for phrase in markers {
            let selection = try #require(pdf.findString(phrase, withOptions: []).first)
            try MarkerCodec.apply(PDFMarker(categories: [.important], color: MarkerColor.palette[0], icon: "star.fill",
                quote: selection.string ?? phrase, note: "Note", question: "",
                regions: MarkerCodec.regions(for: selection, in: pdf)), to: pdf)
        }
        owner.model.load(pdf, owner: owner)
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.document = pdf; view.model = owner.model; owner.model.pdfView = view
        view.layoutDocumentView()
        owner.model.showTool(.edit)
        return Fixture(owner: owner, view: view, window: window)
    }

    private func windowPoint(of phrase: String, in fixture: Fixture, page index: Int = 0) throws -> NSPoint {
        let page = try #require(fixture.pdf.page(at: index))
        let bounds = try #require(fixture.pdf.findString(phrase, withOptions: []).first).bounds(for: page)
        fixture.view.go(to: bounds, on: page)
        fixture.view.layoutSubtreeIfNeeded()
        let point = CGPoint(x: bounds.minX + 1, y: bounds.midY)
        return fixture.view.convert(fixture.view.convert(point, from: page), to: nil)
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    /// Opens a paragraph as a click in Edit does, then waits for it to be applied once.
    private func openParagraph(_ phrase: String, in fixture: Fixture) throws -> LiveTextEdit {
        fixture.view.editParagraph(at: try windowPoint(of: phrase, in: fixture))
        return try #require(fixture.model.liveEdit)
    }

    /// Text that cannot fit and has no empty space below to grow into.
    private func overflow(_ session: LiveTextEdit) {
        session.text = String(repeating: "This paragraph will not fit where it is. ", count: 40)
    }

    // MARK: - editParagraph guards

    @Test("A click outside Edit, on blank page, or over a selection does not open a paragraph")
    func paragraphGuards() throws {
        let fixture = try fixture()
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let point = try windowPoint(of: "Annotate lets", in: fixture)
        // Blank margin of the page.
        let page = try #require(fixture.pdf.page(at: 0))
        let margin = fixture.view.convert(fixture.view.convert(CGPoint(x: 20, y: 400), from: page), to: nil)
        fixture.view.editParagraph(at: margin)
        #expect(fixture.model.liveEdit == nil)
        // Words already selected: the click was the end of a drag, not "edit this".
        fixture.view.setCurrentSelection(try #require(fixture.pdf.findString("an exact", withOptions: []).first), animate: false)
        #expect(fixture.view.currentSelection?.string == "an exact")
        fixture.view.editParagraph(at: point)
        #expect(fixture.model.liveEdit == nil)
        fixture.view.clearSelection()
        // Not in Edit.
        fixture.model.activeTool = nil
        fixture.view.editParagraph(at: point)
        #expect(fixture.model.liveEdit == nil)
        fixture.model.showTool(.edit)
        fixture.view.editParagraph(at: point)
        #expect(fixture.model.liveEdit != nil)
    }

    @Test("A second click while a paragraph is open does not replace the open session")
    func noSecondSession() throws {
        let fixture = try fixture()
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let session = try openParagraph("Annotate lets", in: fixture)
        fixture.view.editParagraph(at: try windowPoint(of: "Select a few words", in: fixture))
        #expect(fixture.model.liveEdit === session)
    }

    // MARK: - Clicking elsewhere

    @Test("Clicking elsewhere on the page finishes an applied edit and keeps the typed text")
    func clickElsewhereFinishes() throws {
        let fixture = try fixture(markers: ["Attention is a choice"])
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let session = try openParagraph("Annotate lets", in: fixture)
        session.text = session.text.replacingOccurrences(of: "Annotate lets", with: "Annotate helps")
        #expect(!session.nativeUpdateFailed)
        // Click a marker's pin: SelectionPDFView handles that click itself.
        let page = try #require(fixture.pdf.page(at: 0))
        let badge = try #require(page.annotations.first { $0.type == "FreeText" })
        let pagePoint = CGPoint(x: badge.bounds.midX, y: badge.bounds.midY)
        fixture.view.go(to: badge.bounds, on: page)
        fixture.view.layoutSubtreeIfNeeded()
        let point = fixture.view.convert(fixture.view.convert(pagePoint, from: page), to: nil)
        fixture.view.mouseDown(with: try event(.leftMouseDown, at: point, in: fixture.window))
        #expect(fixture.model.liveEdit == nil)
        #expect(fixture.view.liveTextView == nil)
        #expect(fixture.model.toolSelection == nil, "The finished block's outline is not left behind")
        #expect(fixture.pdf.findString("Annotate helps", withOptions: []).count == 1)
        // Release away from the pin so no popover opens in the test.
        fixture.view.mouseDragged(with: try event(.leftMouseDragged, at: .zero, in: fixture.window))
        fixture.view.mouseUp(with: try event(.leftMouseUp, at: .zero, in: fixture.window))
    }

    @Test("Clicking elsewhere keeps an edit that could not be applied open, with its text")
    func clickElsewhereKeepsPending() throws {
        let fixture = try fixture()
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let session = try openParagraph("Annotate lets", in: fixture)
        overflow(session)
        #expect(session.nativeUpdateFailed)
        let pending = session.text
        let point = try windowPoint(of: "Select a few words", in: fixture)
        fixture.view.mouseDown(with: try event(.leftMouseDown, at: point, in: fixture.window))
        #expect(fixture.model.liveEdit === session)
        #expect(session.text == pending)
        #expect(fixture.view.liveTextView != nil)
        #expect(fixture.model.errorMessage?.contains("discard the pending edit") == true)
    }

    // MARK: - Escape

    @Test("Escape in the editor finishes an applied edit after the key event")
    func escapeFinishes() async throws {
        let fixture = try fixture()
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let session = try openParagraph("Annotate lets", in: fixture)
        session.text = session.text.replacingOccurrences(of: "Annotate lets", with: "Annotate helps")
        let field = try #require(fixture.view.liveTextView)
        let delegate = try #require(fixture.view.liveTextDelegate)
        #expect(delegate.textView(field, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        // Finishing is deferred so AppKit can finish the key event with the text view intact.
        #expect(fixture.model.liveEdit === session)
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.model.liveEdit == nil)
        #expect(fixture.view.liveTextView == nil)
        #expect(fixture.pdf.findString("Annotate helps", withOptions: []).count == 1)
    }

    @Test("Escape repairs a half-typed font size before finishing")
    func escapeNormalizesFontSize() async throws {
        let fixture = try fixture()
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let session = try openParagraph("Annotate lets", in: fixture)
        session.fontSize = 0
        #expect(!session.fontSizeIsValid)
        let field = try #require(fixture.view.liveTextView)
        #expect(try #require(fixture.view.liveTextDelegate).textView(field, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.fontSizeIsValid)
        #expect(session.fontSize == 4)
        #expect(fixture.model.liveEdit == nil)
    }

    @Test("Escape keeps an edit that could not be applied open; other commands go to the text view")
    func escapeKeepsPendingAndOtherCommands() async throws {
        let fixture = try fixture()
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let session = try openParagraph("Annotate lets", in: fixture)
        let field = try #require(fixture.view.liveTextView)
        let delegate = try #require(fixture.view.liveTextDelegate)
        for command in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)),
                        #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.moveLeft(_:))] {
            #expect(!delegate.textView(field, doCommandBy: command), "\(command)")
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.model.liveEdit === session)
        overflow(session)
        #expect(session.nativeUpdateFailed)
        #expect(delegate.textView(field, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.model.liveEdit === session)
        #expect(fixture.model.errorMessage?.contains("discard the pending edit") == true)
    }

    @Test("Escape after the session was already closed does nothing")
    func escapeAfterClose() async throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        _ = try openParagraph("Annotate lets", in: fixture)
        let field = try #require(fixture.view.liveTextView)
        let delegate = try #require(fixture.view.liveTextDelegate)
        fixture.model.discardPendingLiveText()
        #expect(delegate.textView(field, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.model.liveEdit == nil)
        #expect(fixture.model.errorMessage == nil)
    }

    // MARK: - Presentation

    @Test("The editor hides its own glyphs while the page shows the text, and shows them when it cannot")
    func glyphsFollowApplyState() throws {
        let fixture = try fixture()
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let session = try openParagraph("Annotate lets", in: fixture)
        let field = try #require(fixture.view.liveTextView)
        let layout = try #require(field.layoutManager as? LiveTextLayoutManager)
        #expect(!layout.drawsGlyphs)
        #expect(!field.drawsBackground)
        overflow(session)
        #expect(session.nativeUpdateFailed)
        #expect(layout.drawsGlyphs)
        #expect(field.drawsBackground)
        session.text = "Short again."
        #expect(!session.nativeUpdateFailed)
        #expect(!layout.drawsGlyphs)
        #expect(!field.drawsBackground)
        #expect(field.accessibilityLabel() == "Edit PDF text in place")
        #expect(field.accessibilityHelp()?.contains("Escape") == true)
    }

    /// Dark pixels drawn by the editor, rendered offscreen.
    private func inkPixels(of field: NSTextView) throws -> Int {
        let rep = try #require(field.bitmapImageRepForCachingDisplay(in: field.bounds))
        field.cacheDisplay(in: field.bounds, to: rep)
        var dark = 0
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh {
            if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.5,
               (color.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) < 0.4 { dark += 1 }
        } }
        return dark
    }

    @Test("Hidden glyphs are really not drawn; shown glyphs are")
    func canvasDrawsGlyphsOnlyOnRequest() throws {
        _ = NSApplication.shared
        let field = LiveTextCanvas.makeEditor()
        field.frame = CGRect(x: 0, y: 0, width: 240, height: 40)
        field.textStorage?.setAttributedString(NSAttributedString(string: "MMMMMMMM",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 24), .foregroundColor: NSColor.black]))
        field.setSelectedRange(NSRange(location: 0, length: 0))
        LiveTextCanvas.present(field, showsPendingText: false, overflows: false)
        let hidden = try inkPixels(of: field)
        #expect(hidden == 0)
        LiveTextCanvas.present(field, showsPendingText: true, overflows: false)
        let shown = try inkPixels(of: field)
        #expect(shown > 50)
        // The outline sits outside the text block and follows the state.
        let outline = try #require(field.layer?.sublayers?.first { $0.name == "AnnotateLiveTextOutline" } as? CAShapeLayer)
        func overflowMarks() -> Int { field.layer?.sublayers?.filter { $0.name == "AnnotateLiveTextOverflow" }.count ?? 0 }
        #expect(outline.lineDashPattern != nil, "Any other failure gets the caution outline")
        #expect(outline.frame.contains(field.bounds))
        #expect(overflowMarks() == 0)
        // Text that only needs more room: ordinary outline plus one overflow mark on the bottom edge.
        LiveTextCanvas.present(field, showsPendingText: true, overflows: true)
        #expect(outline.lineDashPattern == nil)
        #expect(overflowMarks() == 1)
        LiveTextCanvas.present(field, showsPendingText: true, overflows: true)
        #expect(overflowMarks() == 1, "Presenting again reuses the mark")
        // Overflowing text that was applied (not pending) shows no mark.
        LiveTextCanvas.present(field, showsPendingText: false, overflows: true)
        #expect(overflowMarks() == 0)
        #expect(try inkPixels(of: field) == 0)
        LiveTextCanvas.present(field, showsPendingText: false, overflows: false)
        #expect(outline.lineDashPattern == nil)
        #expect(field.layer?.sublayers?.filter { $0.name == "AnnotateLiveTextOutline" }.count == 1, "Presenting again reuses the outline")
    }

    // MARK: - Discarding

    @Test("Discarding clears the tool area only when it is the edit's own block")
    func discardClearsOwnToolSelection() throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        let session = try openParagraph("Annotate lets", in: fixture)
        #expect(fixture.model.toolSelection == PageRegion(pageIndex: 0, bounds: session.appliedBounds))
        fixture.model.discardPendingLiveText()
        #expect(fixture.model.toolSelection == nil)
        #expect(fixture.view.liveTextView == nil)

        _ = try openParagraph("Annotate lets", in: fixture)
        let chosen = PageRegion(pageIndex: 0, bounds: CGRect(x: 10, y: 10, width: 50, height: 50))
        fixture.model.toolSelection = chosen
        fixture.model.discardPendingLiveText()
        #expect(fixture.model.toolSelection == chosen, "An area chosen by the person stays")
        // With no session, discarding leaves any area alone.
        fixture.model.discardPendingLiveText()
        #expect(fixture.model.toolSelection == chosen)
    }
}
