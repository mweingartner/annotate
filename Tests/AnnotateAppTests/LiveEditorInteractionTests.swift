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

    /// `windowServer` gives the window a real window number (it is still never shown), so
    /// key events sent to it reach the window as they would from the keyboard.
    private func fixture(markers: [String] = [], windowServer: Bool = false) throws -> Fixture {
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
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: !windowServer)
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
        #expect(fixture.model.errorMessage?.contains("press Escape to discard it") == true)
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

    @Test("Escape ends an edit that could not be applied, dropping only that text; other commands go to the text view")
    func escapeDiscardsPendingAndOtherCommands() async throws {
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
        #expect(fixture.model.liveEdit == nil)
        #expect(fixture.view.liveTextView == nil)
        #expect(fixture.model.statusMessage == "Discarded the text that couldn’t be applied")
        // The page keeps the last text that was applied: here, the original.
        #expect(fixture.pdf.findString("Annotate lets", withOptions: []).count == 1)
    }

    @Test("Closing the Edit inspector ends an edit that could not be applied")
    func closeDiscardsPending() throws {
        let fixture = try fixture()
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let session = try openParagraph("Annotate lets", in: fixture)
        overflow(session)
        #expect(session.nativeUpdateFailed)
        fixture.model.closeActiveTool()
        #expect(fixture.model.liveEdit == nil)
        #expect(fixture.model.activeTool == nil)
        #expect(fixture.pdf.findString("Annotate lets", withOptions: []).count == 1)
    }

    @Test("Undo drops text that could not be applied; the next Undo reverts the applied edit")
    func undoDiscardsPendingThenRevertsEdit() throws {
        let fixture = try fixture()
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let undo = try #require(fixture.owner.undoManager)
        undo.groupsByEvent = false
        let session = try openParagraph("Annotate lets", in: fixture)
        undo.beginUndoGrouping()
        session.text = session.text.replacingOccurrences(of: "Annotate lets", with: "Annotate helps")
        undo.endUndoGrouping()
        #expect(fixture.pdf.findString("Annotate helps", withOptions: []).count == 1)
        undo.beginUndoGrouping()
        overflow(session)
        undo.endUndoGrouping()
        #expect(session.nativeUpdateFailed)
        undo.undo()
        #expect(fixture.model.liveEdit == nil)
        #expect(fixture.model.statusMessage == "Discarded the text that couldn’t be applied")
        #expect(fixture.model.pdfDocument?.findString("Annotate helps", withOptions: []).count == 1)
        undo.undo()
        #expect(fixture.model.pdfDocument?.findString("Annotate lets", withOptions: []).count == 1)
    }

    @Test("Text that applies again withdraws the Undo step that would have dropped it")
    func recoveredTextWithdrawsUndoStep() throws {
        let fixture = try fixture()
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let undo = try #require(fixture.owner.undoManager)
        undo.groupsByEvent = false
        let session = try openParagraph("Annotate lets", in: fixture)
        let original = session.text
        undo.beginUndoGrouping()
        overflow(session)
        undo.endUndoGrouping()
        #expect(session.nativeUpdateFailed)
        #expect(session.pendingTextUndo != nil)
        undo.beginUndoGrouping()
        session.text = original
        undo.endUndoGrouping()
        #expect(!session.nativeUpdateFailed)
        #expect(session.pendingTextUndo == nil)
        #expect(undo.undoActionName != "Typing")
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

    // MARK: - Escape anywhere in the window

    private static let discarded = "Discarded the text that couldn’t be applied"

    /// Sends a key event through the application, as the run loop does, so the editor's
    /// window-wide Escape monitor sees it. The monitor keeps an Escape exactly when it ends
    /// the edit, after the event; so whether the edit is still open once the event has
    /// settled says whether the key was taken or passed on. (The order in which AppKit calls
    /// local monitors is not fixed, so a second monitor cannot observe this.)
    private func sendKey(_ keyCode: UInt16 = 53, modifiers: NSEvent.ModifierFlags = [], to window: NSWindow,
                         afterSending: () -> Void = {}) async throws {
        let characters = keyCode == 53 ? "\u{1B}" : "\r"
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        #expect(event.window === window, "The event addresses the window, as a real key press does")
        NSApp.sendEvent(event)
        afterSending()
        try await Task.sleep(for: .milliseconds(50))
    }

    /// Puts a text field beside the reader, as the Edit inspector's fields are, and returns it.
    private func addInspectorField(to fixture: Fixture) -> NSTextField {
        let container = NSView(frame: fixture.view.frame)
        fixture.window.contentView = container
        container.addSubview(fixture.view)
        let field = NSTextField(frame: CGRect(x: 10, y: 10, width: 120, height: 22))
        field.stringValue = "12"
        container.addSubview(field)
        return field
    }

    @Test("Escape ends the edit when an inspector field has focus, or nothing does, and keeps text that was applied")
    func escapeFromInspectorKeepsAppliedText() async throws {
        let fixture = try fixture(windowServer: true)
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let field = addInspectorField(to: fixture)
        let session = try openParagraph("Annotate lets", in: fixture)
        session.text = session.text.replacingOccurrences(of: "Annotate lets", with: "Annotate helps")
        #expect(!session.nativeUpdateFailed)
        #expect(fixture.window.makeFirstResponder(field))
        let editor = try #require(fixture.window.firstResponder as? NSTextView, "The field's field editor has focus")
        #expect(editor !== fixture.view.liveTextView)
        try await sendKey(to: fixture.window)
        #expect(fixture.model.liveEdit == nil)
        #expect(fixture.view.liveTextView == nil)
        #expect(fixture.model.statusMessage != Self.discarded)
        #expect(fixture.pdf.findString("Annotate helps", withOptions: []).count == 1)
        #expect(field.stringValue == "12", "The field's own value is untouched")

        // Nothing focused at all.
        let second = try openParagraph("Annotate helps", in: fixture)
        second.text = second.text.replacingOccurrences(of: "Annotate helps", with: "Annotate aids")
        #expect(fixture.window.makeFirstResponder(nil))
        try await sendKey(to: fixture.window)
        #expect(fixture.model.liveEdit == nil)
        #expect(fixture.pdf.findString("Annotate aids", withOptions: []).count == 1)
    }

    @Test("Escape from an inspector field drops text that could not be applied")
    func escapeFromInspectorDiscardsPending() async throws {
        let fixture = try fixture(windowServer: true)
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let field = addInspectorField(to: fixture)
        let session = try openParagraph("Annotate lets", in: fixture)
        overflow(session)
        #expect(session.nativeUpdateFailed)
        #expect(fixture.model.errorMessage == nil || fixture.model.errorMessage?.contains("Press Escape or Undo") == true)
        #expect(fixture.window.makeFirstResponder(field))
        try await sendKey(to: fixture.window)
        #expect(fixture.model.liveEdit == nil)
        #expect(fixture.view.liveTextView == nil)
        #expect(fixture.model.statusMessage == Self.discarded)
        #expect(fixture.model.errorMessage == nil, "The failure no longer applies once its text is gone")
        #expect(fixture.pdf.findString("Annotate lets", withOptions: []).count == 1)
        #expect(fixture.pdf.findString("will not fit", withOptions: []).isEmpty)
    }

    @Test("Escape the editor doesn't own is passed on: another window, a modifier, another key, an attached sheet")
    func escapeMonitorGuards() async throws {
        let fixture = try fixture(windowServer: true)
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let session = try openParagraph("Annotate lets", in: fixture)
        overflow(session)
        #expect(session.nativeUpdateFailed)
        let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        try await sendKey(to: other)
        #expect(fixture.model.liveEdit === session, "Escape in another window belongs to that window")
        for modifiers: NSEvent.ModifierFlags in [.shift, .command, .option, .control, [.command, .shift], [.function, .option]] {
            try await sendKey(modifiers: modifiers, to: fixture.window)
            #expect(fixture.model.liveEdit === session, "Modifiers \(modifiers.rawValue)")
        }
        try await sendKey(36, to: fixture.window)
        #expect(fixture.model.liveEdit === session, "Return is not Escape")
        let sheet = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        fixture.window.beginSheet(sheet, completionHandler: nil)
        #expect(fixture.window.attachedSheet === sheet)
        try await sendKey(to: fixture.window)
        #expect(fixture.model.liveEdit === session, "A sheet's Escape cancels the sheet")
        fixture.window.endSheet(sheet)
        sheet.close()
        let deadline = ContinuousClock.now + .seconds(10)
        while fixture.window.attachedSheet != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(fixture.window.attachedSheet == nil)
        #expect(session.nativeUpdateFailed)
        // The Fn key alone (some keyboards report it with Escape) is still plain Escape.
        try await sendKey(modifiers: .function, to: fixture.window)
        #expect(fixture.model.liveEdit == nil)
        #expect(fixture.model.statusMessage == Self.discarded)
    }

    @Test("Caps Lock does not stop Escape from ending the edit")
    func escapeWithCapsLock() async throws {
        let fixture = try fixture(windowServer: true)
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let field = addInspectorField(to: fixture)
        let session = try openParagraph("Annotate lets", in: fixture)
        overflow(session)
        #expect(fixture.window.makeFirstResponder(field))
        try await sendKey(modifiers: .capsLock, to: fixture.window)
        #expect(fixture.model.liveEdit == nil)
        #expect(fixture.model.statusMessage == Self.discarded)
    }

    @Test("Escape during input-method composition goes to the input method, in the editor or a field")
    func escapeDuringComposition() async throws {
        let fixture = try fixture(windowServer: true)
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let field = addInspectorField(to: fixture)
        let session = try openParagraph("Annotate lets", in: fixture)
        let text = try #require(fixture.view.liveTextView)
        #expect(fixture.window.makeFirstResponder(text))
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(text.hasMarkedText())
        try await sendKey(to: fixture.window)
        #expect(fixture.model.liveEdit === session)
        text.unmarkText()
        // Composing in an inspector field is the same.
        #expect(fixture.window.makeFirstResponder(field))
        let editor = try #require(fixture.window.firstResponder as? NSTextView)
        editor.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        try await sendKey(to: fixture.window)
        #expect(fixture.model.liveEdit === session)
        // Once the composition is done, Escape ends the edit.
        editor.unmarkText()
        #expect(!editor.hasMarkedText())
        try await sendKey(to: fixture.window)
        #expect(fixture.model.liveEdit == nil)
    }

    @Test("With no edit open Escape is not taken; ending the edit removes the monitor; showing it again adds one")
    func escapeMonitorLifecycle() async throws {
        let fixture = try fixture(windowServer: true)
        defer { fixture.model.liveEdit = nil; fixture.view.removeLiveEditor(); fixture.window.close() }
        let session = try openParagraph("Annotate lets", in: fixture)
        // The editor is still on screen, but the model has no edit: the monitor stands aside.
        // (Had it kept the key, the end it schedules would find the edit restored here.)
        fixture.model.liveEdit = nil
        try await sendKey(to: fixture.window) { fixture.model.liveEdit = session }
        #expect(fixture.model.liveEdit === session)
        #expect(fixture.view.liveTextView != nil)
        // Ending the edit takes the monitor away: an edit the view isn't showing is not ended by it.
        fixture.model.discardPendingLiveText()
        #expect(fixture.view.liveTextView == nil)
        fixture.model.liveEdit = session
        try await sendKey(to: fixture.window)
        #expect(fixture.model.liveEdit === session)
        // Showing the editor again watches again: one Escape ends it.
        fixture.view.refreshLiveEditor()
        fixture.view.refreshLiveEditor()
        try await sendKey(to: fixture.window)
        #expect(fixture.model.liveEdit == nil)
        #expect(fixture.view.liveTextView == nil)
    }

    // MARK: - Undo, Redo and the document's edited state

    /// Lets the current "event" end, as AppKit's run loop does after each key press: the
    /// undo manager closes the event's group, and NSDocument then settles its edited state.
    /// These tests keep the undo manager grouping by event, as the app does; a group opened
    /// by hand is kept and counted even when nothing was registered in it.
    private func settle(_ undo: UndoManager) async throws {
        try await Task.sleep(for: .milliseconds(60))
        let deadline = ContinuousClock.now + .seconds(10)
        while undo.groupingLevel > 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(undo.groupingLevel == 0, "The event's undo group closed")
        try await Task.sleep(for: .milliseconds(60))
    }

    private func pageText(_ fixture: Fixture) -> String? { fixture.model.pdfDocument?.page(at: 0)?.string }

    /// Checks the document's edited state once NSDocument has caught up, which a loaded run
    /// can delay by more than a run-loop turn. It waits for `expected` (a wrong state never
    /// arrives, and fails at the deadline), then checks that the state holds.
    private func expectEdited(_ fixture: Fixture, _ expected: Bool, _ comment: Comment? = nil,
                              sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while fixture.owner.isDocumentEdited != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(60))
        #expect(fixture.owner.isDocumentEdited == expected, comment, sourceLocation: sourceLocation)
    }

    @Test("Undo when the very first keystroke failed drops the text and leaves the document as it was")
    func undoFirstKeystrokeFailure() async throws {
        let fixture = try fixture()
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let undo = try #require(fixture.owner.undoManager)
        #expect(undo.groupsByEvent)
        let before = pageText(fixture)
        let session = try openParagraph("Annotate lets", in: fixture)
        try await settle(undo)
        #expect(!undo.canUndo, "Opening the paragraph changes nothing")
        overflow(session)
        try await settle(undo)
        #expect(session.nativeUpdateFailed)
        #expect(undo.undoActionName == "Typing")
        try await expectEdited(fixture, true, "There is something to undo")
        undo.undo()
        #expect(fixture.model.liveEdit == nil)
        #expect(fixture.view.liveTextView == nil)
        #expect(session.pendingTextUndo == nil)
        #expect(fixture.model.statusMessage == Self.discarded)
        #expect(pageText(fixture) == before, "Nothing was applied, so nothing changed")
        #expect(!undo.canUndo, "No applied edit to take back")
        #expect(!undo.canRedo, "Dropped text can't be redone into a closed editor")
        try await settle(undo)
        try await expectEdited(fixture, false)
    }

    @Test("Redo after Undo dropped unapplied text brings nothing back; the applied edit undoes and redoes cleanly")
    func redoAfterDiscardUndo() async throws {
        let fixture = try fixture()
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let undo = try #require(fixture.owner.undoManager)
        let session = try openParagraph("Annotate lets", in: fixture)
        session.text = session.text.replacingOccurrences(of: "Annotate lets", with: "Annotate helps")
        try await settle(undo)
        overflow(session)
        try await settle(undo)
        undo.undo()
        #expect(fixture.model.liveEdit == nil)
        try await settle(undo)
        try await expectEdited(fixture, true, "The applied edit is still there")
        let afterUndo = pageText(fixture)
        #expect(afterUndo?.contains("Annotate helps") == true)
        #expect(!undo.canRedo)
        undo.redo()
        #expect(fixture.model.liveEdit == nil, "The dropped text is not reopened")
        #expect(pageText(fixture) == afterUndo)
        // The applied edit is the next thing to undo, and undoing it returns to the opened state.
        #expect(undo.undoActionName == "Edit Text")
        undo.undo()
        #expect(pageText(fixture)?.contains("Annotate lets") == true)
        try await settle(undo)
        try await expectEdited(fixture, false)
        // Redoing it brings back the applied text, never the dropped text.
        #expect(undo.canRedo)
        undo.redo()
        #expect(pageText(fixture) == afterUndo)
        #expect(fixture.model.pdfDocument?.findString("will not fit", withOptions: []).isEmpty == true)
        try await settle(undo)
        try await expectEdited(fixture, true)
    }

    @Test("Escape on text that never applied returns the document to unedited, with nothing to undo")
    func escapeWithdrawsStepAndEditedState() async throws {
        let fixture = try fixture()
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let undo = try #require(fixture.owner.undoManager)
        let session = try openParagraph("Annotate lets", in: fixture)
        overflow(session)
        try await settle(undo)
        try await expectEdited(fixture, true)
        fixture.model.endLiveTextEditing()
        #expect(fixture.model.liveEdit == nil)
        #expect(session.pendingTextUndo == nil)
        try await settle(undo)
        #expect(!undo.canUndo)
        #expect(!undo.canRedo)
        try await expectEdited(fixture, false)
    }

    @Test("After a save, failing then pressing Escape returns to the saved state; Undo still reverts the applied edit")
    func escapeAfterSaveReturnsToSavedState() async throws {
        let fixture = try fixture()
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let undo = try #require(fixture.owner.undoManager)
        let session = try openParagraph("Annotate lets", in: fixture)
        session.text = session.text.replacingOccurrences(of: "Annotate lets", with: "Annotate helps")
        try await settle(undo)
        fixture.owner.updateChangeCount(.changeCleared)
        try await expectEdited(fixture, false)
        overflow(session)
        try await settle(undo)
        try await expectEdited(fixture, true)
        fixture.model.endLiveTextEditing()
        try await settle(undo)
        try await expectEdited(fixture, false, "The page is exactly as saved")
        #expect(fixture.model.pdfDocument?.findString("Annotate helps", withOptions: []).count == 1)
        #expect(undo.undoActionName == "Edit Text")
        undo.undo()
        #expect(fixture.model.pdfDocument?.findString("Annotate lets", withOptions: []).count == 1)
        try await settle(undo)
        try await expectEdited(fixture, true, "Undoing past the save point is a change")
    }

    @Test("Text that applies again leaves exactly one Undo, the applied edit, however often it failed")
    func recoveredTextLeavesOneUndo() async throws {
        let fixture = try fixture()
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let undo = try #require(fixture.owner.undoManager)
        let session = try openParagraph("Annotate lets", in: fixture)
        let applied = session.text.replacingOccurrences(of: "Annotate lets", with: "Annotate helps")
        session.text = applied
        try await settle(undo)
        for round in 0..<3 {
            overflow(session)
            try await settle(undo)
            #expect(session.pendingTextUndo != nil, "Round \(round)")
            #expect(undo.undoActionName == "Typing")
            session.text = applied
            try await settle(undo)
            #expect(!session.nativeUpdateFailed)
            #expect(session.pendingTextUndo == nil)
            #expect(undo.undoActionName == "Edit Text")
        }
        try await expectEdited(fixture, true)
        undo.undo()
        #expect(fixture.model.liveEdit == nil)
        #expect(fixture.model.pdfDocument?.findString("Annotate lets", withOptions: []).count == 1)
        #expect(!undo.canUndo, "No empty steps were left behind")
        try await settle(undo)
        try await expectEdited(fixture, false)
    }

    @Test("Text that keeps failing offers one Undo step, and one Undo drops it")
    func repeatedFailureOffersOneStep() async throws {
        let fixture = try fixture()
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let undo = try #require(fixture.owner.undoManager)
        let session = try openParagraph("Annotate lets", in: fixture)
        overflow(session)
        try await settle(undo)
        let step = try #require(session.pendingTextUndo)
        for _ in 0..<3 {
            session.text += " And more text that still does not fit."
            try await settle(undo)
            #expect(session.nativeUpdateFailed)
            #expect(session.pendingTextUndo === step)
        }
        undo.undo()
        #expect(fixture.model.liveEdit == nil)
        #expect(!undo.canUndo)
        try await settle(undo)
        try await expectEdited(fixture, false)
    }

    @Test("Escape repairs a half-typed font size; when that size no longer fits, the edit ends without it and leaves no Undo")
    func escapeNormalizesFontSizeThenFails() async throws {
        let fixture = try fixture()
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let undo = try #require(fixture.owner.undoManager)
        let before = pageText(fixture)
        let session = try openParagraph("Annotate lets", in: fixture)
        session.fontSize = 999
        try await settle(undo)
        #expect(!session.fontSizeIsValid)
        #expect(!session.nativeUpdateFailed, "A half-typed size is not applied")
        #expect(!undo.canUndo)
        // One key event: the repair fails, and the edit ends, within it.
        fixture.model.endLiveTextEditing()
        #expect(session.fontSize == 144, "Repaired to the largest size")
        #expect(session.nativeUpdateFailed, "…which does not fit")
        #expect(fixture.model.liveEdit == nil)
        #expect(fixture.view.liveTextView == nil)
        #expect(fixture.model.statusMessage == Self.discarded)
        #expect(session.pendingTextUndo == nil)
        #expect(pageText(fixture) == before)
        try await settle(undo)
        #expect(!undo.canUndo, "No empty Undo Typing is left behind")
        try await expectEdited(fixture, false, "Nothing was applied")
    }

    @Test("Closing the Edit inspector after a repaired size fails leaves no Undo and an unedited document")
    func closeNormalizesFontSizeThenFails() async throws {
        let fixture = try fixture()
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let undo = try #require(fixture.owner.undoManager)
        let session = try openParagraph("Annotate lets", in: fixture)
        session.fontSize = 500
        try await settle(undo)
        fixture.model.closeActiveTool()
        #expect(fixture.model.liveEdit == nil)
        #expect(fixture.model.activeTool == nil)
        #expect(fixture.model.statusMessage == Self.discarded)
        try await settle(undo)
        #expect(!undo.canUndo)
        try await expectEdited(fixture, false)
    }

    @Test("Closing the Edit inspector keeps text that was applied and leaves Edit")
    func closeKeepsAppliedText() throws {
        let fixture = try fixture()
        defer { fixture.model.discardPendingLiveText(); fixture.window.close() }
        let session = try openParagraph("Annotate lets", in: fixture)
        session.text = session.text.replacingOccurrences(of: "Annotate lets", with: "Annotate helps")
        session.fontSize = 0
        fixture.model.closeActiveTool()
        #expect(session.fontSize == 4)
        #expect(fixture.model.liveEdit == nil)
        #expect(fixture.model.activeTool == nil)
        #expect(fixture.model.statusMessage != Self.discarded)
        #expect(fixture.pdf.findString("Annotate helps", withOptions: []).count == 1)
        // With no edit open, closing just leaves the tool.
        fixture.model.showTool(.edit)
        #expect(fixture.model.activeTool == .edit)
        fixture.model.closeActiveTool()
        #expect(fixture.model.activeTool == nil)
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
