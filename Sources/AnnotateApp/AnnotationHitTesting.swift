import AnnotateCore
import AppKit
import PDFKit

struct MarkerHit {
    let marker: PDFMarker
    let anchor: CGRect
}

/// Intercept a marker's pin (its owned icon annotation) and its comment annotation,
/// and a bookmark's tab, leaving passage text selectable. The comment carries the note for other PDF readers
/// and is not drawn here (see MarkerChrome), but it is still intercepted: otherwise
/// PDFKit would open its own note popup for it.
@MainActor
enum AnnotationHitTesting {
    static func hit(at point: CGPoint, in view: PDFView, markers: [PDFMarker]) -> MarkerHit? {
        directHit(at: point, in: view, markers: markers) ?? pinHit(at: point, in: view, markers: markers)
    }

    /// A click on a pin that is larger on screen than its icon annotation (pins never
    /// shrink below the minimum target, see `MarkerPinArtwork.screenFrame`).
    private static func pinHit(at point: CGPoint, in view: PDFView, markers: [PDFMarker]) -> MarkerHit? {
        guard view.bounds.contains(point), let page = view.page(for: point, nearest: false) else { return nil }
        // A link, form field or action under the point keeps its click.
        if let under = page.annotation(at: view.convert(point, to: page)),
           under.type == "Link" || under.type == "Widget" || under.action != nil { return nil }
        // As for a direct hit: a hidden annotation, or one carrying a link or other
        // action, is never taken for a pin, whatever ownership it claims.
        for annotation in page.annotations where annotation.type == "FreeText"
            && annotation.shouldDisplay && annotation.action == nil
            && annotation.value(forAnnotationKey: MarkerCodec.ownerKey) as? String == MarkerCodec.ownerValue {
            guard let identifier = annotation.value(forAnnotationKey: MarkerCodec.identifierKey) as? String,
                  let marker = markers.first(where: { $0.id.uuidString == identifier }) else { continue }
            let frame = MarkerPinArtwork.screenFrame(view.convert(MarkerPin.footprint(of: marker, icon: annotation.bounds, on: page), from: page))
            if frame.contains(point) { return MarkerHit(marker: marker, anchor: frame) }
        }
        return nil
    }

    private static func directHit(at point: CGPoint, in view: PDFView, markers: [PDFMarker]) -> MarkerHit? {
        guard view.bounds.contains(point), let page = view.page(for: point, nearest: false),
              let annotation = page.annotation(at: view.convert(point, to: page)),
              annotation.shouldDisplay, annotation.action == nil,
              annotation.value(forAnnotationKey: MarkerCodec.ownerKey) as? String == MarkerCodec.ownerValue,
              let identifier = annotation.value(forAnnotationKey: MarkerCodec.identifierKey) as? String,
              let id = UUID(uuidString: identifier),
              let marker = markers.first(where: { $0.id == id }) else { return nil }
        // A bookmark's highlight lies under its pin's tab, so it opens the bookmark too.
        // A passage's highlight stays text for selecting.
        guard ["Text", "FreeText"].contains(annotation.type ?? "") || (annotation.type == "Highlight" && marker.isBookmark) else { return nil }
        return MarkerHit(marker: marker, anchor: view.convert(annotation.bounds, from: page))
    }
}
