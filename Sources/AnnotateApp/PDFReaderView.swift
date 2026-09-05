import AppKit
import PDFKit
import SwiftUI

struct PDFReaderView: NSViewRepresentable {
    let model: ReaderModel
    func makeNSView(context: Context) -> SelectionPDFView {
        let view = SelectionPDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        view.backgroundColor = .windowBackgroundColor
        view.minScaleFactor = 0.2
        view.maxScaleFactor = 6
        view.document = model.pdfDocument
        // PDFKit's minimum/maximum assignments disable autoscaling, so enable
        // fit-to-width only after configuring the limits and document.
        view.autoScales = true
        view.model = model
        model.pdfView = view
        view.setAccessibilityLabel("PDF document")
        view.setAccessibilityHelp("Select text to open the annotation panel. Use Add Marker to mark a location without text.")
        NotificationCenter.default.addObserver(view, selector: #selector(SelectionPDFView.pageChanged), name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(view, selector: #selector(SelectionPDFView.selectionChanged), name: .PDFViewSelectionChanged, object: view)
        return view
    }
    func updateNSView(_ view: SelectionPDFView, context: Context) {
        if view.document !== model.pdfDocument { view.document = model.pdfDocument; view.autoScales = true }
    }
    static func dismantleNSView(_ view: SelectionPDFView, coordinator: ()) {
        NotificationCenter.default.removeObserver(view)
        view.selectionTask?.cancel()
        if view.model?.pdfView === view { view.model?.pdfView = nil }
    }
}

@MainActor
final class SelectionPDFView: PDFView {
    weak var model: ReaderModel?
    var selectionTask: Task<Void, Never>?
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        selectionTask?.cancel()
        if let selection = currentSelection { model?.captureSelection(selection) }
    }
    @objc func pageChanged() {
        if let document, let currentPage { model?.pageNumber = document.index(for: currentPage) + 1 }
    }
    @objc func selectionChanged() {
        selectionTask?.cancel()
        guard model?.suppressSelection == false else { return }
        selectionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            while NSEvent.pressedMouseButtons != 0 {
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            }
            guard let self, let selection = self.currentSelection else { return }
            self.model?.captureSelection(selection)
        }
    }
}
