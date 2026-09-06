import AnnotateCore
import AppKit
import PDFKit
import Testing
@testable import AnnotateApp

@Suite("Document workspace workflows", .serialized)
@MainActor
struct WorkspaceTests {
    func document() -> AnnotateDocument {
        _ = NSApplication.shared
        let result = AnnotateDocument()
        result.model.load(SamplePDF.make(), owner: result)
        result.fileType = "com.adobe.pdf"
        return result
    }

    @Test("Failed multi-step mutations leave the current document untouched")
    func transactionRollback() throws {
        let owner = document()
        let original = try #require(owner.model.pdfDocument)
        owner.model.mutatePDF("Fail") { working in
            working.removePage(at: 0)
            throw PDFContentError.invalidArea
        }
        #expect(owner.model.pdfDocument === original)
        #expect(owner.model.pageCount == 4)
        #expect(owner.model.errorMessage != nil)
        #expect(!owner.isDocumentEdited)
    }

    @Test("Workspace undo and redo restore complete PDF snapshots")
    func snapshotUndo() async throws {
        let owner = document(), model = owner.model
        let undo = try #require(owner.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        model.mutatePDF("Rotate Page") { $0.page(at: 0)?.rotation = 90 }
        undo.endUndoGrouping()
        #expect(model.pdfDocument?.page(at: 0)?.rotation == 90)
        try await Task.sleep(for: .milliseconds(60))
        #expect(owner.isDocumentEdited)
        undo.undo()
        #expect(model.pdfDocument?.page(at: 0)?.rotation == 0)
        undo.redo()
        #expect(model.pdfDocument?.page(at: 0)?.rotation == 90)
    }

    @Test("Live text changes are in the PDF immediately and survive save/reopen with undo")
    func liveText() throws {
        let owner = document(), model = owner.model
        let original = try #require(model.pdfDocument?.string)
        let undo = try #require(owner.undoManager)
        undo.groupsByEvent = false
        model.activeTool = .edit
        model.toolSelection = PageRegion(pageIndex: 0, bounds: CGRect(x: 60, y: 80, width: 450, height: 80))
        undo.beginUndoGrouping()
        model.beginLiveText(replacingSelection: false)
        undo.endUndoGrouping()
        let live = try #require(model.liveEdit)
        live.text = "Realtime edit 734"
        live.fontSize = 22
        let pdf = try #require(model.pdfDocument)
        #expect(!live.nativeUpdateFailed)
        let selection = try #require(pdf.findString("Realtime edit 734", withOptions: []).first)
        let font = try #require(selection.attributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(abs(font.pointSize - 22) < 0.01)
        #expect(pdf.page(at: live.pageIndex)?.annotations.isEmpty == true)
        #expect(normalized((pdf.string ?? "").replacingOccurrences(of: "Realtime edit 734", with: "")) == normalized(original))
        let bytes = try owner.data(ofType: "com.adobe.pdf")
        let reopened = try #require(PDFDocument(data: bytes))
        let restored = try #require(reopened.findString("Realtime edit 734", withOptions: []).first)
        let restoredFont = try #require(restored.attributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(abs(restoredFont.pointSize - 22) < 0.01)
        #expect(reopened.page(at: live.pageIndex)?.annotations.isEmpty == true)
        #expect(normalized((reopened.string ?? "").replacingOccurrences(of: "Realtime edit 734", with: "")) == normalized(original))
        undo.undo()
        #expect(model.liveEdit == nil)
        #expect(model.pdfDocument?.page(at: 0)?.annotations.isEmpty == true)
        #expect(model.pdfDocument?.string == original)
        undo.redo()
        #expect(model.pdfDocument?.findString("Realtime edit 734", withOptions: []).count == 1)
        #expect(model.pdfDocument?.page(at: 0)?.annotations.isEmpty == true)
    }

    @Test("Selected original text is replaced natively without removing surrounding paragraphs")
    func existingNativeText() throws {
        let owner = document(), model = owner.model
        let source = try PDFConversion.textDocument(NSAttributedString(string: "BeforeSentinel remains.\nReplace this phrase\nAfterSentinel remains.",
            attributes: [.font: try #require(NSFont(name: "Helvetica", size: 16))]))
        model.load(source, owner: owner)
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 900))
        view.document = source; view.model = model; model.pdfView = view
        let selected = try #require(source.findString("Replace this phrase", withOptions: []).first)
        view.setCurrentSelection(selected, animate: false)
        model.beginLiveText(replacingSelection: true)
        let session = try #require(model.liveEdit)
        #expect(session.isExistingContent)
        session.bounds = CGRect(x: session.bounds.minX, y: session.bounds.maxY - 45, width: session.bounds.width, height: 45)
        session.updateAttributedText(NSAttributedString(string: "Revised phrase", attributes: [
            .font: try #require(NSFont(name: "Helvetica-Bold", size: 18)), .foregroundColor: NSColor.blue
        ]), selectedRange: NSRange(location: 0, length: 0))
        #expect(!session.nativeUpdateFailed)
        #expect(model.finishLiveText())
        let reopened = try #require(PDFDocument(data: owner.data(ofType: "com.adobe.pdf")))
        #expect(reopened.findString("Replace this phrase", withOptions: []).isEmpty)
        #expect(reopened.findString("BeforeSentinel remains.", withOptions: []).count == 1)
        #expect(reopened.findString("AfterSentinel remains.", withOptions: []).count == 1)
        #expect(reopened.page(at: 0)?.annotations.isEmpty == true)
        let revised = try #require(reopened.findString("Revised phrase", withOptions: []).first)
        let attributes = try #require(revised.attributedString?.attributes(at: 0, effectiveRange: nil))
        let font = try #require(attributes[.font] as? NSFont)
        #expect(abs(font.pointSize - 18) < 0.01)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        let color = try #require((attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.deviceRGB))
        #expect(color.blueComponent > 0.9 && color.redComponent < 0.1)
    }

    private func normalized(_ value: String) -> String {
        value.filter { !$0.isWhitespace }
    }

    @Test("Tool selection leaves marker drafts intact until explicitly saved")
    func markerDraft() throws {
        let owner = document(), model = owner.model
        let selection = try #require(model.pdfDocument?.findString("attention", withOptions: []).first)
        model.captureSelection(selection)
        model.draft?.note = "Keep this thought"
        model.showTool(.edit)
        #expect(model.markers.first?.note == "Keep this thought")
        #expect(model.activeTool == .edit)
        model.captureSelection(selection)
        #expect(model.draft == nil)
        #expect(model.toolSelection != nil)
    }
}
