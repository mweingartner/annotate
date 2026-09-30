import AnnotateCore
import AppKit
import Atrium

/// The look of a marker pin, shared by the live pin on screen (`MarkerPin`) and the pin
/// drawn into printed and exported pages, so a marker looks the same everywhere and in
/// every colour: a colour body with a glassy top sheen, a light edge, a soft lift off the
/// paper, and the icon filling most of it so the colour sits just outside the icon.
enum MarkerPinArtwork {
    /// The icon's share of the pin's side.
    static let symbolScale: CGFloat = 0.7
    /// Font size, as a share of the side, that makes an SF Symbol fill `symbolScale`:
    /// symbols carry a little space around their ink.
    static let symbolPointScale: CGFloat = symbolScale * 0.94
    /// Corner radius as a share of the side (Atrium's field radius at control size).
    static let cornerRatio = Radius.field / Metrics.control

    /// Where the pin sits, in page space: at the marker's icon annotation, centred on
    /// the line it marks. A bookmark's pin is a tab over its icon and its small
    /// highlight, which PDFView draws itself and so cannot be hidden.
    static func frame(icon: CGRect, line: CGRect?, isBookmark: Bool) -> CGRect {
        guard isFinite(icon) else { return icon }
        // MarkerCodec writes an 18 pt icon; a far larger one did not come from it, so the
        // pin keeps the codec's size, centred where the icon is.
        let largest: CGFloat = 36
        // Too large, or far from square: not an icon MarkerCodec wrote.
        guard icon.width <= largest, icon.height <= largest,
              min(icon.width, icon.height) * 4 >= max(icon.width, icon.height) else {
            return CGRect(x: icon.midX - largest / 4, y: icon.midY - largest / 4, width: largest / 2, height: largest / 2)
        }
        guard let line, isFinite(line), line.height > 0 else { return icon }
        if isBookmark {
            let tab = icon.union(line)
            // Only when the two sit side by side, as MarkerCodec places them.
            return tab.width <= icon.width * 3 && tab.height <= icon.height * 1.5 ? tab : icon
        }
        // Only a line beside the icon (MarkerCodec clamps icons at page edges).
        guard abs(line.midY - icon.midY) <= icon.height else { return icon }
        return icon.offsetBy(dx: 0, dy: line.midY - icon.midY)
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
    }

    /// A pin on screen stays a comfortable target at any zoom: at least the HIG's
    /// minimum control and at most a standard control, centred where it would be.
    static func screenFrame(_ frame: CGRect) -> CGRect {
        guard isFinite(frame), frame.height > 0 else { return frame }
        let side = min(max(frame.height, Metrics.minimumControl), Metrics.control)
        let scale = side / frame.height
        // A bookmark tab is at most three pins wide.
        let size = CGSize(width: min(frame.width * scale, side * 3), height: side)
        return CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Draws the pin for output (print, export) into a page context, in page space.
    @MainActor
    static func draw(symbol: String, color: MarkerColor, in rect: CGRect, context: CGContext) {
        guard isFinite(rect), rect.width > 0, rect.height > 0 else { return }
        let side = min(rect.width, rect.height)
        let radius = side * cornerRatio
        let body = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let base = color.nsColor
        context.saveGState()
        // Lift: a soft shadow below the pin.
        context.setShadow(offset: CGSize(width: 0, height: -side * 0.05), blur: side * 0.18,
                          color: NSColor.black.withAlphaComponent(0.22).cgColor)
        context.addPath(body)
        context.setFillColor(base.cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(body)
        context.clip()
        // Body and sheen in one opaque gradient: light across the upper half, as on
        // glass, then the colour, deepening a little at the bottom. (PDF output cannot
        // carry a gradient's transparency, so the sheen is blended in, not overlaid.)
        let colors = [base.blended(withFraction: 0.45, of: .white), base.blended(withFraction: 0.18, of: .white),
                      base, base.blended(withFraction: 0.12, of: .black)].map { ($0 ?? base).cgColor }
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: colors as CFArray, locations: [0, 0.48, 0.52, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY),
                                       end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        }
        context.restoreGState()

        // Edge: a light rim inside the body.
        let inset = side * 0.03
        let rim = CGPath(roundedRect: rect.insetBy(dx: inset, dy: inset), cornerWidth: radius - inset,
                         cornerHeight: radius - inset, transform: nil)
        context.saveGState()
        context.addPath(rim)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        context.setLineWidth(side * 0.05)
        context.strokePath()
        context.addPath(body)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.12).cgColor)
        context.setLineWidth(max(0.25, side * 0.025))
        context.strokePath()
        context.restoreGState()

        // Icon: the SF Symbol as a stencil filled with the ink colour. A stencil keeps its
        // transparency in PDF output, where a drawn image with alpha can lose it.
        let configuration = NSImage.SymbolConfiguration(pointSize: side * symbolPointScale, weight: .semibold)
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        var proposed = CGRect(origin: .zero, size: image.size)
        // Rendered well above screen resolution so print stays crisp.
        guard let stencil = image.cgImage(forProposedRect: &proposed, context: nil,
                                          hints: [.ctm: AffineTransform(scale: 8)]) else { return }
        let size = image.size
        let scale = min(side * symbolScale / max(size.width, 1), side * symbolScale / max(size.height, 1), 1.6)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let target = CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                            width: drawn.width, height: drawn.height)
        context.saveGState()
        context.clip(to: target, mask: stencil)
        context.setFillColor(color.readableInkColor.cgColor)
        context.fill(target)
        context.restoreGState()
    }
}
