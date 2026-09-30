# Native PDF text editing

The user's requirement is direct editing of original PDF text. `PDFNativeTextEditor` removes selected encoded glyphs from source content streams and writes replacement text as real PDF text. The engine does not rasterize pages, cover original text with a rectangle, or save replacement text as a FreeText annotation.

## Public interface

```swift
PDFNativeTextEditor.replace(
    in: PDFDocument,
    region: PageRegion,
    originalText: String,
    replacement: NSAttributedString,
    destination: PageRegion? = nil
) throws -> PDFDocument
```

The original region identifies the glyphs to remove. The optional destination is on the same page and controls replacement position and layout independently. Empty original text inserts native text; empty replacement deletes the matched source text. A new document is returned only after serialization and reopening succeed. The input document is not mutated.

## Content preservation

Core Graphics decodes the original object graph, including compressed content and object streams. The graph writer retains page dictionaries, crops, rotations, annotations, resource dictionaries, vectors, and surviving text. Dictionary, array, and stream identities preserve shared references and legal cycles. The output contains only objects reachable from the final catalog and information dictionary. It is a fresh object graph with cross references, not an incremental append that leaves retired source streams in the file.

The native tokenizer retains string bytes and operator byte ranges. Font decoding uses source `ToUnicode` CMaps, `bfchar`/`bfrange`, simple font encodings and differences, and Identity-H CID font widths. The text interpreter follows `Tj`, `TJ`, both quote operators, font and spacing state, text matrices, graphics state, and nested Form XObjects. Selected glyph codes are removed. Numeric `TJ` adjustments preserve their original advances, so unrelated following glyphs keep their coordinates. Other operators remain unchanged.

A shared Form XObject is cloned for the edited invocation. Other invocations retain the original. An unused original form resource is removed when its last invocation on that content path is replaced.

CoreText lays out attributed replacement text using the requested fonts, sizes, colors, and per-range styles in a new PDF context. Those embedded PDF font resources and native text streams are imported into a Form XObject on the destination page. The replacement is inserted after the selected text object's `ET`, preserving later artwork's paint order. The insertion cancels the enclosing transformation, and the generated form resets inherited text spacing, rendering mode, alpha, blend mode, and soft mask before applying replacement styles. Existing enclosing clipping remains in effect. The visible character range must include the entire replacement; overflow fails explicitly instead of truncating text.

The source-style extractor reads the actual content-stream font, effective page font size, and fill color. It does not trust PDFKit's sometimes-substituted selection font. Named device/ICC color spaces and standard source color operators are tracked. Unavailable fonts are disclosed by the editor; unsupported source colors retain PDFKit's fallback attributes.

## Supported scope and explicit limits

Ordinary selectable horizontal PDF text is supported, including the compressed subset-font PDFs produced by Apple frameworks, TJ positioning arrays, partial text-show strings, nested/reused forms, crop offsets, and quarter-turn page rotations. Movement and resizing use an independent destination rectangle. This is fixed-area editing: neighboring paragraphs are preserved in place, and text is not reflowed through the rest of the document. The reader may enlarge the destination rectangle downward when the replacement needs another line and the added area holds no page text (see INTERFACE_DESIGN.md).

The engine fails explicitly for encrypted source files, external stream data, content streams with inline images during source replacement, Type 3 glyph programs, vertical writing, unimplemented predefined CMaps, missing usable character maps or widths, selected clipping text, and page content containing ActualText accessibility replacement strings. Native insertion does not need to decode existing fonts or inline images. Invisible OCR text raises the distinct `scannedText` error; changing only its hidden layer would leave the scanned image's original words visible. Partial selections inside a single source ligature also fail rather than deleting extra unselected characters.

## Explicit scanned-text mode

`replaceScanned(in:region:originalText:replacement:destination:)` has the same argument types as `replace`. The app presents this as a separate choice explaining that the original scan pixels will change. The selection must lie entirely in invisible OCR text within exactly one source image. The engine removes matched OCR glyphs, decodes that original image at its original pixel dimensions, replaces the selected rectangle with verified surrounding paper color, and writes the requested text as visible, searchable native PDF content. It does not rasterize the rest of the page. Deleting text removes both its scan pixels and OCR; moving text clears the original area and inserts at the requested destination.

Accepted source images are RGB/grayscale with device or ICC color spaces, 8-bit raw RGB/gray or 1-bit raw gray, and JPEG/JPEG2000 decoded by ImageIO. Axis-aligned scaling and quarter-turn transforms are supported, including page crop offsets and rotations. The edited image is stored as lossless RGB, which can increase file size. Other references to the original image retain their source data; only the edited invocation receives a new image resource. Unreachable retired objects are omitted from the output.

The mode refuses masks, alternate image representations, custom Decode arrays, skewed transforms, ambiguous overlapping images, overlap with neighboring OCR text, and selections too close to image edges. It requires a nearly uniform sampled border and rejects colored non-paper pixels within the patch; patterned paper, photographs, and colored artwork cannot be reconstructed safely. This bounded paper-and-ink operation does not reconstruct hidden background details, distinguish monochrome artwork inside the selected rectangle, or reflow a scanned layout. Separate [native existing-image editing](NATIVE_IMAGE_EDITING.md) provides replacement, movement, resizing, and deletion of image XObjects. Source scan images are limited to 16,384 pixels per dimension and 40 million pixels total.

Source text is matched by both location and normalized Unicode. Ambiguous or mismatched selections fail. Parser depth, object, byte, and numeric limits prevent runaway structures. Core Graphics performs stream decoding, so this adds no third-party PDF runtime dependency.

Rewriting changes the file bytes. This engine does not preserve existing cryptographic digital-signature validity or the byte identity of an archival/certified original. Source font programs remain necessary for surviving source text; unused characters in those font programs are not a redaction claim. This feature edits text and preserves document content, while the separate redaction export is the sanitization workflow.

## Verification

`NativeTextEditingTests` verifies exact original-text removal from search and saved reachable content, unchanged adjacent text coordinates and vector operators, annotation preservation, repeated editing of embedded replacement fonts, font family/size after reopen, all four page rotations with a nonzero crop origin, insertion, deletion, shared-form instance isolation, moved mixed-style text, overlapping artwork, overflow, and mismatch rollback. `NativeObjectGraphTests` verifies page/form round trips, pixel-identical unchanged page rendering, and omission of unreachable streams. `NativeTextStyleTests` covers actual subset/variable font resolution, mixed fonts/colors, source transformations, Unicode, and substitution disclosure.

`NativeScanEditingTests` uses a generated scanned page processed by real Vision OCR. It verifies visible replacement, complete source-letter pixel deletion, absent original OCR, unchanged neighbor geometry and outside content pixels, preservation of another page's original image, annotation metadata, crop/rotation, save/reopen, and rejection of patterned backgrounds without changing the source. Annotation appearance rendering is tested separately from source-content pixels because PDFKit can normalize note-icon appearances while serializing. The test retains a disposable `build/Scanned-Editing-Smoke.pdf` for installed-app verification. `NativeTextPerformanceTests` measures synthetic four- and hundred-page edits; a representative debug run was 24 ms and 122 ms respectively. These timings are observations, not performance guarantees. No network service or external PDF utility is required.

## Primary sources

Six primary sources informed this implementation:

1. [Adobe-hosted ISO 32000-1:2008](https://opensource.adobe.com/dc-acrobat-sdk-docs/standards/pdfstandards/pdf/PDF32000_2008.pdf), clauses 7 (objects, streams, references), 8 (graphics state/forms), and 9.4–9.10 (text operators, displacement, fonts, Unicode maps).
2. [PDF Association's ISO 32000-2 text errata](https://pdf-issues.pdfa.org/32000-2-2020/clause09.html), including horizontal scaling, text-state push/pop, and `T*` behavior.
3. [Apple CGPDFDictionary](https://developer.apple.com/documentation/coregraphics/cgpdfdictionary), dictionary enumeration and object lifetime within the retained CGPDFDocument.
4. [Apple CGPDFStreamCopyData](https://developer.apple.com/documentation/coregraphics/cgpdfstreamcopydata(_:_:)), decoded stream data and raw/JPEG/JPEG2000 format handling.
5. [Apple CTFrameGetVisibleStringRange](https://developer.apple.com/documentation/coretext/ctframegetvisiblestringrange(_:)), checking that replacement layout includes every character.
6. [Apple CGImageSourceCreateImageAtIndex](https://developer.apple.com/documentation/imageio/cgimagesourcecreateimageatindex(_:_:_:)), decoding the original source image for explicit scan pixel editing.

## Font map resource limits

Character-map decoding limits source data to 16 MiB, tokens to 262,144, total attempted mappings to 131,072, and aggregate decoded mapping storage to 8 MiB. Repeated and overlapping ranges consume the same aggregate work budget as unique ranges, preventing small range declarations from expanding into billions of assignments. Adversarial tests exercise repeated ranges and long Unicode destinations alongside valid Unicode and CID ranges.
