# Architecture and API evidence

## Design

The reading surface stays central. A leading, resizable panel switches between category lists and search results; a trailing panel captures selection-based annotations. Notes and questions are independent fields, and categories are a set rather than an exclusive enum. This lets the same important passage appear in the questions list without duplicate highlights. Icons and labels accompany colors so category meaning is not color-only. SwiftUI owns the panels and visual state; PDFKit owns text selection, page rendering, scrolling, zooming, and printing.

AppKit `NSDocument` manages document windows, file opening, saving, autosave, dirty state, and undo. `ReaderModel` coordinates the live PDF and SwiftUI state on the main actor. Disk reads use isolated byte storage until the window initializes. Search is debounced, cancellable, and cooperatively yields between PDF pages. All PDF objects belonging to the reader remain on the main actor.

Marker values use versioned, bounded Codable metadata in a custom PDF annotation key. Each selected line has its own highlight rectangle; a standard FreeText annotation carries a printable symbol. A private owner tag and UUID associate the annotations belonging to one marker. Applying a replacement validates and constructs the new annotations before deleting the old ones. Deletion only touches annotations owned by that marker. Loading treats all PDF metadata as untrusted and ignores invalid/unsupported entries without deleting their visible PDF annotations.

Flattening draws PDF pages and visible annotations into a fresh Core Graphics PDF context. Core Text paginates a complete annotation index, including arbitrarily long text within the validated per-marker storage limits. Export verifies that the resulting PDF contains no annotation objects. It does not overwrite the currently open editable PDF.

## Primary sources

Eight original Apple documentation sources inform the implementation; installed Xcode SDK headers and executable tests verify exact signatures and runtime behavior. Documentation describes APIs, while the verification report records what was actually observed.

1. [PDFKit overview](https://developer.apple.com/documentation/pdfkit) — PDFView, PDFDocument, PDFSelection, page and annotation APIs.
2. [NSDocument](https://developer.apple.com/documentation/appkit/nsdocument) — native file lifecycle, save, windows, undo, and print integration.
3. [NSDocument autosavesInPlace](https://developer.apple.com/documentation/appkit/nsdocument/autosavesinplace) — in-place autosave and nonisolated class behavior.
4. [PDFDocument printOperation(for:scalingMode:autoRotate:)](https://developer.apple.com/documentation/pdfkit/pdfdocument/printoperation(for:scalingmode:autorotate:)) — native system print operation.
5. [PDFPage draw(with:to:)](https://developer.apple.com/documentation/pdfkit/pdfpage/draw(with:to:)) — drawing pages and their visible annotations for flattened export.
6. [SwiftUI updates](https://developer.apple.com/documentation/updates/swiftui) — Observation-based state, native inspector concepts, current macOS styling, and Liquid Glass support.
7. [PDFAnnotation setValue(_:forAnnotationKey:)](https://developer.apple.com/documentation/pdfkit/pdfannotation/setvalue(_:forannotationkey:)) — custom metadata fields embedded in standard PDF annotations.
8. [CTFrameGetVisibleStringRange](https://developer.apple.com/documentation/coretext/ctframegetvisiblestringrange(_:)) — advancing the text cursor by the range actually rendered on each notes-index page.

## Code map

- `Sources/AnnotateCore`: portable marker values plus macOS PDF persistence, export, and generated sample.
- `Sources/AnnotateApp`: document lifecycle, commands, observable reader model, PDFView bridge.
- `Sources/AnnotateApp/Views`: composed SwiftUI reading, list, search, and annotation panels.
- `Tests`: executable behavioral tests with generated, deterministic PDF fixtures.
- `Resources`: app metadata and icon.
- `Scripts`: reproducible build and icon generation.
