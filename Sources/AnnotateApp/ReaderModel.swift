import AnnotateCore
import AppKit
import Observation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class ReaderModel {
    var pdfDocument: PDFDocument?
    var markers: [PDFMarker] = []
    var filter: MarkerFilter = .all
    var query = "" { didSet { scheduleSearch() } }
    var searchResults: [SearchHit] = []
    var isSearching = false
    var sidebarVisible = true
    var inspectorVisible = false
    var draft: MarkerDraft?
    var selectedMarkerID: UUID?
    var pageNumber = 1
    var pageCount = 0
    var errorMessage: String?
    var fileName = "Annotate"
    var canEdit = false
    var searchFocusRequest = 0
    var statusMessage = ""
    @ObservationIgnored weak var owner: AnnotateDocument?
    @ObservationIgnored weak var pdfView: SelectionPDFView?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var initialDraftSignature = ""
    @ObservationIgnored var suppressSelection = false

    var markerCount: Int { markers.count }
    var filteredMarkers: [PDFMarker] { markers.filter { filter.matches($0) } }
    var hasDraftChanges: Bool { draft != nil && draftSignature != initialDraftSignature }
    private var draftSignature: String {
        guard let draft else { return "" }
        return "\(draft.categories.map(\.rawValue).sorted())|\(draft.color)|\(draft.icon)|\(draft.note)|\(draft.question)"
    }

    func load(_ document: PDFDocument, owner: AnnotateDocument) {
        self.owner = owner
        pdfDocument = document
        MarkerCodec.refreshAppearance(in: document)
        markers = MarkerCodec.markers(in: document)
        pageCount = document.pageCount
        fileName = owner.displayName ?? "Untitled PDF"
        canEdit = !document.isLocked && document.allowsCommenting
    }

    func openDocument() { NSDocumentController.shared.openDocument(nil) }
    func openSample() {
        let doc = AnnotateDocument()
        doc.model.load(SamplePDF.make(), owner: doc)
        doc.fileType = "com.adobe.pdf"
        doc.model.fileName = "A field guide to thoughtful reading"
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
    }
    func saveDocument() {
        if hasDraftChanges { saveDraft() }
        guard !hasDraftChanges else { return }
        owner?.save(nil)
    }
    func showSearch() { sidebarVisible = true; searchFocusRequest += 1 }
    func setFilter(_ value: MarkerFilter) { filter = value; query = ""; sidebarVisible = true }

    func captureSelection(_ selection: PDFSelection) {
        guard !suppressSelection, canEdit, let document = pdfDocument,
              let quote = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty else { return }
        guard !hasDraftChanges else { inspectorVisible = true; return }
        let regions = MarkerCodec.regions(for: selection, in: document)
        guard !regions.isEmpty else { return }
        draft = MarkerDraft(quote: quote, regions: regions)
        initialDraftSignature = draftSignature
        inspectorVisible = true
    }

    func beginPageMarker() {
        guard canEdit, !hasDraftChanges, let view = pdfView, let page = view.currentPage,
              let document = pdfDocument else { inspectorVisible = draft != nil; return }
        let index = document.index(for: page)
        let visible = view.convert(view.bounds, to: page).intersection(page.bounds(for: .cropBox))
        let box = visible.isNull ? page.bounds(for: .cropBox) : visible
        let region = PageRegion(pageIndex: index, bounds: CGRect(x: box.minX + 20, y: box.maxY - 38, width: 20, height: 20))
        draft = MarkerDraft(categories: [.revisit], icon: "bookmark.fill", quote: "", regions: [region])
        initialDraftSignature = draftSignature
        inspectorVisible = true
    }

    func edit(_ marker: PDFMarker) {
        guard !hasDraftChanges else { inspectorVisible = true; return }
        selectedMarkerID = marker.id
        draft = MarkerDraft(id: marker.id, categories: marker.categories, color: Color(nsColor: marker.color.nsColor),
                            icon: marker.icon, quote: marker.quote, note: marker.note, question: marker.question,
                            regions: marker.regions, isEditing: true)
        initialDraftSignature = draftSignature
        inspectorVisible = true
    }
    func saveDraft() {
        guard let draft, let document = pdfDocument, canEdit else { return }
        var categories = draft.categories
        if !draft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { categories.insert(.note) }
        if !draft.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { categories.insert(.question) }
        if categories.isEmpty { categories.insert(.important) }
        let rgb = NSColor(draft.color).usingColorSpace(.sRGB) ?? .systemYellow
        let previous = markers.first { $0.id == draft.id }
        let marker = PDFMarker(id: draft.id, categories: categories,
            color: MarkerColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent),
            icon: draft.icon, quote: draft.quote, note: draft.note, question: draft.question,
            regions: draft.regions, createdAt: previous?.createdAt ?? Date())
        do {
            try MarkerCodec.apply(marker, to: document)
            registerUndo(previous: previous, current: marker)
            refreshMarkers()
            owner?.updateChangeCount(.changeDone)
            selectedMarkerID = marker.id
            statusMessage = previous == nil ? "Marker added" : "Marker updated"
            cancelDraft()
        } catch { errorMessage = error.localizedDescription }
    }
    func cancelDraft() {
        draft = nil; inspectorVisible = false
        suppressSelection = true
        pdfView?.clearSelection()
        suppressSelection = false
    }
    func delete(_ marker: PDFMarker) {
        guard let document = pdfDocument, canEdit else { return }
        MarkerCodec.remove(id: marker.id, from: document)
        registerUndo(previous: marker, current: nil)
        if draft?.id == marker.id { cancelDraft() }
        refreshMarkers()
        owner?.updateChangeCount(.changeDone)
    }
    private func registerUndo(previous: PDFMarker?, current: PDFMarker?) {
        owner?.undoManager?.registerUndo(withTarget: self) { target in
            target.restore(previous, replacing: current)
        }
        owner?.undoManager?.setActionName(current == nil ? "Delete Marker" : previous == nil ? "Add Marker" : "Edit Marker")
    }
    private func restore(_ marker: PDFMarker?, replacing current: PDFMarker?) {
        guard let document = pdfDocument else { return }
        do {
            if let marker { try MarkerCodec.apply(marker, to: document) }
            else if let current { MarkerCodec.remove(id: current.id, from: document) }
            registerUndo(previous: current, current: marker)
            refreshMarkers()
            if let draft, draft.id == (marker?.id ?? current?.id) { cancelDraft() }
        } catch { errorMessage = error.localizedDescription }
    }
    private func refreshMarkers() {
        pdfView?.closeAnnotationPopover()
        guard let document = pdfDocument else { return }
        markers = MarkerCodec.markers(in: document)
        pdfView?.documentView?.needsDisplay = true
        pdfView?.needsDisplay = true
    }

    func jump(to marker: PDFMarker) {
        guard let document = pdfDocument, let region = marker.regions.first,
              let page = document.page(at: region.pageIndex), let view = pdfView else { return }
        selectedMarkerID = marker.id
        suppressSelection = true
        view.clearSelection()
        view.go(to: region.bounds.insetBy(dx: -24, dy: -50), on: page)
        suppressSelection = false
        pageNumber = region.pageIndex + 1
    }
    func jump(to hit: SearchHit) {
        guard let view = pdfView else { return }
        suppressSelection = true
        view.setCurrentSelection(hit.selection, animate: true)
        view.go(to: hit.selection)
        suppressSelection = false
        pageNumber = hit.pageIndex + 1
    }
    func navigateMarker(_ delta: Int) {
        let items = filteredMarkers
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedMarkerID }
        let index = current.map { ($0 + delta % items.count + items.count) % items.count } ?? (delta < 0 ? items.count - 1 : 0)
        jump(to: items[index])
    }
    func zoomIn() { pdfView?.zoomIn(nil) }
    func zoomOut() { pdfView?.zoomOut(nil) }
    func fitPage() { pdfView?.autoScales = true }
    func goToPage(_ number: Int) {
        guard let document = pdfDocument, number >= 1, number <= document.pageCount,
              let page = document.page(at: number - 1) else { return }
        pdfView?.go(to: page); pageNumber = number
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchResults = []
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, let document = pdfDocument else { isSearching = false; return }
        isSearching = true
        searchTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            guard let self else { return }
            for pageIndex in 0..<document.pageCount {
                guard !Task.isCancelled else { return }
                if let page = document.page(at: pageIndex), let text = page.string {
                    let nsText = text as NSString
                    var cursor = 0
                    while cursor < nsText.length {
                        let match = nsText.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: cursor, length: nsText.length - cursor))
                        guard match.location != NSNotFound, match.length > 0 else { break }
                        if let selection = page.selection(for: match) {
                            let start = max(0, match.location - 65), end = min(nsText.length, NSMaxRange(match) + 100)
                            let safeRange = nsText.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
                            let context = nsText.substring(with: safeRange).replacingOccurrences(of: "\n", with: " ")
                            var snippet = AttributedString((start > 0 ? "…" : "") + context + (end < nsText.length ? "…" : ""))
                            if let range = snippet.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                                snippet[range].font = .body.bold()
                            }
                            self.searchResults.append(SearchHit(pageIndex: pageIndex, snippet: snippet, selection: selection))
                        }
                        cursor = NSMaxRange(match)
                        if cursor % 20 == 0 { await Task.yield() }
                        guard !Task.isCancelled else { return }
                    }
                }
                await Task.yield()
            }
            self.isSearching = false
        }
    }

    func exportDocument() {
        if hasDraftChanges { saveDraft() }
        guard !hasDraftChanges else { return }
        guard let document = pdfDocument, let window = owner?.windowForSheet else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = ((fileName as NSString).deletingPathExtension) + " — Annotated.pdf"
        panel.message = "Creates a sharing copy with permanent highlights and markers, plus an index containing your full notes and questions."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if url.standardizedFileURL == self.owner?.fileURL?.standardizedFileURL {
                self.errorMessage = "Choose a different filename for the flattened sharing copy so your editable markers stay available."
                return
            }
            do {
                let data = try PDFExporter.flattenedData(document: document, markers: self.markers)
                try data.write(to: url, options: .atomic)
                self.statusMessage = "Exported \(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { self.errorMessage = error.localizedDescription }
        }
    }
    func printDocument() {
        if hasDraftChanges { saveDraft() }
        guard !hasDraftChanges else { return }
        owner?.printDocument(nil)
    }
}
