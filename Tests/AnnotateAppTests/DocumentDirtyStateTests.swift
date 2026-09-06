import AnnotateCore
import AppKit
import PDFKit
import Testing
@testable import AnnotateApp

@Suite("Undo and saved document state", .serialized)
@MainActor
struct DocumentDirtyStateTests {
    @Test("Workspace snapshots return clean at the saved undo position")
    func snapshotSavePosition() async throws {
        let owner = document(), model = owner.model
        let undo = try #require(owner.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        model.mutatePDF("First rotation") { $0.page(at: 0)?.rotation = 90 }
        undo.endUndoGrouping()
        try await Task.sleep(for: .milliseconds(60))
        #expect(owner.isDocumentEdited)
        undo.undo()
        try await Task.sleep(for: .milliseconds(60))
        #expect(!owner.isDocumentEdited)
        undo.redo()
        try await Task.sleep(for: .milliseconds(60))
        #expect(owner.isDocumentEdited)
        owner.updateChangeCount(.changeCleared)
        undo.beginUndoGrouping()
        model.mutatePDF("Second rotation") { $0.page(at: 0)?.rotation = 180 }
        undo.endUndoGrouping()
        try await Task.sleep(for: .milliseconds(60))
        #expect(owner.isDocumentEdited)
        undo.undo()
        try await Task.sleep(for: .milliseconds(60))
        #expect(!owner.isDocumentEdited)
        #expect(model.pdfDocument?.page(at: 0)?.rotation == 90)
        undo.undo()
        try await Task.sleep(for: .milliseconds(60))
        #expect(owner.isDocumentEdited)
        undo.redo()
        try await Task.sleep(for: .milliseconds(60))
        #expect(!owner.isDocumentEdited)
    }

    @Test("Marker add, edit and delete preserve dirty state across undo and saving")
    func markerSavePosition() async throws {
        let owner = document(), model = owner.model
        let undo = try #require(owner.undoManager)
        undo.groupsByEvent = false
        let selection = try #require(model.pdfDocument?.findString("attention", withOptions: []).first)
        model.captureSelection(selection)
        model.draft?.note = "Saved marker"
        undo.beginUndoGrouping()
        model.saveDraft()
        undo.endUndoGrouping()
        try await Task.sleep(for: .milliseconds(60))
        #expect(owner.isDocumentEdited)
        undo.undo()
        try await Task.sleep(for: .milliseconds(60))
        #expect(!owner.isDocumentEdited)
        undo.redo()
        try await Task.sleep(for: .milliseconds(60))
        owner.updateChangeCount(.changeCleared)
        let original = try #require(model.markers.first)
        model.edit(original)
        model.draft?.note = "Changed marker"
        undo.beginUndoGrouping()
        model.saveDraft()
        undo.endUndoGrouping()
        try await Task.sleep(for: .milliseconds(60))
        #expect(owner.isDocumentEdited)
        undo.undo()
        try await Task.sleep(for: .milliseconds(60))
        #expect(!owner.isDocumentEdited)
        #expect(model.markers.first?.note == "Saved marker")
        undo.beginUndoGrouping()
        model.delete(original)
        undo.endUndoGrouping()
        try await Task.sleep(for: .milliseconds(60))
        #expect(owner.isDocumentEdited)
        undo.undo()
        try await Task.sleep(for: .milliseconds(60))
        #expect(!owner.isDocumentEdited)
    }

    @Test("Native field undo returns to the saved value and marks older values as changed")
    func nativeSavePosition() async throws {
        let owner = document(), model = owner.model
        let pdf = try #require(model.pdfDocument)
        try PDFFormEditor.create(in: pdf, region: PageRegion(pageIndex: 0, bounds: CGRect(x: 70, y: 100, width: 200, height: 30)), name: "Checkpoint", kind: .text)
        let view = SelectionPDFView()
        view.document = pdf
        view.model = model
        model.pdfView = view
        let annotation = try #require(pdf.page(at: 0)?.annotations.first { $0.fieldName == "Checkpoint" })
        let undo = try #require(owner.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        annotation.widgetStringValue = "Saved value"
        undo.endUndoGrouping()
        try await Task.sleep(for: .milliseconds(60))
        owner.updateChangeCount(.changeCleared)
        undo.beginUndoGrouping()
        annotation.widgetStringValue = "Later value"
        undo.endUndoGrouping()
        try await Task.sleep(for: .milliseconds(60))
        #expect(owner.isDocumentEdited)
        undo.undo()
        try await Task.sleep(for: .milliseconds(60))
        #expect(annotation.widgetStringValue == "Saved value")
        #expect(!owner.isDocumentEdited)
        undo.undo()
        try await Task.sleep(for: .milliseconds(60))
        #expect(owner.isDocumentEdited)
        undo.redo()
        try await Task.sleep(for: .milliseconds(60))
        #expect(!owner.isDocumentEdited)
        withExtendedLifetime(view) {}
    }

    private func document() -> AnnotateDocument {
        _ = NSApplication.shared
        let owner = AnnotateDocument()
        owner.model.load(SamplePDF.make(), owner: owner)
        return owner
    }
}
