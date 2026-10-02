import AnnotateCore
import AppKit
import PDFKit
import SwiftUI
import Testing
@testable import AnnotateApp

@Suite("Reader workflows", .serialized)
@MainActor
struct ReaderModelTests {
    @Test("A selected passage saves combined categories, custom color, note and question")
    func saveSelectedPassage() async throws {
        let document = makeDocument()
        let model = document.model
        let selection = try #require(model.pdfDocument?.findString("attention", withOptions: .caseInsensitive).first)
        model.captureSelection(selection)
        let draft = try #require(model.draft)
        #expect(model.inspectorVisible)
        #expect(!model.hasDraftChanges)
        draft.categories = [.important, .revisit]
        draft.note = "Compare the source evidence."
        draft.question = "Which result is repeatable?"
        draft.color = Color(red: 0.2, green: 0.4, blue: 0.8)
        draft.icon = "flag.fill"
        #expect(model.hasDraftChanges)
        model.saveDraft()
        let marker = try #require(model.markers.first)
        #expect(marker.categories == [.important, .revisit, .question, .note])
        #expect(marker.note == "Compare the source evidence.")
        #expect(marker.question == "Which result is repeatable?")
        #expect(marker.icon == "flag.fill")
        #expect(abs(marker.color.red - 0.2) < 0.001)
        #expect(abs(marker.color.green - 0.4) < 0.001)
        #expect(abs(marker.color.blue - 0.8) < 0.001)
        #expect(marker.quote.lowercased() == "attention")
        #expect(model.draft == nil && !model.inspectorVisible)
        try await Task.sleep(for: .milliseconds(60))
        #expect(document.isDocumentEdited)
        let data = try document.data(ofType: "com.adobe.pdf")
        let reopened = try #require(PDFDocument(data: data))
        #expect(MarkerCodec.markers(in: reopened) == [marker])
    }

    @Test("A changed draft is preserved when another passage is selected")
    func selectionDoesNotDiscardDraft() throws {
        let document = makeDocument()
        let model = document.model
        let matches = try #require(model.pdfDocument).findString("attention", withOptions: .caseInsensitive)
        model.captureSelection(try #require(matches.first))
        let draft = try #require(model.draft)
        draft.note = "Keep this unsaved thought."
        model.captureSelection(try #require(matches.last))
        #expect(model.draft === draft)
        #expect(model.draft?.note == "Keep this unsaved thought.")
        model.cancelDraft()
        #expect(model.draft == nil)
        #expect(model.markers.isEmpty)
        #expect(!document.isDocumentEdited)
    }

    @Test("Add, edit and delete can each be undone and redone")
    func undoRedo() throws {
        let document = makeDocument()
        let model = document.model
        let undo = try #require(document.undoManager)
        undo.groupsByEvent = false
        let selection = try #require(model.pdfDocument?.findString("attention", withOptions: .caseInsensitive).first)
        model.captureSelection(selection)
        model.draft?.note = "Original note"
        undo.beginUndoGrouping(); model.saveDraft(); undo.endUndoGrouping()
        let original = try #require(model.markers.first)
        #expect(undo.canUndo)
        undo.undo()
        #expect(model.markers.isEmpty)
        undo.redo()
        #expect(model.markers == [original])
        model.edit(original)
        model.draft?.note = "Revised note"
        undo.beginUndoGrouping(); model.saveDraft(); undo.endUndoGrouping()
        let revised = try #require(model.markers.first)
        #expect(revised.note == "Revised note")
        #expect(revised.createdAt == original.createdAt)
        undo.undo()
        #expect(model.markers == [original])
        undo.redo()
        #expect(model.markers == [revised])
        undo.beginUndoGrouping(); model.delete(revised); undo.endUndoGrouping()
        #expect(model.markers.isEmpty)
        undo.undo()
        #expect(model.markers == [revised])
        undo.redo()
        #expect(model.markers.isEmpty)
        #expect(model.errorMessage == nil)
    }

    @Test("Search lists every hit with readable context and correct page locations")
    func contextualSearch() async throws {
        let document = makeDocument()
        let model = document.model
        model.query = "ATTENTION"
        try await waitForSearch(model)
        let pdf = try #require(model.pdfDocument)
        let expected = pdf.findString("attention", withOptions: .caseInsensitive)
        #expect(model.searchResults.count == expected.count)
        #expect(Set(model.searchResults.map(\.pageIndex)) == [0, 1, 2, 3])
        for hit in model.searchResults {
            let text = String(hit.snippet.characters)
            #expect(text.lowercased().contains("attention"))
            #expect(text.count > "attention".count)
            #expect(!text.contains("\n"))
            #expect(hit.selection?.string?.lowercased() == "attention")
            #expect(hit.selection?.pages.first === pdf.page(at: hit.pageIndex))
            #expect(hit.snippet.runs.contains { $0.font != nil })
        }
    }

    @Test("A replacement query cancels stale results and clearing search stays empty")
    func searchCancellation() async throws {
        let document = makeDocument()
        let model = document.model
        model.query = "attention"
        model.query = "specific question"
        try await waitForSearch(model)
        #expect(!model.searchResults.isEmpty)
        #expect(model.searchResults.allSatisfy { $0.selection?.string?.lowercased() == "specific question" })
        model.query = "attention"
        model.query = " \n "
        #expect(!model.isSearching)
        #expect(model.searchResults.isEmpty)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.searchResults.isEmpty)
        #expect(!model.isSearching)
        model.query = "no such phrase exists in this tour"
        try await waitForSearch(model)
        #expect(model.searchResults.isEmpty)
    }

    @Test("Category filters include attached notes and questions and reset search")
    func categoryFilters() throws {
        let document = makeDocument()
        let model = document.model
        model.captureSelection(try #require(model.pdfDocument?.findString("attention", withOptions: .caseInsensitive).first))
        model.draft?.categories = [.important, .revisit]
        model.draft?.note = "One note"
        model.draft?.question = "One question?"
        model.saveDraft()
        for filter in MarkerFilter.allCases {
            model.query = "attention"
            model.setFilter(filter)
            #expect(model.query.isEmpty)
            #expect(model.filteredMarkers.count == 1)
            #expect(model.sidebarVisible)
        }
    }

    @Test("A page without selectable text can receive a navigable location marker")
    func pageLocationMarker() throws {
        _ = NSApplication.shared
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
        let pdf = PDFDocument()
        pdf.insert(page, at: 0)
        let document = AnnotateDocument()
        document.model.load(pdf, owner: document)
        let model = document.model
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 700))
        view.document = pdf
        view.go(to: page)
        model.pdfView = view
        #expect((page.string ?? "").isEmpty)
        model.beginPageMarker()
        let draft = try #require(model.draft)
        #expect(draft.quote.isEmpty)
        #expect(draft.categories == [.revisit])
        draft.note = "Return to this image."
        model.saveDraft()
        let marker = try #require(model.markers.first)
        #expect(marker.pageIndex == 0)
        #expect(marker.quote.isEmpty)
        #expect(marker.note == "Return to this image.")
        let region = try #require(marker.regions.first)
        #expect(page.bounds(for: .cropBox).contains(region.bounds))
        model.jump(to: marker)
        #expect(model.selectedMarkerID == marker.id)
        #expect(model.pageNumber == 1)
    }

    @Test("Page navigation rejects out-of-range requests and marker traversal wraps")
    func navigation() throws {
        let document = makeDocument()
        let model = document.model
        let pdf = try #require(model.pdfDocument)
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 700))
        view.document = pdf
        model.pdfView = view
        let matches = pdf.findString("attention", withOptions: .caseInsensitive)
        model.captureSelection(try #require(matches.first)); model.saveDraft()
        model.captureSelection(try #require(matches.last)); model.saveDraft()
        #expect(model.markers.count == 2)
        let first = try #require(model.markers.first)
        let last = try #require(model.markers.last)
        model.selectedMarkerID = nil
        model.navigateMarker(1)
        #expect(model.selectedMarkerID == first.id && model.pageNumber == 1)
        model.navigateMarker(-1)
        #expect(model.selectedMarkerID == last.id && model.pageNumber == 4)
        model.navigateMarker(1)
        #expect(model.selectedMarkerID == first.id && model.pageNumber == 1)
        model.goToPage(3)
        #expect(model.pageNumber == 3)
        model.goToPage(0)
        #expect(model.pageNumber == 3)
        model.goToPage(5)
        #expect(model.pageNumber == 3)
        model.goToPage(Int.min)
        #expect(model.pageNumber == 3)
        model.goToPage(Int.max)
        #expect(model.pageNumber == 3)
    }

    @Test("Search finds saved text boxes and form values, navigates their areas, and refreshes after native edits")
    func liveContentSearch() async throws {
        let source = SamplePDF.make()
        let term = "Canvas search 932"
        let area = PageRegion(pageIndex: 3, bounds: CGRect(x: 70, y: 100, width: 260, height: 30))
        try PDFContentEditor.addText(term, in: area, document: source, font: .systemFont(ofSize: 12), color: .black)
        try PDFFormEditor.create(in: source, region: PageRegion(pageIndex: 1, bounds: area.bounds), name: "SearchField", kind: .text)
        try PDFFormEditor.fill(in: source, field: #require(PDFFormEditor.fields(in: source).first), value: term)
        let bytes = try #require(source.dataRepresentation())
        let pdf = try #require(PDFDocument(data: bytes))
        let owner = AnnotateDocument(), model = owner.model
        model.load(pdf, owner: owner)
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 700))
        view.document = pdf; view.model = model; model.pdfView = view
        model.query = term
        try await waitForSearch(model)
        #expect(model.searchResults.count == 2)
        #expect(Set(model.searchResults.map(\.pageIndex)) == [1, 3])
        let boxHit = try #require(model.searchResults.first { $0.pageIndex == 3 })
        #expect(boxHit.selection == nil)
        #expect(boxHit.bounds != nil)
        model.jump(to: boxHit)
        #expect(model.pageNumber == 4)
        #expect(view.currentPage === pdf.page(at: 3))
        try PDFFormEditor.fill(in: pdf, field: #require(PDFFormEditor.fields(in: pdf).first), value: "Revised value")
        try await waitForSearch(model)
        #expect(model.searchResults.count == 1)
        #expect(model.searchResults.first?.pageIndex == 3)
        withExtendedLifetime(view) {}
    }

    private func makeDocument() -> AnnotateDocument {
        _ = NSApplication.shared
        let document = AnnotateDocument()
        document.model.load(SamplePDF.make(), owner: document)
        return document
    }

    /// Waits for the search under way to finish. Alone, a search of the four-page tour takes
    /// about a quarter of a second (most of it the typing debounce); in a full run every app
    /// suite shares the main actor and runs in parallel, which has stretched that past a
    /// second. So the deadline only catches a search that never finishes, without measuring
    /// what other tests were doing at the time; the results are what the callers check.
    private func waitForSearch(_ model: ReaderModel) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while model.isSearching && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!model.isSearching, "Search should finish on the four-page tour.")
    }
}
