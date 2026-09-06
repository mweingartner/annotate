import SwiftUI

/// An accessible secondary editor using the same attributed text and selection as the page editor.
struct SidebarRichTextEditor: NSViewRepresentable {
    @Bindable var session: LiveTextEdit

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .white
        let text = NSTextView(frame: .zero)
        text.isRichText = true
        text.isEditable = true
        text.isSelectable = true
        text.allowsUndo = true
        text.importsGraphics = false
        text.usesFontPanel = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 280, height: CGFloat.greatestFiniteMagnitude)
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.backgroundColor = .white
        text.insertionPointColor = .black
        text.setAccessibilityLabel("Edit PDF text and select characters to format")
        text.delegate = context.coordinator
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.session = session
        coordinator.isSynchronizing = true
        defer { coordinator.isSynchronizing = false }
        if !text.attributedString().isEqual(to: session.attributedText) {
            text.textStorage?.setAttributedString(session.attributedText)
        }
        let length = text.textStorage?.length ?? 0
        let start = min(length, max(0, session.selectedRange.location))
        let count = min(length - start, max(0, session.selectedRange.length))
        let selection = NSRange(location: start, length: count)
        if text.selectedRange() != selection { text.setSelectedRange(selection) }
        text.typingAttributes = session.typingAttributes
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var session: LiveTextEdit
        var isSynchronizing = false
        init(session: LiveTextEdit) { self.session = session }

        func textDidChange(_ notification: Notification) {
            guard !isSynchronizing, let text = notification.object as? NSTextView else { return }
            session.updateAttributedText(text.attributedString(), selectedRange: text.selectedRange())
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isSynchronizing, let text = notification.object as? NSTextView else { return }
            // Let textDidChange publish newly typed text together with its caret.
            guard text.attributedString().isEqual(to: session.attributedText) else { return }
            session.updateSelection(text.selectedRange())
        }
    }
}
