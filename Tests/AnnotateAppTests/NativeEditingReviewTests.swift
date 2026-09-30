import AnnotateCore
import AppKit
import CoreText
import PDFKit
import SwiftUI
import Testing
@testable import AnnotateApp

@Suite("Native editing lifecycle review", .serialized)
@MainActor
struct NativeEditingReviewTests {
    @Test("Explicit scan mode turns real transparent OCR into visible native text")
    func scannedOCRVisibility() async throws {
        _ = NSApplication.shared
        let bitmap = try #require(CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 1600,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(NSColor.white.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        bitmap.textPosition = CGPoint(x: 60, y: 270)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "TARGET", attributes: [
            .font: try #require(NSFont(name: "Courier", size: 28)), .foregroundColor: NSColor.black])), bitmap)
        let image = try #require(bitmap.makeImage())
        let data = NSMutableData(); var bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil); context.draw(image, in: bounds); context.endPDFPage(); context.closePDF()
        let scan = try #require(PDFDocument(data: data as Data))
        let recognized = try await PDFOCR.recognize(document: scan, options: PDFOCROptions(languages: ["en-US"]))
        let pdf = try #require(PDFDocument(data: recognized.data))
        let owner = AnnotateDocument(); owner.model.load(pdf, owner: owner)
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        view.document = pdf; view.model = owner.model; owner.model.pdfView = view
        let selection = try #require(pdf.findString("TARGET", withOptions: []).first)
        view.setCurrentSelection(selection, animate: false)
        owner.model.beginLiveText(replacingSelection: true)
        let session = try #require(owner.model.liveEdit)
        #expect(session.canEditScannedText)
        #expect(session.color.alphaComponent == 1)
        owner.model.enableScannedTextEditing()
        #expect(!session.nativeUpdateFailed)
        session.text = "EDITED"
        #expect(!session.nativeUpdateFailed)
        let reopened = try #require(PDFDocument(data: owner.data(ofType: "com.adobe.pdf")))
        #expect(reopened.findString("TARGET", withOptions: []).isEmpty)
        let edited = try #require(reopened.findString("EDITED", withOptions: []).first)
        let page = try #require(reopened.page(at: 0))
        let pixels = NSBitmapImageRep(cgImage: try PDFConversion.renderedImage(page: page, scale: 1))
        let region = edited.bounds(for: page)
        var darkPixels = 0
        for y in max(0, Int(400 - region.maxY))..<min(400, Int(ceil(400 - region.minY))) {
            for x in max(0, Int(region.minX))..<min(400, Int(ceil(region.maxX))) {
                if let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.redComponent < 0.5 { darkPixels += 1 }
            }
        }
        #expect(darkPixels > 30)
        withExtendedLifetime(view) {}
    }

    @Test("Native typing retains the field, focus, caret and styles through document replacement")
    func canvasCaretAndFocus() throws {
        let fixture = try makeFixture()
        defer { fixture.window.close() }
        let model = fixture.owner.model
        model.beginLiveText(replacingSelection: false)
        let session = try #require(model.liveEdit)
        // New text starts in the nearest text's size and keeps it through every keystroke.
        let startingSize = session.font.pointSize
        let field = try #require(fixture.view.liveTextView)
        fixture.window.makeFirstResponder(field)
        field.insertText("First", replacementRange: NSRange(location: 0, length: field.string.utf16.count))
        #expect(!session.nativeUpdateFailed)
        #expect(fixture.view.liveTextView === field)
        #expect(fixture.window.firstResponder === field)
        #expect(field.selectedRange() == NSRange(location: 5, length: 0))
        field.insertText(" again", replacementRange: field.selectedRange())
        #expect(session.text == "First again")
        #expect(field.selectedRange() == NSRange(location: 11, length: 0))
        #expect(model.pdfDocument?.findString("First again", withOptions: []).count == 1)
        #expect(session.font.pointSize == startingSize)
    }

    @Test("Sidebar typing and document undo restore a consistent saved PDF state")
    func sidebarUndo() async throws {
        let fixture = try makeFixture()
        defer { fixture.window.close() }
        let model = fixture.owner.model
        model.beginLiveText(replacingSelection: false)
        let session = try #require(model.liveEdit)
        session.text = "Before sidebar"
        let host = NSHostingView(rootView: SidebarRichTextEditor(session: session))
        host.frame = CGRect(x: 0, y: 0, width: 350, height: 200)
        fixture.window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let field = try #require(descendants(host).compactMap { $0 as? NSTextView }.first)
        let undo = try #require(fixture.owner.undoManager)
        undo.removeAllActions(); undo.groupsByEvent = false
        session.needsUndoCheckpoint = true
        fixture.window.makeFirstResponder(field)
        undo.beginUndoGrouping()
        field.insertText("After sidebar", replacementRange: NSRange(location: 0, length: field.string.utf16.count))
        undo.endUndoGrouping()
        await Task.yield()
        #expect(model.pdfDocument?.findString("After sidebar", withOptions: []).count == 1)
        #expect(fixture.window.firstResponder === field)
        undo.undo()
        #expect(model.liveEdit == nil)
        #expect(model.pdfDocument?.findString("Before sidebar", withOptions: []).count == 1)
        #expect(model.pdfDocument?.findString("After sidebar", withOptions: []).isEmpty == true)
        undo.redo()
        #expect(model.pdfDocument?.findString("After sidebar", withOptions: []).count == 1)
    }

    private func makeFixture() throws -> (owner: AnnotateDocument, view: SelectionPDFView, window: NSWindow) {
        _ = NSApplication.shared
        let owner = AnnotateDocument()
        owner.model.load(SamplePDF.make(), owner: owner)
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 750))
        view.document = owner.model.pdfDocument; view.model = owner.model; owner.model.pdfView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        owner.addWindowController(NSWindowController(window: window))
        view.layoutDocumentView(); view.layoutSubtreeIfNeeded()
        owner.model.toolSelection = PageRegion(pageIndex: 0, bounds: CGRect(x: 50, y: 80, width: 400, height: 70))
        return (owner, view, window)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
