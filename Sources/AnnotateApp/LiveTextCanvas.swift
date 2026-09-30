import AppKit
import Atrium

/// In-place text editing that looks like the page, not like a form field.
///
/// Every keystroke is applied to the PDF itself (see `ReaderModel.updateLiveText`), so the
/// page already shows the edited words in their real fonts and positions. The editor on
/// top therefore draws only what the page cannot: the insertion point, the selection and
/// a quiet outline around the block. Its own glyphs stay hidden, unless the latest text
/// could not be applied; then it shows them on a page-coloured ground so nothing typed
/// is ever invisible.
@MainActor
enum LiveTextCanvas {
    /// Builds the editor on TextKit 1 so glyph drawing can be withheld while the
    /// caret, selection and marked-text handling stay entirely AppKit's own.
    static func makeEditor() -> NSTextView {
        let storage = NSTextStorage()
        let layout = LiveTextLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let field = NSTextView(frame: .zero, textContainer: container)
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
        field.focusRingType = .none
        field.wantsLayer = true
        field.setAccessibilityLabel("Edit PDF text in place")
        field.setAccessibilityHelp("Type to change the text on the page. Press Escape or click elsewhere when you are done.")
        return field
    }

    /// Chooses between the natural presentation and the visible fallback, and keeps the
    /// outline in step with the block's size and state.
    static func present(_ field: NSTextView, showsPendingText: Bool, overflows: Bool) {
        (field.layoutManager as? LiveTextLayoutManager)?.drawsGlyphs = showsPendingText
        // Pending text that doesn't fit is not laid out past the block's edge, as in a Pages
        // text box; an overflow mark says there is more. Applied text is never clipped, so
        // TextKit's slightly taller line boxes can't hide the last line's insertion point.
        if let container = field.textContainer {
            let height = showsPendingText ? field.bounds.height : CGFloat.greatestFiniteMagnitude
            if container.size.height != height { container.size = NSSize(width: container.size.width, height: height) }
        }
        field.drawsBackground = showsPendingText
        field.backgroundColor = .white
        // A translucent selection lets the page's own glyphs show through it.
        field.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.4)]
        // Text that only needs more room keeps the ordinary outline plus an overflow mark;
        // any other failure to apply it gets the caution outline.
        outline(on: field, pending: showsPendingText && !overflows)
        overflowMark(on: field, visible: showsPendingText && overflows)
        field.needsDisplay = true
    }

    private static let overflowName = "AnnotateLiveTextOverflow"

    /// A small caution-coloured plus on the block's bottom edge, as Pages marks a text box
    /// with more text than it shows.
    private static func overflowMark(on field: NSTextView, visible: Bool) {
        guard let layer = field.layer else { return }
        let existing = layer.sublayers?.first { $0.name == overflowName }
        guard visible else { existing?.removeFromSuperlayer(); return }
        let mark = existing ?? {
            let mark = CALayer()
            mark.name = overflowName
            layer.addSublayer(mark)
            return mark
        }()
        let side = Metrics.minimumControl * 0.7
        let configuration = NSImage.SymbolConfiguration(pointSize: side, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemOrange]))
        let image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: "More text than fits")?
            .withSymbolConfiguration(configuration)
        mark.contents = image
        mark.contentsGravity = .resizeAspect
        mark.contentsScale = field.window?.backingScaleFactor ?? 2
        let edge = field.isFlipped ? field.bounds.maxY : field.bounds.minY
        mark.frame = CGRect(x: field.bounds.midX - side / 2, y: edge - side / 2, width: side, height: side)
    }

    private static let outlineName = "AnnotateLiveTextOutline"

    /// A hairline just outside the text block: accent while editing, caution when the
    /// latest text is waiting to be applied. It rotates with the editor on turned pages.
    private static func outline(on field: NSTextView, pending: Bool) {
        guard let layer = field.layer else { return }
        layer.masksToBounds = false
        let outline = layer.sublayers?.first { $0.name == outlineName } as? CAShapeLayer ?? {
            let shape = CAShapeLayer()
            shape.name = outlineName
            shape.fillColor = nil
            shape.lineWidth = 1
            layer.addSublayer(shape)
            return shape
        }()
        let frame = field.bounds.insetBy(dx: -Spacing.tight, dy: -Spacing.tight)
        outline.frame = frame
        outline.path = CGPath(roundedRect: CGRect(origin: .zero, size: frame.size),
                              cornerWidth: Radius.badge, cornerHeight: Radius.badge, transform: nil)
        var color = NSColor.controlAccentColor
        field.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = pending ? .systemOrange : .controlAccentColor.withAlphaComponent(0.7)
        }
        outline.strokeColor = color.cgColor
        outline.lineDashPattern = pending ? [4, 3] : nil
    }
}

/// Lays out text exactly as TextKit always does, but draws glyphs only on request.
/// Selection and the insertion point are drawn by the text view, so they remain.
final class LiveTextLayoutManager: NSLayoutManager {
    var drawsGlyphs = false

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard drawsGlyphs else { return }
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
    }
}
