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
    /// Escape ends the edit, as it does for text in Pages and Keynote, even when the text
    /// could not be applied (see `ReaderModel.endLiveTextEditing`).
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        // Ending removes this text view; do it after AppKit finishes the key event.
        Task { @MainActor [weak model] in model?.endLiveTextEditing() }
        return true
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
