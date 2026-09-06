import AppKit

@MainActor
final class LiveTextDelegate: NSObject, NSTextViewDelegate {
    weak var model: ReaderModel?
    var isSynchronizing = false
    var scale = 1.0
    init(model: ReaderModel?) { self.model = model }
    func textDidChange(_ notification: Notification) {
        guard !isSynchronizing, let field = notification.object as? NSTextView, let edit = model?.liveEdit else { return }
        edit.updateAttributedText(LiveTextLayout.scaled(field.attributedString(), by: 1 / scale), selectedRange: field.selectedRange())
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isSynchronizing, let field = notification.object as? NSTextView, let edit = model?.liveEdit else { return }
        // AppKit moves the caret before textDidChange. Refreshing the PDF editor
        // in that interval would overwrite the new characters with the old session.
        let text = LiveTextLayout.scaled(field.attributedString(), by: 1 / scale)
        guard text.isEqual(to: edit.attributedText) else { return }
        edit.updateSelection(field.selectedRange())
    }
}
