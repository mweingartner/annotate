import AnnotateCore
import AppKit
import PDFKit

/// Observes committed PDFKit widget values and only the native text editors belonging to one PDFView.
/// Keeping value undo in place avoids replacing a document while its field editor owns the caret.
@MainActor
final class NativeFormTracker: NSObject {
    private weak var view: SelectionPDFView?
    private weak var model: ReaderModel?
    private let document: PDFDocument
    private var lastFields: [PDFFormField]
    private var observations: [NSKeyValueObservation] = []
    private weak var activeWidget: PDFAnnotation?
    private weak var activeTextEditor: NSTextView?
    private weak var activeTextControl: NSTextField?
    private var isRestoring = false

    init(view: SelectionPDFView, model: ReaderModel, document: PDFDocument) {
        self.view = view
        self.model = model
        self.document = document
        lastFields = PDFFormEditor.fields(in: document)
        super.init()
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] where annotation.type == "Widget" {
                observations.append(annotation.observe(\.widgetStringValue, options: [.new]) { @Sendable [weak self] _, _ in
                    Self.deliverChange(to: self)
                })
                observations.append(annotation.observe(\.buttonWidgetState, options: [.new]) { @Sendable [weak self] _, _ in
                    Self.deliverChange(to: self)
                })
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(annotationHit(_:)), name: .PDFViewAnnotationHit, object: view)
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged(_:)), name: NSText.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged(_:)), name: NSControl.textDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(textEnded(_:)), name: NSText.didEndEditingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(textEnded(_:)), name: NSControl.textDidEndEditingNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    nonisolated private static func deliverChange(to tracker: NativeFormTracker?) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { tracker?.captureChanges() }
        } else {
            Task { @MainActor [weak tracker] in tracker?.captureChanges() }
        }
    }

    func captureChanges() {
        guard !isRestoring, let model, model.pdfDocument === document else { return }
        let current = PDFFormEditor.fields(in: document)
        guard current != lastFields else { return }
        let previous = lastFields
        lastFields = current
        model.recordNativeFormChange(previous: previous)
    }

    func restoring(_ operation: () -> Void) {
        isRestoring = true
        operation()
        if let value = activeWidget?.widgetStringValue {
            if let editor = activeTextEditor, editor.string != value { editor.string = value }
            if let control = activeTextControl, control.stringValue != value { control.stringValue = value }
        }
        lastFields = PDFFormEditor.fields(in: document)
        isRestoring = false
    }

    @objc private func annotationHit(_ notification: Notification) {
        guard notification.object as AnyObject? === view else { return }
        // Apple's documented notification payload uses this key.
        activeWidget = notification.userInfo?["PDFAnnotationHit"] as? PDFAnnotation
        activeTextEditor = nil
        activeTextControl = nil
        captureChanges()
    }

    @objc private func textChanged(_ notification: Notification) {
        guard let text = textFromOwnedEditor(notification.object), let widget = widgetForOwnedEditor(notification.object),
              widget.page?.document === document, widget.widgetFieldType == .text,
              !document.isLocked, document.allowsFormFieldEntry, !widget.isReadOnly,
              widget.widgetStringValue != text else { return }
        if widget.maximumLength > 0, text.count > widget.maximumLength {
            model?.errorMessage = "This form field allows at most \(widget.maximumLength) characters."
            return
        }
        activeWidget = widget
        activeTextEditor = notification.object as? NSTextView
        activeTextControl = notification.object as? NSTextField
        // PDFKit may keep an active NSText field-editor buffer until focus changes. Persist its
        // value immediately so autosave, closing, and an AI request see the words currently shown.
        widget.widgetStringValue = text
        captureChanges()
    }

    @objc private func textEnded(_ notification: Notification) {
        guard textFromOwnedEditor(notification.object) != nil else { return }
        textChanged(notification)
        captureChanges()
    }

    private func textFromOwnedEditor(_ object: Any?) -> String? {
        guard let view else { return nil }
        if let field = object as? NSTextView {
            if field === view.liveTextView { return nil }
            let belongsToView = field.isDescendant(of: view)
                || (field.delegate as? NSView)?.isDescendant(of: view) == true
            return belongsToView ? field.string : nil
        }
        if let field = object as? NSTextField, field.isDescendant(of: view) { return field.stringValue }
        return nil
    }

    private func widgetForOwnedEditor(_ object: Any?) -> PDFAnnotation? {
        guard let view, let editor = object as? NSView else { return nil }
        let source: NSView
        if let textView = editor as? NSTextView, let control = textView.delegate as? NSView,
           control.isDescendant(of: view) { source = control }
        else { source = editor }
        let point = source.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), to: view)
        guard let page = view.page(for: point, nearest: false), page.document === document else { return nil }
        let pagePoint = view.convert(point, to: page)
        // Keyboard Tab may switch fields without an annotation-hit notification. Resolve the
        // current editor by its visible field location, never by a stale last-clicked widget.
        return page.annotations.last { $0.type == "Widget" && $0.widgetFieldType == .text && $0.bounds.contains(pagePoint) }
    }
}
