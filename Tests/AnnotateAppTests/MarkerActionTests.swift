import AnnotateCore
import AppKit
import PDFKit
import Testing
@testable import AnnotateApp

@Suite("Marker actions across workspace tools", .serialized)
@MainActor
struct MarkerActionTests {
    private func fixture() throws -> (AnnotateDocument, PDFMarker) {
        _ = NSApplication.shared
        let owner = AnnotateDocument()
        owner.model.load(SamplePDF.make(), owner: owner)
        let selection = try #require(owner.model.pdfDocument?.findString("attention", withOptions: .caseInsensitive).first)
        owner.model.captureSelection(selection)
        owner.model.draft?.categories = [.important, .revisit]
        owner.model.draft?.note = "Check the original evidence."
        owner.model.draft?.question = "Is the result reproducible?"
        owner.model.saveDraft()
        return (owner, try #require(owner.model.markers.first))
    }

    @Test("Opening a marker from another tool reveals its editor and preserves composable data")
    func opensVisibleMarkerEditor() throws {
        let (owner, marker) = try fixture()
        let model = owner.model
        model.activeTool = .pages
        model.selectingToolArea = true
        model.openMarkerEditor(marker)
        #expect(model.activeTool == nil)
        #expect(!model.selectingToolArea)
        #expect(model.inspectorVisible)
        let draft = try #require(model.draft)
        #expect(draft.id == marker.id && draft.isEditing)
        #expect(draft.categories == [.important, .revisit, .note, .question])
        #expect(draft.quote == marker.quote && draft.regions == marker.regions)
        #expect(draft.note == marker.note && draft.question == marker.question)
        #expect(!model.hasDraftChanges)
    }

    @Test("Pending marker changes survive requests to edit or delete another marker")
    func preservesPendingDraft() throws {
        let (owner, marker) = try fixture()
        let model = owner.model
        let selection = try #require(model.pdfDocument?.findString("questions", withOptions: .caseInsensitive).first)
        model.captureSelection(selection)
        let draft = try #require(model.draft)
        draft.note = "Do not lose this unsaved thought."
        model.activeTool = .forms
        model.openMarkerEditor(marker)
        #expect(model.activeTool == nil && model.inspectorVisible)
        #expect(model.draft === draft)
        model.removeMarkerFromReader(marker)
        #expect(model.markers == [marker])
        #expect(model.draft === draft && model.hasDraftChanges)
        #expect(model.errorMessage?.contains("Save or cancel") == true)
    }

    @Test("Visible delete action clears selection and remains completely undoable")
    func deleteUndo() throws {
        let (owner, marker) = try fixture()
        let model = owner.model
        let undo = try #require(owner.undoManager)
        undo.removeAllActions()
        undo.groupsByEvent = false
        model.selectedMarkerID = marker.id
        undo.beginUndoGrouping()
        model.removeMarkerFromReader(marker)
        undo.endUndoGrouping()
        #expect(model.markers.isEmpty)
        #expect(model.selectedMarkerID == nil)
        #expect(model.statusMessage.contains("Undo"))
        undo.undo()
        #expect(model.markers == [marker])
        let reopened = try #require(model.pdfDocument?.dataRepresentation().flatMap(PDFDocument.init(data:)))
        #expect(MarkerCodec.markers(in: reopened) == [marker])
    }

    @Test("Unapplied native text blocks marker actions without hiding the live editor")
    func preservesUnappliedText() throws {
        let (owner, marker) = try fixture()
        let model = owner.model
        let session = LiveTextEdit(identifier: "pending", pageIndex: 0, text: "Pending", font: .systemFont(ofSize: 14),
                                   color: .black, bounds: CGRect(x: 10, y: 10, width: 100, height: 30))
        session.nativeUpdateFailed = true
        session.nativeFailureMessage = "Text does not fit."
        model.liveEdit = session
        model.activeTool = .edit
        model.openMarkerEditor(marker)
        model.removeMarkerFromReader(marker)
        model.markCurrentPageFromWorkspace()
        #expect(model.liveEdit === session)
        #expect(model.activeTool == .edit)
        #expect(model.draft == nil)
        #expect(model.markers == [marker])
    }

    @Test("Page descriptions deduplicate line regions and retain disjoint page ranges")
    func multiPageDescription() {
        let region: (Int) -> PageRegion = { PageRegion(pageIndex: $0, bounds: CGRect(x: 0, y: 0, width: 10, height: 10)) }
        #expect(MarkerPresentation.pageLabel(regions: [region(2), region(2)]) == "Page 3")
        #expect(MarkerPresentation.pageLabel(regions: [region(5), region(2), region(0), region(1), region(1)]) == "Pages 1–3, 6")
    }
}
