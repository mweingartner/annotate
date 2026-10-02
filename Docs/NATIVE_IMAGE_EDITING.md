# Native editing of existing PDF images

`PDFNativeImageEditor` enumerates and edits image XObject invocations in original PDF content streams. Replacing or deleting an image changes its original `Do` operation and resource reference. Moving/resizing surrounds that one invocation with a balanced graphics-state transform. These operations do not cover the old image, add an annotation, or rasterize a PDF page.

## Interface and geometry

All APIs run on the main actor and return a new document after successful writing and reopening; source documents remain unchanged on success or failure.

- `images(in:pageIndex:)` returns `PDFNativeImage` values with `id`, `pageIndex`, `bounds`, `pixelSize`, `canTransform`, and `unsupportedReason`.
- `preview(in:image:maximumDimension:)` renders the selected image's page area. Overlapping page artwork can appear in this preview; it is not an isolated image extraction.
- `update(in:image:bounds:replacement:)` applies movement/resizing, replacement with a `CGImage`, or both in one transaction. Nil bounds preserve placement; nil replacement preserves original pixel resources.
- `remove(in:image:)` removes only the selected image invocation.

Bounds use unrotated PDF page coordinates, matching `PageRegion`. Page crops and rotation remain unchanged. Source axis-aligned and quarter-turn transforms, including mirrored images, preserve their orientation during movement/resizing. Changed bounds must be finite, at least one point per dimension, within the crop box, and within enclosing Form bounds. Originally cropped placements can still be replaced at their existing bounds or removed.

Each selection token fingerprints its source content, placement, and full image resource graph. A token cannot silently edit a different image after a source change, including changed image bytes at identical geometry and pixel dimensions. The app adds document identity/revision checks and an explicit Apply action for one undo checkpoint.

## Preservation and limits

The parser reads graphics state and image/Form invocations without decoding source fonts. Shared image resources and nested Forms are copied only along the selected invocation path. Other invocations and other pages retain their original resources. The old resource name is removed when no surviving invocation uses it, including inherited resource references in unchanged Form descendants. The graph writer emits only reachable objects. This is content editing, not a claim that all copies of an image elsewhere in the document are redacted.

Original image encodings, color spaces, masks, and Decode arrays can remain intact during movement and deletion because those operations preserve their resource objects. Replacement pixels are rendered at their own pixel dimensions, stored as lossless RGB, and retain transparency through an 8-bit grayscale soft mask. Existing surrounding graphics state and paint order remain in effect. New image storage can increase file size. Replacement images are limited to 32,768 pixels per dimension and 80 million pixels total.

Skewed/oblique or singular source transforms and custom clipping paths disable movement/resizing with a specific explanation. In-place replacement and deletion remain available where source geometry permits. Inline-image content, recursive or malformed forms, and unsafe resource sizes fail explicitly. Encrypted documents cannot be rewritten while preserving their encryption through this engine; copying and document-change permissions are enforced. Rewriting a digitally signed document changes its signed bytes.

Limits apply to aggregate work, not just nesting: 4,000 Form instances/images, 500,000 content operations, and 256 MB of expanded content per page. Fingerprinting memoizes repeated indirect references and caps aggregate visits at 200,000 and hashed data at 512 MB per enumeration. These prevent repeated shared-resource graphs from causing exponential expansion. Native graph serialization also enforces its own object/byte limits.

## Verification

`NativeImageEditingTests` covers all four crop/page rotations, native geometry, movement, resizing, replacement alpha against direct CoreGraphics rendering, deletion with original stream bytes absent, exact surrounding source pixels, overlapping vector paint order, unchanged searchable neighbor positions, saved annotation metadata, shared images on another page and inside a repeated Form, stale raw-image bytes at the same geometry, invalid bounds, explicit clipping/skew limits, Apple-produced compressed content with subset-font text, and bounded shared-resource graphs.

The generated `build/Image-Editing-Smoke.pdf` contains an opaque image, a transparent image, and the native heading “IMAGE EDITOR SMOKE” for installed-app verification.

## Primary sources

Three primary sources informed this implementation:

1. [Adobe-hosted ISO 32000-1:2008](https://opensource.adobe.com/dc-acrobat-sdk-docs/standards/pdfstandards/pdf/PDF32000_2008.pdf), clauses 8.3–8.4 (coordinate systems and graphics state), 8.9 (images and masks), and 8.10 (Form XObjects).
2. [PDF Association graphics errata for ISO 32000-2](https://pdf-issues.pdfa.org/32000-2-2020/clause08.html), balanced graphics-state operations, image dictionaries, masks, and Forms.
3. [Apple CGContext.drawPDFPage](https://developer.apple.com/documentation/coregraphics/cgcontext/drawpdfpage(_:)), direct source PDF rendering for area previews and preservation checks.
