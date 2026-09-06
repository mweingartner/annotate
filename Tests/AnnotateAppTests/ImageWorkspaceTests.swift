import AnnotateCore
import AppKit
import CoreText
import PDFKit
import Testing
@testable import AnnotateApp

@Suite("Existing image workspace", .serialized)
@MainActor
struct ImageWorkspaceTests {
    @Test("Combined native replacement and frame changes save and undo as one action")
    func applyAndUndo() throws {
        _ = NSApplication.shared
        let owner = AnnotateDocument(), source = try fixture()
        owner.model.load(source, owner: owner)
        let model = owner.model, undo = try #require(owner.undoManager)
        let original = try #require(model.imagesOnCurrentPage().first)
        model.selectImage(original)
        let session = try #require(model.imageEdit)
        session.width = 120; session.x = 35; session.y = 60
        session.stageReplacement(try bitmap(color: .blue), name: "Blue.png")
        #expect(session.height == 60)
        #expect(model.hasPendingImageChanges)
        #expect(throws: NSError.self) { try owner.data(ofType: "com.adobe.pdf") }
        undo.removeAllActions(); undo.groupsByEvent = false
        undo.beginUndoGrouping()
        #expect(model.applyImageChanges())
        undo.endUndoGrouping()
        #expect(model.imageEdit == nil)
        let saved = try #require(PDFDocument(data: owner.data(ofType: "com.adobe.pdf")))
        let edited = try PDFNativeImageEditor.images(in: saved, pageIndex: 0)
        #expect(edited.count == 2)
        #expect(edited.contains { $0.bounds == CGRect(x: 35, y: 60, width: 120, height: 60) })
        #expect(saved.findString("Keep this text", withOptions: []).count == 1)
        undo.undo()
        #expect(try model.imagesOnCurrentPage().first?.bounds == original.bounds)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(try model.imagesOnCurrentPage().contains { $0.bounds == CGRect(x: 35, y: 60, width: 120, height: 60) })
        owner.close()
    }

    @Test("Image removal changes only its source invocation and can be undone")
    func removeAndUndo() throws {
        _ = NSApplication.shared
        let owner = AnnotateDocument(), source = try fixture()
        owner.model.load(source, owner: owner)
        let model = owner.model, undo = try #require(owner.undoManager)
        let originalImages = try model.imagesOnCurrentPage()
        model.selectImage(try #require(originalImages.first))
        undo.groupsByEvent = false; undo.beginUndoGrouping()
        #expect(model.removeSelectedImage())
        undo.endUndoGrouping()
        #expect(try model.imagesOnCurrentPage().count == 1)
        #expect(model.pdfDocument?.findString("Keep this text", withOptions: []).count == 1)
        undo.undo()
        #expect(try model.imagesOnCurrentPage().map(\.bounds) == originalImages.map(\.bounds))
        owner.close()
    }

    @Test("Invalid geometry and stale source preserve pending controls without PDF changes")
    func transactionalFailure() throws {
        _ = NSApplication.shared
        let owner = AnnotateDocument(), source = try fixture()
        owner.model.load(source, owner: owner)
        let model = owner.model
        model.selectImage(try #require(model.imagesOnCurrentPage().first))
        let session = try #require(model.imageEdit)
        session.width = -1
        session.stageReplacement(try bitmap(color: .blue), name: "Keep pending.png")
        #expect(!model.applyImageChanges())
        #expect(model.pdfDocument === source)
        #expect(model.imageEdit === session)
        #expect(session.replacementName == "Keep pending.png")
        session.width = 120
        model.showTool(.pages)
        #expect(model.imageEdit === session && model.hasPendingImageChanges)
        let changedData = try #require(source.dataRepresentation())
        let changed = try #require(PDFDocument(data: changedData))
        model.replacePDF(changed, actionName: "Other PDF change")
        #expect(!model.imageEditIsCurrent)
        #expect(!model.applyImageChanges())
        #expect(model.pdfDocument === changed)
        #expect(model.imageEdit === session)
        #expect(model.errorMessage?.contains("PDF changed") == true)
        model.discardImageChanges()
        #expect(!model.hasPendingImageChanges)
        _ = try owner.data(ofType: "com.adobe.pdf")
        owner.close()
    }

    @Test("Changing image selection never discards a pending replacement or marker draft")
    func pendingSelection() throws {
        _ = NSApplication.shared
        let owner = AnnotateDocument(), source = try fixture()
        owner.model.load(source, owner: owner)
        let model = owner.model, images = try model.imagesOnCurrentPage()
        model.selectImage(try #require(images.first))
        let pending = try #require(model.imageEdit)
        pending.stageReplacement(try bitmap(color: .blue), name: "Pending.png")
        model.selectImage(try #require(images.last))
        #expect(model.imageEdit === pending)
        model.discardImageChanges()
        model.activeTool = nil
        model.captureSelection(try #require(source.findString("Keep this text", withOptions: []).first))
        model.draft?.note = "Keep this unsaved marker"
        #expect(model.hasDraftChanges)
        model.selectImage(try #require(images.first))
        #expect(model.imageEdit == nil)
        #expect(model.draft?.note == "Keep this unsaved marker")
        model.cancelDraft()
        let live = LiveTextEdit(identifier: "pending", pageIndex: 0, text: "Unapplied text", font: .systemFont(ofSize: 14),
            color: .black, bounds: CGRect(x: 0, y: 0, width: 30, height: 20))
        live.nativeUpdateFailed = true
        model.liveEdit = live
        model.selectImage(try #require(images.first))
        #expect(model.imageEdit == nil && model.liveEdit === live)
        model.discardPendingLiveText()
        owner.close()
    }

    @Test("Image frame proportions lock in both resize directions and validate finite geometry")
    func frameGeometry() throws {
        let pdf = try fixture(), image = try #require(PDFNativeImageEditor.images(in: pdf, pageIndex: 0).first)
        let session = ImageEditSession(image: image, source: pdf, revision: 0,
            pageBounds: CGRect(x: 0, y: 0, width: 400, height: 400), preview: nil)
        session.width = 160
        #expect(session.height == 80)
        session.height = 30
        #expect(session.width == 60)
        session.keepsAspectRatio = false
        session.width = 110
        #expect(session.height == 30)
        session.keepsAspectRatio = true
        session.height = 60
        #expect(abs(session.width - 220) < 0.001)
        session.x = .nan
        #expect(!session.geometryIsValid)
        session.reset()
        #expect(session.geometryIsValid && !session.hasChanges)
    }

    @Test("Selecting an image navigates to its page and outlines its frame at actual PDF zoom", arguments: [0, 90])
    func selectionOutline(rotation: Int) throws {
        _ = NSApplication.shared
        let owner = AnnotateDocument(), pdf = try fixture()
        let second = try #require(pdf.page(at: 0)?.copy() as? PDFPage)
        second.rotation = rotation
        pdf.insert(second, at: 1)
        owner.model.load(pdf, owner: owner)
        let model = owner.model
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 800))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close(); owner.close() }
        view.document = pdf; view.model = model; model.pdfView = view
        view.autoScales = false; view.scaleFactor = 1.4
        view.layoutDocumentView(); view.layoutSubtreeIfNeeded()
        let image = try #require(PDFNativeImageEditor.images(in: pdf, pageIndex: 1).first)
        model.selectImage(image)
        #expect(model.pageNumber == 2)
        #expect(model.toolSelection == PageRegion(pageIndex: 1, bounds: image.bounds))
        #expect(model.activeTool == .edit)
        let host = try #require(view.documentView)
        let outline = try #require(host.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.lineDashPattern != nil })
        let expected = host.convert(view.convert(image.bounds, from: second), from: view)
        #expect(outline.path?.boundingBoxOfPath == expected)
        #expect(view.currentSelection == nil)
        #expect(model.pdfDocument === pdf)
        let preview = try PDFNativeImageEditor.preview(in: pdf, image: image, maximumDimension: 160)
        #expect(max(preview.width, preview.height) == 160)
    }

    private func fixture() throws -> PDFDocument {
        let data = NSMutableData(), consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        var media = CGRect(x: 0, y: 0, width: 400, height: 400)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        let image = try bitmap(color: .red)
        context.draw(image, in: CGRect(x: 40, y: 70, width: 100, height: 50))
        context.draw(image, in: CGRect(x: 220, y: 200, width: 100, height: 50))
        context.textPosition = CGPoint(x: 40, y: 330)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Keep this text",
            attributes: [.font: NSFont(name: "Helvetica", size: 14)!, .foregroundColor: NSColor.black])), context)
        context.endPDFPage(); context.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }

    private func bitmap(color: NSColor) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        return try #require(context.makeImage())
    }
}
