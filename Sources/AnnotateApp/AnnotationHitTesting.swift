import AnnotateCore
import AppKit
import PDFKit

struct MarkerHit {
    let marker: PDFMarker
    let anchor: CGRect
}

/// Intercept explicit owned tags and badges, leaving passage text selectable.
@MainActor
enum AnnotationHitTesting {
    static func hit(at point: CGPoint, in view: PDFView, markers: [PDFMarker]) -> MarkerHit? {
        guard view.bounds.contains(point), let page = view.page(for: point, nearest: false),
              let annotation = page.annotation(at: view.convert(point, to: page)),
              annotation.shouldDisplay, annotation.action == nil,
              ["Text", "FreeText"].contains(annotation.type ?? ""),
              annotation.value(forAnnotationKey: MarkerCodec.ownerKey) as? String == MarkerCodec.ownerValue,
              let identifier = annotation.value(forAnnotationKey: MarkerCodec.identifierKey) as? String,
              let id = UUID(uuidString: identifier),
              let marker = markers.first(where: { $0.id == id }) else { return nil }
        return MarkerHit(marker: marker, anchor: view.convert(annotation.bounds, from: page))
    }
}
