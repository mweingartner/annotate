import AppKit
import AnnotateCore
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
        NotificationCenter.default.addObserver(view, selector: #selector(SelectionPDFView.refreshEditorGeometry), name: .PDFViewScaleChanged, object: view)
        return view
    }
    func updateNSView(_ view: SelectionPDFView, context: Context) {
        if view.document !== model.pdfDocument {
            view.closeAnnotationPopover()
            view.document = model.pdfDocument
            view.autoScales = true
        }
        view.refreshLiveEditor()
        view.updateAreaOutline()
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
    weak var model: ReaderModel? {
        didSet {
            NotificationCenter.default.removeObserver(self, name: .PDFViewDocumentChanged, object: self)
            NotificationCenter.default.addObserver(self, selector: #selector(nativeDocumentChanged), name: .PDFViewDocumentChanged, object: self)
            configureNativeFormTracking()
        }
    }
    var nativeFormTracker: NativeFormTracker?
    var selectionTask: Task<Void, Never>?
    private(set) var annotationPopover: NSPopover?
    private var pendingMarkerHit: MarkerHit?
    private var trackingMarkerClick = false
    var liveTextView: NSTextView?
    var liveTextDelegate: LiveTextDelegate?
    private var areaStart: (PDFPage, CGPoint)?
    private let areaOutline = CAShapeLayer()

    private func configureNativeFormTracking() {
        nativeFormTracker = nil
        if let model, let document { nativeFormTracker = NativeFormTracker(view: self, model: model, document: document) }
    }

    @objc nonisolated private func nativeDocumentChanged() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { configureNativeFormTracking() }
        } else {
            Task { @MainActor [weak self] in self?.configureNativeFormTracking() }
        }
    }

    // PDFKit installs its own gestures on child views. Route only our explicit
    // tags/badges to this view so annotation popup handling has one event owner.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let nativeHit = super.hitTest(point)
        if model?.selectingToolArea == true, nativeHit != nil { return self }
        if let editor = liveTextView, nativeHit === editor || nativeHit?.isDescendant(of: editor) == true { return nativeHit }
        if model?.activeTool == .edit, let superview,
           let page = page(for: convert(point, from: superview), nearest: false),
           let annotation = page.annotation(at: convert(convert(point, from: superview), to: page)),
           annotation.type == "FreeText",
           annotation.value(forAnnotationKey: MarkerCodec.ownerKey) as? String != MarkerCodec.ownerValue { return self }
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
        if model?.selectingToolArea == true {
            let point = convert(event.locationInWindow, from: nil)
            if let page = page(for: point, nearest: false) { areaStart = (page, convert(point, to: page)) }
            return
        }
        if model?.activeTool == .edit {
            let point = convert(event.locationInWindow, from: nil)
            if let page = page(for: point, nearest: false), let annotation = page.annotation(at: convert(point, to: page)),
               annotation.type == "FreeText",
               annotation.value(forAnnotationKey: MarkerCodec.ownerKey) as? String != MarkerCodec.ownerValue {
                model?.editTextAnnotation(annotation, page: page)
                return
            }
        }
        pendingMarkerHit = annotationHit(for: event)
        trackingMarkerClick = pendingMarkerHit != nil
        if trackingMarkerClick {
            window?.makeFirstResponder(self)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let (page, start) = areaStart, let document {
            let end = convert(convert(event.locationInWindow, from: nil), to: page)
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(page.bounds(for: .cropBox))
            if rect.width >= 1, rect.height >= 1 {
                model?.toolSelection = PageRegion(pageIndex: document.index(for: page), bounds: rect)
                updateAreaOutline()
            }
            return
        }
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
                model.openMarkerEditor(current)
            },
            close: { [weak self] in self?.closeAnnotationPopover() },
            delete: { [weak self, weak model] in
                self?.closeAnnotationPopover()
                guard let model, let current = model.markers.first(where: { $0.id == hit.marker.id }) else { return }
                model.removeMarkerFromReader(current)
            }
        ))
        annotationPopover = popover
        popover.show(relativeTo: hit.anchor.intersection(bounds), of: self, preferredEdge: .maxX)
    }

    func closeAnnotationPopover() {
        annotationPopover?.close()
        annotationPopover = nil
    }

    override func mouseUp(with event: NSEvent) {
        if areaStart != nil {
            areaStart = nil
            model?.selectingToolArea = false
            return
        }
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
        refreshLiveEditor()
        updateAreaOutline()
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

    @objc func refreshEditorGeometry() { refreshLiveEditor(); updateAreaOutline() }

    func replaceDocumentForLiveEdit(_ replacement: PDFDocument) {
        let origin = documentView?.enclosingScrollView?.contentView.bounds.origin
        let previousScale = scaleFactor
        let wasAutoScaling = autoScales
        document = replacement
        if wasAutoScaling { autoScales = true }
        else { scaleFactor = previousScale }
        layoutSubtreeIfNeeded()
        if let origin, let scroll = documentView?.enclosingScrollView {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func refreshLiveEditor(focus: Bool = false) {
        guard let edit = model?.liveEdit, let page = document?.page(at: edit.pageIndex), let host = documentView else {
            removeLiveEditor(); return
        }
        let field: NSTextView
        if let liveTextView { field = liveTextView }
        else {
            field = NSTextView()
            field.isRichText = true
            field.importsGraphics = false
            // The canvas uses zoomed point sizes. Our unscaled typography controls
            // avoid accidentally applying a view-sized value as a PDF font size.
            field.usesFontPanel = false
            field.isAutomaticQuoteSubstitutionEnabled = false
            field.isAutomaticDashSubstitutionEnabled = false
            field.isVerticallyResizable = false
            field.isHorizontallyResizable = false
            field.textContainerInset = .zero
            field.textContainer?.lineFragmentPadding = 0
            field.drawsBackground = true
            field.backgroundColor = .white
            field.insertionPointColor = .black
            field.wantsLayer = true
            field.layer?.borderWidth = 1.5
            field.layer?.borderColor = NSColor.controlAccentColor.cgColor
            field.setAccessibilityLabel("Edit PDF text in place")
            let delegate = LiveTextDelegate(model: model)
            field.delegate = delegate
            liveTextDelegate = delegate
            liveTextView = field
        }
        if field.superview !== host { field.removeFromSuperview(); host.addSubview(field) }
        // Match the PDF page's coordinate basis, including /Rotate and a nonzero crop origin.
        // An axis-aligned converted rect alone would stretch quarter-turned text and show a
        // horizontal editor over a vertical saved annotation.
        let bounds = edit.appliedBounds
        let topLeft = host.convert(convert(CGPoint(x: bounds.minX, y: bounds.maxY), from: page), from: self)
        let topRight = host.convert(convert(CGPoint(x: bounds.maxX, y: bounds.maxY), from: page), from: self)
        let bottomLeft = host.convert(convert(CGPoint(x: bounds.minX, y: bounds.minY), from: page), from: self)
        let width = hypot(topRight.x - topLeft.x, topRight.y - topLeft.y)
        let height = hypot(bottomLeft.x - topLeft.x, bottomLeft.y - topLeft.y)
        field.frameRotation = 0
        field.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let angle = atan2(topRight.y - topLeft.y, topRight.x - topLeft.x) * 180 / .pi
        field.frameRotation = angle
        let actualOrigin = field.convert(CGPoint.zero, to: host)
        field.setFrameOrigin(CGPoint(x: field.frame.origin.x + topLeft.x - actualOrigin.x,
                                     y: field.frame.origin.y + topLeft.y - actualOrigin.y))
        liveTextDelegate?.isSynchronizing = true
        // PDFKit may scale its document view's coordinate system independently
        // of PDFView.scaleFactor. Typography must use the editor host's basis.
        let textScale = width / bounds.width
        liveTextDelegate?.scale = textScale
        let displayedText = LiveTextLayout.scaled(edit.attributedText, by: textScale)
        if !field.attributedString().isEqual(to: displayedText) { field.textStorage?.setAttributedString(displayedText) }
        field.setSelectedRange(edit.selectedRange)
        let typing = LiveTextLayout.scaled(NSAttributedString(string: " ", attributes: edit.typingAttributes), by: textScale)
        field.typingAttributes = typing.attributes(at: 0, effectiveRange: nil)
        liveTextDelegate?.isSynchronizing = false
        if focus { window?.makeFirstResponder(field) }
    }

    func removeLiveEditor() {
        liveTextView?.delegate = nil
        liveTextView?.removeFromSuperview()
        liveTextView = nil
        liveTextDelegate = nil
    }

    func updateAreaOutline() {
        guard let region = model?.toolSelection, model?.activeTool != nil, model?.liveEdit == nil,
              let page = document?.page(at: region.pageIndex), let host = documentView else {
            areaOutline.removeFromSuperlayer(); return
        }
        host.wantsLayer = true
        if areaOutline.superlayer !== host.layer { areaOutline.removeFromSuperlayer(); host.layer?.addSublayer(areaOutline) }
        let rect = host.convert(convert(region.bounds, from: page), from: self)
        areaOutline.path = CGPath(rect: rect, transform: nil)
        areaOutline.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        areaOutline.strokeColor = NSColor.controlAccentColor.cgColor
        areaOutline.lineWidth = 1.5
        areaOutline.lineDashPattern = [5, 3]
    }
}
