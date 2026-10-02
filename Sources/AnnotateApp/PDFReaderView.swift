import AppKit
import AnnotateCore
import Atrium
import PDFKit
import SwiftUI

struct PDFReaderView: NSViewRepresentable {
    let model: ReaderModel
    func makeNSView(context: Context) -> SelectionPDFView {
        let view = SelectionPDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        // Paper on a neutral desk, as in Preview: pages float with a soft shadow on the
        // system's under-page colour, which adapts to light, dark and Increase Contrast.
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.pageBreakMargins = NSEdgeInsets(top: Spacing.margin, left: Spacing.margin,
                                             bottom: Spacing.margin, right: Spacing.margin)
        view.backgroundColor = .underPageBackgroundColor
        view.minScaleFactor = 0.2
        view.maxScaleFactor = 6
        // PDFKit asks for page overlays as it loads a document, so the provider is
        // installed before the document is.
        let pins = MarkerPinProvider(pdfView: view)
        view.pinProvider = pins
        view.pageOverlayViewProvider = pins
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
        if let clip = view.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(view, selector: #selector(SelectionPDFView.canvasScrolled), name: NSView.boundsDidChangeNotification, object: clip)
        }
        return view
    }
    func updateNSView(_ view: SelectionPDFView, context: Context) {
        if view.document !== model.pdfDocument {
            view.closeAnnotationPopover()
            view.document = model.pdfDocument
            view.autoScales = true
        }
        // Reading these registers the observation that redraws pins when markers change.
        _ = (model.markers, model.selectedMarkerID)
        view.refreshMarkerPins()
        view.refreshLiveEditor()
        view.updateAreaOutline()
    }
    static func dismantleNSView(_ view: SelectionPDFView, coordinator: ()) {
        NotificationCenter.default.removeObserver(view)
        view.selectionTask?.cancel()
        view.closeAnnotationPopover()
        // Also removes the Escape monitor, which would otherwise outlive the window.
        view.removeLiveEditor()
        if view.model?.pdfView === view { view.model?.pdfView = nil }
    }
}

@MainActor
final class SelectionPDFView: PDFView {
    weak var model: ReaderModel? {
        didSet {
            // Links in the PDF go through ExternalLink rather than straight to the system.
            delegate = linkDelegate
            NotificationCenter.default.removeObserver(self, name: .PDFViewDocumentChanged, object: self)
            NotificationCenter.default.addObserver(self, selector: #selector(nativeDocumentChanged), name: .PDFViewDocumentChanged, object: self)
            configureNativeFormTracking()
        }
    }
    var nativeFormTracker: NativeFormTracker?
    /// A separate object: PDFView forwards some of its own delegate calls to its delegate,
    /// so the view can't be its own.
    private lazy var linkDelegate = LinkDelegate(view: self)
    /// Asks the reader whether to open an external link, showing its whole address.
    var confirmExternalLink: @MainActor (URL, NSWindow?, @escaping @MainActor (Bool) -> Void) -> Void = SelectionPDFView.askToOpen
    /// Opens a link the reader agreed to.
    var openExternalLink: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Tells the reader a link was refused, and why.
    var reportRefusedLink: @MainActor (String, NSWindow?) -> Void = SelectionPDFView.tellRefused
    var selectionTask: Task<Void, Never>?
    private(set) var annotationPopover: NSPopover?
    private var pendingMarkerHit: MarkerHit?
    private var trackingMarkerClick = false
    var liveTextView: NSTextView?
    var liveTextDelegate: LiveTextDelegate?
    /// Escape anywhere in this window ends the text edit, whatever has focus: the text
    /// on the page, a field in the inspector, or nothing at all.
    private var escapeMonitor: Any?
    /// The glass formatting bar that floats beside the text being edited.
    private var formatBar: NSHostingView<LiveTextFormatBar>?
    /// Strong reference: PDFView holds its overlay provider weakly.
    var pinProvider: MarkerPinProvider?
    /// A click in Edit that may become "edit this paragraph" once the button is released.
    private var pendingParagraphEdit: NSPoint?
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
        if let bar = formatBar, let nativeHit, nativeHit === bar || nativeHit.isDescendant(of: bar) { return nativeHit }
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
        pendingParagraphEdit = nil
        if model?.selectingToolArea == true {
            let point = convert(event.locationInWindow, from: nil)
            if let page = page(for: point, nearest: false) { areaStart = (page, convert(point, to: page)) }
            return
        }
        // Clicks inside the editor go straight to it (see hitTest), so a click that
        // arrives here is elsewhere on the page: it ends the edit, as in Pages. Text that
        // could not be applied keeps the editor open instead.
        if model?.liveEdit != nil {
            guard model?.finishLiveText() == true else { return }
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
        } else if model?.activeTool != .edit, let link = externalLink(at: event) {
            // Followed here rather than by PDFKit, which would open any address. While
            // editing, the click edits the text under the link instead.
            follow(link)
        } else {
            let editsText = model?.activeTool == .edit && event.clickCount == 1
                && event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty
            super.mouseDown(with: event)
            guard editsText else { return }
            // PDFKit may track the whole drag inside mouseDown; if the button is already
            // up, this was a plain click. Otherwise decide when mouseUp arrives.
            if NSEvent.pressedMouseButtons & 1 == 0 { editParagraph(at: event.locationInWindow) }
            else { pendingParagraphEdit = event.locationInWindow }
        }
    }

    /// In Edit, a plain click on text starts editing its paragraph with the insertion
    /// point where the click landed. Dragging selects just some words instead.
    func editParagraph(at windowPoint: NSPoint) {
        guard let model, model.activeTool == .edit, model.liveEdit == nil,
              currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else { return }
        let point = convert(windowPoint, from: nil)
        guard let page = page(for: point, nearest: false) else { return }
        let pagePoint = convert(point, to: page)
        guard let paragraph = ParagraphText.paragraph(at: pagePoint, on: page) else { return }
        model.suppressSelection = true
        setCurrentSelection(paragraph.selection, animate: false)
        model.suppressSelection = false
        model.beginLiveText(replacingSelection: true, reflowingLines: paragraph.rewraps)
        guard let field = liveTextView, model.liveEdit != nil else { return }
        let index = field.characterIndexForInsertion(at: field.convert(windowPoint, from: nil))
        field.setSelectedRange(NSRange(location: min(index, field.string.utf16.count), length: 0))
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
            pendingParagraphEdit = nil
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

    /// Opens a marker's details from the keyboard or VoiceOver: goes to the marker, then
    /// anchors the popover on its pin.
    func showDetails(for marker: PDFMarker) {
        guard let model, let document, let region = marker.regions.first,
              let page = document.page(at: region.pageIndex) else { return }
        model.jump(to: marker)
        layoutDocumentView()
        let icon = page.annotations.first {
            $0.type == "FreeText" && $0.value(forAnnotationKey: MarkerCodec.identifierKey) as? String == marker.id.uuidString
        }?.bounds ?? region.bounds
        let anchor = MarkerPinArtwork.screenFrame(convert(MarkerPin.footprint(of: marker, icon: icon, on: page), from: page))
        showAnnotation(MarkerHit(marker: marker, anchor: anchor))
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
        if let point = pendingParagraphEdit {
            pendingParagraphEdit = nil
            editParagraph(at: point)
            if model?.liveEdit != nil { return }
        }
        if let selection = currentSelection { model?.captureSelection(selection) }
    }
    @objc func pageChanged() {
        closeAnnotationPopover()
        if let document, let currentPage { model?.pageNumber = document.index(for: currentPage) + 1 }
        refreshLiveEditor()
        updateAreaOutline()
    }

    func refreshMarkerPins() { pinProvider?.refresh() }

    @objc func canvasScrolled() { positionFormatBar() }

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
            field = LiveTextCanvas.makeEditor()
            let delegate = LiveTextDelegate(model: model)
            field.delegate = delegate
            liveTextDelegate = delegate
            liveTextView = field
            watchForEscape()
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
        LiveTextCanvas.present(field, showsPendingText: edit.nativeUpdateFailed, overflows: edit.textOverflows)
        if focus { window?.makeFirstResponder(field) }
        showFormatBar(for: edit)
    }

    private func watchForEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, event.window === self.window, let window = self.window,
                  // Fn and Caps Lock don't change what Escape means.
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .capsLock]).isEmpty,
                  window.attachedSheet == nil, self.model?.liveEdit != nil else { return event }
            // Escape first cancels an input method's composition.
            if let text = window.firstResponder as? NSTextView, text.hasMarkedText() { return event }
            // Ending removes the editor and this monitor; do it after the key event.
            Task { @MainActor [weak self] in self?.model?.endLiveTextEditing() }
            return nil
        }
    }

    func removeLiveEditor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        liveTextView?.delegate = nil
        liveTextView?.removeFromSuperview()
        liveTextView = nil
        liveTextDelegate = nil
        formatBar?.removeFromSuperview()
        formatBar = nil
    }

    private func showFormatBar(for edit: LiveTextEdit) {
        guard let model else { return }
        let bar: NSHostingView<LiveTextFormatBar>
        if let formatBar, formatBar.rootView.session === edit { bar = formatBar }
        else {
            formatBar?.removeFromSuperview()
            bar = NSHostingView(rootView: LiveTextFormatBar(model: model, session: edit))
            addSubview(bar)
            formatBar = bar
        }
        positionFormatBar()
    }

    /// Floats the format bar beside the text block: above it where that covers no text,
    /// otherwise below it where that covers none, otherwise above. Always inside the canvas.
    func positionFormatBar() {
        guard let bar = formatBar, let field = liveTextView, field.superview != nil,
              let edit = model?.liveEdit, let page = document?.page(at: edit.pageIndex) else { return }
        let size = bar.fittingSize
        let block = convert(field.bounds, from: field).insetBy(dx: -Spacing.tight, dy: -Spacing.tight)
        let visible = safeAreaRect
        let gap = Spacing.snug
        var x = block.midX - size.width / 2
        x = min(max(x, visible.minX + gap), max(visible.minX + gap, visible.maxX - size.width - gap))
        // Screen-up is +y in an unflipped view and −y in a flipped one.
        let above = CGRect(x: x, y: isFlipped ? block.minY - gap - size.height : block.maxY + gap, width: size.width, height: size.height)
        let below = CGRect(x: x, y: isFlipped ? block.maxY + gap : block.minY - gap - size.height, width: size.width, height: size.height)
        func fits(_ rect: CGRect) -> Bool { visible.contains(rect) }
        func coversText(_ rect: CGRect) -> Bool {
            let text = page.selection(for: convert(rect, to: page))?.string ?? ""
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let choice = [above, below].first { fits($0) && !coversText($0) } ?? (fits(above) ? above : below)
        let y = min(max(choice.minY, visible.minY), max(visible.minY, visible.maxY - size.height))
        bar.frame = CGRect(x: choice.minX, y: y, width: size.width, height: size.height)
        bar.isHidden = !visible.intersects(block)
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

// MARK: - Links

/// Receives PDFKit's link clicks; PDFKit's own handling would hand any address in the PDF
/// to the system.
@MainActor
final class LinkDelegate: NSObject, @preconcurrency PDFViewDelegate {
    private weak var view: SelectionPDFView?
    init(view: SelectionPDFView) { self.view = view }
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) { view?.follow(ExternalLink(url)) }
    /// PDFKit's default only beeps; the reader is told why instead, whatever route PDFKit takes.
    func pdfViewOpenPDF(_ sender: PDFView, forRemoteGoToAction action: PDFActionRemoteGoTo) { view?.follow(.remoteDocument) }
}

extension SelectionPDFView {
    override func perform(_ action: PDFAction) {
        switch action {
        case let link as PDFActionURL:
            if let url = link.url { follow(ExternalLink(url)) }
        case is PDFActionRemoteGoTo:
            follow(.remoteDocument)
        default:
            super.perform(action)
        }
    }

    /// The external link under a plain click, if any. Links within this PDF are left to
    /// PDFKit, which only scrolls.
    func externalLink(at event: NSEvent) -> ExternalLink? {
        guard event.type == .leftMouseDown, event.clickCount == 1,
              event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false),
              let annotation = page.annotation(at: convert(point, to: page)), annotation.type == "Link" else { return nil }
        switch annotation.action {
        case let action as PDFActionURL: return action.url.map(ExternalLink.init)
        case is PDFActionRemoteGoTo: return .remoteDocument
        case nil: return annotation.url.map(ExternalLink.init)
        default: return nil
        }
    }

    func follow(_ link: ExternalLink) {
        // While editing, a click edits the text under it; links don't open.
        guard model?.activeTool != .edit else { return }
        switch link {
        case .confirm(let url):
            confirmExternalLink(url, window) { [weak self] agreed in
                if agreed { self?.openExternalLink(url) }
            }
        case .refuse(let reason):
            reportRefusedLink(reason, window)
        }
    }

    private static func askToOpen(_ url: URL, in window: NSWindow?, then decide: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = url.scheme?.lowercased() == "mailto" ? "Write an email from this link?" : "Open this link in your browser?"
        alert.informativeText = ExternalLink.summary(url)
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        // Return cancels: opening takes a deliberate click, even when a long address
        // pushes the buttons out of view.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        if let window {
            alert.beginSheetModal(for: window) { response in decide(response == .alertFirstButtonReturn) }
        } else {
            decide(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    private static func tellRefused(_ reason: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Link not opened"
        alert.informativeText = reason
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

