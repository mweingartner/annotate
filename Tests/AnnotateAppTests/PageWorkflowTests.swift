import AnnotateCore
import AppKit
import PDFKit
import Testing
@testable import AnnotateApp

@Suite("Page and form workspace workflows", .serialized)
@MainActor
struct PageWorkflowTests {
    @Test("Page moves update marker navigation and snapshot undo/redo restores exact indexes")
    func pageMoveUndo() throws {
        _ = NSApplication.shared
        let owner = AnnotateDocument()
        owner.model.load(SamplePDF.make(), owner: owner)
        let model = owner.model
        let selection = try #require(model.pdfDocument?.findString("attention", withOptions: .caseInsensitive).first)
        model.captureSelection(selection)
        model.draft?.note = "Move with this page"
        model.saveDraft()
        let original = try #require(model.markers.first)
        let originalRevision = model.documentRevision
        let undo = try #require(owner.undoManager)
        undo.removeAllActions()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        model.movePage(0, to: 3)
        undo.endUndoGrouping()
        #expect(model.markers.first?.pageIndex == 3)
        #expect(model.pageNumber == 4)
        undo.undo()
        #expect(model.markers == [original])
        undo.redo()
        #expect(model.markers.first?.pageIndex == 3)
        #expect(model.documentRevision == originalRevision + 3)
        owner.close()
    }

    @Test("Failed page mutation keeps original PDF and markers")
    func failedMutation() throws {
        _ = NSApplication.shared
        let owner = AnnotateDocument()
        owner.model.load(SamplePDF.make(), owner: owner)
        let model = owner.model
        let original = model.pdfDocument
        model.deletePages(IndexSet(integersIn: 0..<4))
        #expect(model.pdfDocument === original)
        #expect(model.pageCount == 4)
        #expect(model.errorMessage != nil)
        owner.close()
    }

    @Test("Displayed percentage placement respects rotated crop-box origins", arguments: [0, 90, 180, 270])
    func placement(_ angle: Int) throws {
        _ = NSApplication.shared
        let owner = AnnotateDocument()
        let pdf = SamplePDF.make()
        let page = try #require(pdf.page(at: 0))
        page.rotation = angle
        page.setBounds(CGRect(x: 40, y: 50, width: 500, height: 650), for: .cropBox)
        owner.model.load(pdf, owner: owner)
        let region = try #require(owner.model.placementRegion(page: 0, left: 0.1, top: 0.2, width: 0.3, height: 0.1))
        let transform = page.transform(for: .cropBox)
        let visible = page.bounds(for: .cropBox).applying(transform)
        let box = region.bounds.applying(transform)
        #expect(abs(box.minX - (visible.minX + visible.width * 0.1)) < 0.001)
        #expect(abs(box.maxY - (visible.maxY - visible.height * 0.2)) < 0.001)
        #expect(abs(box.width - visible.width * 0.3) < 0.001)
        #expect(abs(box.height - visible.height * 0.1) < 0.001)
        owner.close()
    }
}
