import AnnotateCore
import AppKit
import PDFKit

/// Who draws a marker's icon.
///
/// Every marker is saved as standard PDF annotations (a highlight, a small icon box and a
/// comment) so that any PDF reader shows it. In Annotate's own viewer the icon is drawn
/// instead as a native pin over the page (`MarkerPinOverlay`), so the viewer's copies of
/// the icon box and comment skip drawing. (PDFView renders highlights itself without
/// asking the annotation, so a bookmark's small highlight is covered by its pin instead.)
/// Printing, exporting and converting draw the page for output. There each marker's
/// icon is drawn as the same glass pin the viewer shows (`MarkerPinArtwork`), and the
/// comment's speech bubble is left out (an export lists every note in its index). The
/// file itself is unchanged.
@MainActor
enum MarkerChrome {
    /// Installed on every document the reader displays, so parsed annotations of the
    /// affected types are created as `ViewerMarkerAnnotation`.
    static let documentDelegate = DocumentDelegate()

    private static var outputDepth = 0

    /// What a marker's pin looks like and which line it marks, by marker identifier.
    struct Pin: Equatable {
        let symbol: String
        let color: MarkerColor
        let line: CGRect?
        let isBookmark: Bool
    }
    private static var pins: [String: Pin] = [:]

    /// Records the pins of a document's markers. Identifiers are unique across
    /// documents, so several open documents share the table.
    static func remember(_ markers: [PDFMarker]) {
        for marker in markers {
            pins[marker.id.uuidString] = Pin(symbol: marker.icon, color: marker.color,
                                             line: marker.regions.first?.bounds, isBookmark: marker.isBookmark)
        }
    }

    static func isOwnedComment(_ annotation: PDFAnnotation) -> Bool {
        annotation.type == "Text" && marksKnownMarker(annotation)
    }

    /// The pin to draw for output in place of a marker's icon annotation, and where.
    static func outputPin(for annotation: PDFAnnotation) -> (pin: Pin, frame: CGRect)? {
        guard annotation.type == "FreeText",
              annotation.value(forAnnotationKey: MarkerCodec.ownerKey) as? String == MarkerCodec.ownerValue,
              let id = annotation.value(forAnnotationKey: MarkerCodec.identifierKey) as? String,
              let pin = pins[id] else { return nil }
        return (pin, MarkerPinArtwork.frame(icon: annotation.bounds, line: pin.line, isBookmark: pin.isBookmark))
    }

    /// Runs work that draws pages for output (print, export, conversion, redaction)
    /// with every marker annotation drawn exactly as saved.
    static func drawingForOutput<T>(_ work: () throws -> T) rethrows -> T {
        outputDepth += 1
        defer { outputDepth -= 1 }
        return try work()
    }

    static func drawingForOutput<T>(_ work: () async throws -> T) async rethrows -> T {
        outputDepth += 1
        defer { outputDepth -= 1 }
        return try await work()
    }

    /// Makes MarkerCodec create new marker annotations as viewer annotations too, so a
    /// marker added in this session looks the same as one read from the file.
    static func install() {
        MarkerCodec.makeAnnotation = { ViewerMarkerAnnotation(bounds: $0, forType: $1, withProperties: nil) }
    }

    static func isDrawnByViewer(_ annotation: PDFAnnotation) -> Bool {
        guard outputDepth == 0, NSPrintOperation.current == nil,
              annotation.type == "FreeText" || annotation.type == "Text" else { return false }
        return marksKnownMarker(annotation)
    }

    /// Only an annotation that belongs to a marker Annotate actually read (and so draws a
    /// pin for) is ever left undrawn. An annotation that merely claims Annotate's owner
    /// key draws as saved.
    private static func marksKnownMarker(_ annotation: PDFAnnotation) -> Bool {
        guard annotation.value(forAnnotationKey: MarkerCodec.ownerKey) as? String == MarkerCodec.ownerValue,
              let id = annotation.value(forAnnotationKey: MarkerCodec.identifierKey) as? String else { return false }
        return pins[id] != nil
    }

    final class DocumentDelegate: NSObject, PDFDocumentDelegate {
        func `class`(forAnnotationType annotationType: String) -> AnyClass {
            annotationType == "FreeText" || annotationType == "Text" ? ViewerMarkerAnnotation.self : PDFAnnotation.self
        }
    }
}

/// A standard annotation that steps aside while Annotate's viewer draws the marker
/// itself. It is an ordinary annotation in every other respect, including when saved.
final class ViewerMarkerAnnotation: PDFAnnotation {
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        // PDFKit renders the reader's pages on the main thread. Anything drawn elsewhere
        // is not the viewer, so it is drawn as saved.
        // Checked only on the main thread, where PDFKit already holds this annotation.
        nonisolated(unsafe) let annotation = self
        nonisolated(unsafe) let output = context
        if Thread.isMainThread, MainActor.assumeIsolated({ () -> Bool in
            if MarkerChrome.isDrawnByViewer(annotation) { return true }
            // The comment carries the note for other PDF readers. Annotate's pin already
            // marks the passage, and an export lists every note in its index, so its
            // speech-bubble icon is not drawn in print or export either.
            if MarkerChrome.isOwnedComment(annotation) { return true }
            // For output, the icon is drawn as the viewer's glass pin.
            guard let (pin, frame) = MarkerChrome.outputPin(for: annotation) else { return false }
            MarkerPinArtwork.draw(symbol: pin.symbol, color: pin.color, in: frame, context: output)
            return true
        }) { return }
        super.draw(with: box, in: context)
    }
}
