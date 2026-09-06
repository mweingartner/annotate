# Architecture and API evidence

## Design

The reading surface stays central. A leading, resizable panel switches between category lists and search results; a trailing panel captures selection-based annotations. Notes and questions are independent fields, and categories are a set rather than an exclusive enum. This lets the same important passage appear in the questions list without duplicate highlights. Icons and labels accompany colors so category meaning is not color-only. SwiftUI owns the panels and visual state; PDFKit owns text selection, page rendering, scrolling, zooming, and printing.

AppKit `NSDocument` manages document windows, file opening, saving, autosave, dirty state, and undo. `ReaderModel` coordinates the live PDF and SwiftUI state on the main actor. Disk reads use isolated byte storage until the window initializes. Search is debounced, cancellable, and cooperatively yields between PDF pages. All PDF objects belonging to the reader remain on the main actor.

Marker values use versioned, bounded Codable metadata in a custom PDF annotation key. Each selected line has its own highlight rectangle; a standard FreeText annotation carries a printable symbol, and an owned Text/comment annotation carries the full human-readable note and question. Highlights have empty standard contents to avoid PDFKit synthesizing comment controls outside their hit bounds. A private owner tag and UUID associate the annotations belonging to one marker. Applying a replacement validates and constructs the new annotations before deleting the old ones. Deletion only touches annotations owned by that marker. Loading treats all PDF metadata as untrusted and ignores invalid/unsupported entries without deleting their visible PDF annotations.

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

## Note details and contrast

`SelectionPDFView.hitTest` routes only Annotate-owned comment tags and margin badges to its mouse handlers. Highlights, ordinary page text, foreign annotations, links, and forms stay with PDFKit. A tag click opens a SwiftUI details view in a transient NSPopover; dragging a tag or releasing elsewhere cancels the click. The panel uses semantic text and background colors, separately labeled note/question/passage sections, bounded scrolling, and an explicit Edit action. Editing resolves the current marker by UUID; marker mutations and document replacement dismiss stale details. Changed drafts disable the edit action.

Marker glyphs and swatch checkmarks choose black or white according to sRGB relative luminance. Printable badges use opaque fills so contrast does not depend on the PDF underneath. Teal controls adapt to light/dark appearance, and stronger selected outlines respond to Increase Contrast. Search results emphasize matches with bold semantic text.

## Version 2 document workspace

The version 2 design is in [WORKSPACE_DESIGN.md](WORKSPACE_DESIGN.md). `ReaderModel` now coordinates tool panels, transactional document snapshots, live on-page text editing, source revisions, and cancellable operations. The original marker codec, selection-based marker workflow, search navigation, and flattened annotation index remain compatible.

`PDFNativeTextEditor` removes the selected encoded glyphs from original text operations, compensates their advances so neighboring glyph positions remain unchanged, and embeds selectable replacement text generated by Core Text. A bounded native PDF object graph preserves reachable source resources, annotations, vectors, and document structure. Rich attributed text and selection are shared between the on-page editor and the typography panel; fonts and paragraph metrics are converted between PDF points and zoomed display coordinates. Source matching and fit failures leave the last valid PDF unchanged and prevent a misleading save of unapplied text. See [NATIVE_TEXT_EDITING.md](NATIVE_TEXT_EDITING.md) for supported syntax and explicit limits.

`PDFContentEditor` performs actual pixel removal for sanitized redaction, creating a fresh image-only document without source dictionaries. Its earlier raster area-replacement API remains an independently tested core utility; the live text editor does not use that route. Standard free-text appearance strings retain typography for legacy annotations and marker symbols through PDFKit/AnnotationKit serialization, including the PDF Name-versus-string distinction for slash-prefixed values.

Page assembly, form widgets, and electronic signature logic are separate native services. Conversion uses AppKit, ImageIO, PDFKit, Core Text, and Vision. Document snapshots isolate asynchronous OCR and image export from concurrent edits. The document assistant is now an optional network capability: Ollama uses loopback, OpenAI/Claude require explicit reviewed-text generation and Keychain keys, and Apple Intelligence uses the local system model. See the linked feature designs for concrete APIs, original sources, and fidelity limits.

`PDFNativeImageEditor` rewrites individual Image XObject invocations and clones only the affected shared Form resource path. It supports native replacement/deletion and bounded geometry changes without covering the source. Fingerprints reject stale image selections. The image session stages replacement and frame changes for one transactional Apply, with save/close guards for unapplied controls; see [IMAGE_EDITING_DESIGN.md](IMAGE_EDITING_DESIGN.md).
