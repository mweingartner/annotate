import AnnotateCore
import AppKit
import Atrium
import PDFKit
import SwiftUI

/// Supplies each visible page with an overlay that draws its markers as native pins.
@MainActor
final class MarkerPinProvider: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    weak var pdfView: SelectionPDFView?
    private var overlays: [ObjectIdentifier: MarkerPinOverlay] = [:]

    init(pdfView: SelectionPDFView) { self.pdfView = pdfView }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = MarkerPinOverlay(page: page, provider: self)
        overlays[ObjectIdentifier(page)] = overlay
        overlay.refresh()
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        overlays[ObjectIdentifier(page)] = nil
    }

    /// Markers, their colours or the selection changed: redraw every visible page's pins.
    func refresh() { overlays.values.forEach { $0.refresh() } }
}

/// One page's pins. It never takes mouse clicks itself: the reader's hit testing finds
/// the pin (`AnnotationHitTesting`) and opens the marker's details. For VoiceOver each
/// pin is a button that opens the same details.
@MainActor
final class MarkerPinOverlay: NSView {
    private weak var page: PDFPage?
    private weak var provider: MarkerPinProvider?
    private var pins: [String: (bounds: CGRect, view: PinHostingView)] = [:]

    init(page: PDFPage, provider: MarkerPinProvider) {
        self.page = page
        self.provider = provider
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Not used from a coder") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func refresh() {
        guard let page, let reader = provider?.pdfView, let model = reader.model else { return }
        let markers = Dictionary(model.markers.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        // Each marker's icon annotation marks exactly where its pin belongs.
        var placed: [String: CGRect] = [:]
        for annotation in page.annotations where annotation.type == "FreeText"
            && annotation.value(forAnnotationKey: MarkerCodec.ownerKey) as? String == MarkerCodec.ownerValue {
            guard let id = annotation.value(forAnnotationKey: MarkerCodec.identifierKey) as? String,
                  let marker = markers[id] else { continue }
            placed[id] = MarkerPin.footprint(of: marker, icon: annotation.bounds, on: page)
        }
        for (id, pin) in pins where placed[id] == nil {
            pin.view.removeFromSuperview()
            pins[id] = nil
        }
        for (id, bounds) in placed {
            guard let marker = markers[id] else { continue }
            let pin = MarkerPin(marker: marker, selected: model.selectedMarkerID == marker.id)
            let host = pins[id]?.view ?? {
                let host = PinHostingView(rootView: pin)
                addSubview(host)
                return host
            }()
            host.rootView = pin
            host.describe(marker)
            host.press = { [weak reader] in reader?.showDetails(for: marker) }
            pins[id] = (bounds, host)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let page, let reader = provider?.pdfView else { return }
        for pin in pins.values {
            // Sized as a comfortable target, matching AnnotationHitTesting.
            let frame = MarkerPinArtwork.screenFrame(reader.convert(pin.bounds, from: page))
            pin.view.frame = convert(frame, from: reader)
        }
    }
}

/// Hosts one pin and presents it to VoiceOver as a button.
final class PinHostingView: NSHostingView<MarkerPin> {
    var press: (() -> Void)?

    func describe(_ marker: PDFMarker) {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        let kind = marker.isBookmark ? "Bookmark" : "Annotation"
        let page = MarkerPresentation.pageLabel(regions: marker.regions)
        setAccessibilityLabel([kind, page, marker.isBookmark ? "" : marker.quote].filter { !$0.isEmpty }.joined(separator: ", "))
        setAccessibilityHelp("Shows this marker’s details")
    }

    override func accessibilityPerformPress() -> Bool {
        press?()
        return press != nil
    }
}

/// A marker on the page, in Liquid Glass tinted with the marker's colour: the colour
/// body with a sheen and light edge (`MarkerPinArtwork` draws the same pin into printed
/// and exported pages), lifted slightly off the paper, the icon filling most of it.
struct MarkerPin: View {
    let marker: PDFMarker
    let selected: Bool

    /// Where the pin goes, in page space: see `MarkerPinArtwork.frame`.
    @MainActor
    static func footprint(of marker: PDFMarker, icon: CGRect, on page: PDFPage) -> CGRect {
        let line = marker.regions.first { page.document?.index(for: page) == $0.pageIndex }?.bounds
        return MarkerPinArtwork.frame(icon: icon, line: line, isBookmark: marker.isBookmark)
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let shape = RoundedRectangle(cornerRadius: side * MarkerPinArtwork.cornerRatio, style: .continuous)
            let base = Color(nsColor: marker.color.nsColor)
            Image(systemName: marker.icon)
                .font(.system(size: side * MarkerPinArtwork.symbolPointScale, weight: .semibold))
                .foregroundStyle(Color(nsColor: marker.color.readableInkColor))
                .shadow(color: .black.opacity(0.15), radius: side * 0.02, y: side * 0.02)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .background {
                    shape.fill(base.gradient)
                        .overlay {
                            // Sheen: light falling across the upper half, as on glass.
                            shape.fill(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0)],
                                                      startPoint: .top, endPoint: .center))
                        }
                }
                .glassEffect(.regular.tint(base.opacity(0.35)), in: shape)
                .overlay {
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .black.opacity(0.12)],
                                                      startPoint: .top, endPoint: .bottom),
                                       lineWidth: max(0.5, side * 0.05))
                }
                .shadow(color: .black.opacity(0.22), radius: side * 0.12, y: side * 0.06)
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: side * (MarkerPinArtwork.cornerRatio + 0.15), style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: max(1, side * 0.1))
                            .padding(-side * 0.15)
                    }
                }
        }
    }
}
