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
        if view.document !== model.pdfDocument {
            view.closeAnnotationPopover()
            view.document = model.pdfDocument
            view.autoScales = true
        }
    }
    static func dismantleNSView(_ view: SelectionPDFView, coordinator: ()) {
        NotificationCenter.default.removeObserver(view)
        view.selectionTask?.cancel()
        view.closeAnnotationPopover()
        if view.model?.pdfView === view { view.model?.pdfView = nil }
    }
}

@MainActor
final class SelectionPDFView: PDFView {
    weak var model: ReaderModel?
    var selectionTask: Task<Void, Never>?
    private(set) var annotationPopover: NSPopover?
    private var pendingMarkerHit: MarkerHit?
    private var trackingMarkerClick = false

    // PDFKit installs its own gestures on child views. Route only our explicit
    // tags/badges to this view so annotation popup handling has one event owner.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let nativeHit = super.hitTest(point)
        if let event = NSApp.currentEvent,
           !event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty ||
           event.type == .rightMouseDown || event.type == .otherMouseDown {
            return nativeHit
        }
        guard nativeHit != nil, let superview, let model,
              AnnotationHitTesting.hit(at: convert(point, from: superview), in: self, markers: model.markers) != nil else {
            return nativeHit
        }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func annotationHit(for event: NSEvent) -> MarkerHit? {
        guard event.type == .leftMouseDown, event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
              let model else { return nil }
        return AnnotationHitTesting.hit(at: convert(event.locationInWindow, from: nil), in: self, markers: model.markers)
    }

    override func mouseDown(with event: NSEvent) {
        pendingMarkerHit = annotationHit(for: event)
        trackingMarkerClick = pendingMarkerHit != nil
        if trackingMarkerClick {
            window?.makeFirstResponder(self)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if trackingMarkerClick {
            pendingMarkerHit = nil
        } else {
            super.mouseDragged(with: event)
        }
    }

    func showAnnotation(_ hit: MarkerHit) {
        guard let model, window != nil else { return }
        selectionTask?.cancel()
        closeAnnotationPopover()
        model.selectedMarkerID = hit.marker.id
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: AnnotationPopoverView(
            marker: hit.marker, canEdit: model.canEdit, hasPendingDraft: model.hasDraftChanges,
            edit: { [weak self, weak model] in
                self?.closeAnnotationPopover()
                guard let model, let current = model.markers.first(where: { $0.id == hit.marker.id }) else { return }
                model.edit(current)
            },
            close: { [weak self] in self?.closeAnnotationPopover() }
        ))
        annotationPopover = popover
        popover.show(relativeTo: hit.anchor.intersection(bounds), of: self, preferredEdge: .maxX)
    }

    func closeAnnotationPopover() {
        annotationPopover?.close()
        annotationPopover = nil
    }

    override func mouseUp(with event: NSEvent) {
        if trackingMarkerClick {
            trackingMarkerClick = false
            let hit = pendingMarkerHit
            pendingMarkerHit = nil
            if let hit, let model,
               AnnotationHitTesting.hit(at: convert(event.locationInWindow, from: nil), in: self, markers: model.markers)?.marker.id == hit.marker.id {
                showAnnotation(hit)
            }
            return
        }
        super.mouseUp(with: event)
        selectionTask?.cancel()
        if let selection = currentSelection { model?.captureSelection(selection) }
    }
    @objc func pageChanged() {
        closeAnnotationPopover()
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
