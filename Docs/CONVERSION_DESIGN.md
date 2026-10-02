# Native conversion, compression, and OCR

This design implements the conversion, batch processing, compression, and document-wide OCR portions of the [PDFgear Mac product page](https://www.pdfgear.com/pdfgear-for-mac/), accessed September 5, 2026. That page is a vendor requirements reference, not independent evidence of PDFgear's accuracy or privacy. The implementation uses Swift, PDFKit, AppKit text layout, ImageIO, Core Graphics, Core Text, and Vision. These operations do not send documents to a server and require no external conversion executable.

## User workflows

The Convert & recognize panel has four independent sections and batch processing. Import opens a new unsaved PDF. Text exports use a save dialog. Image exports create a folder containing naturally sorted page images. Compression prepares a separate copy and reports actual bytes before and after encoding. OCR opens a separate searchable PDF or exports recognized UTF-8 text. Original documents remain available. Batch conversion chooses inputs and a destination folder once, then presents one success or error result per processed input, with Finder access to successful results.

Available outputs are PDF, DOCX, DOC, ODT, RTF, TXT, HTML, XLSX, PPTX, PNG, JPEG, TIFF, and HEIC. PDF is the batch creation output; the other twelve are document export choices. Inputs are PDF, TXT, RTF, RTFD, DOC, DOCX, ODT, and ImageIO-supported images. All pages of a TIFF become PDF pages. Animated image formats import their first frame. Image orientation metadata is applied during decoding, with an 8192-pixel maximum edge.

## Conversion architecture

`PDFConversion.extractedText` obtains each page's attributed text and inserts page separators. AppKit serializes text outputs into their actual document formats. PDF text does not inherently describe editable Word paragraph flow or Office table/slide structure. Therefore text exports retain available text and styling but do not promise reconstruction of original page layouts, images, spreadsheets, tables, or slide objects. The limitation is stated beside the export control.

Word, RTF, and OpenDocument imports use AppKit's attributed-string readers, then `NSTextStorage`, `NSLayoutManager`, and sequential `NSTextContainer` objects to paginate onto 612 × 792 point pages with 48-point margins. Available attributed styling and supported attachments are drawn by AppKit. Original Office page breaks, floating objects, formulas, charts, macros, document-level pagination and exact Word layout are not reproduced. Imported output requires visual review. Arbitrary HTML import is deliberately not offered because external HTML resources require a separate resource-loading policy; HTML export remains available.

Image rendering uses the page's displayed crop size, respecting quarter-turn rotation. A white background avoids transparent page backgrounds. Exports support 72, 144, or 216 pixels/inch and include visible annotations. Image memory is bounded to 64 million pixels and a 32,768-pixel edge per rendered page. Inputs larger than 1 GB are rejected; text pagination and TIFF imports are capped at 20,000 pages. Those are safety bounds, not a promised capacity benchmark.

## Native Excel and PowerPoint exports

`PDFOfficeExporter` writes actual OpenXML packages using Swift and a bounded stored-ZIP writer with CRC32, local headers, central directory, and end-of-directory records. No Office installation, external process, network request, or conversion service is used. XLSX creates one worksheet per source PDF page, one row per extracted line, and splits tabs or runs of two or more spaces into text cells. Inline strings preserve leading zeros and keep PDF text beginning with `=` from becoming an executable spreadsheet formula. Cells wrap, and rows receive estimated heights. This is a reading-order text export: original tables, numeric types, formulas, charts, and merged cells are not reconstructed. PDFKit's extracted character mappings and spacing remain authoritative; OCR is required for scanned pages.

PPTX creates one slide per PDF page with a 144 ppi PNG image including visible annotations. A complete slide master, blank layout, theme, presentation properties, and package relationships are included. Slide dimensions follow the first page's aspect ratio, with later pages fitted and centered without distortion. Each page image can be moved or resized in a presentation editor; the text and images within the page are not separate slide objects. The source PDF's reading text remains in the PDF, but the PPTX page copy is an image.

The Office package limit is 512 MB. XLSX additionally limits source text to 128 MB per page, one million worksheet rows, 16,384 columns, and the Excel 32,767 UTF-16-unit cell limit; values exceeding limits produce an error rather than truncation. PPTX is limited to 2,000 slides and retains the shared per-page rendering bounds. ZIP entries are stored without deflate compression; PNG images are already compressed.

## Compression

The original-quality setting requests neither lossy image conversion nor screen optimization. Balanced enables PDFKit's `saveImagesAsJPEGOption`. Compact additionally enables `optimizeImagesForScreenOption`. Apple defines these as JPEG encoding and screen-appropriate image resolution; the API does not expose a precise target DPI or JPEG quality setting here. Therefore the UI does not invent one.

Compression rewrites PDF resources instead of converting entire pages to images. Searchable text, annotations, marker metadata, and widget values remain available and have round-trip tests. The original-quality path can still rewrite internal PDF representation; it is not byte preserving. The before/after measurement is based on the current serialized document for single-document work and the original PDF file's size for a batch input. Results may be larger, and that outcome is reported plainly. Saving a rewritten PDF does not preserve certificate signature validity.

## OCR geometry and execution

Vision runs in a dedicated actor, leaving the main UI executor free while its synchronous recognition request works. Each page is processed sequentially. Page rendering and PDFKit access remain on the main actor. Before processing yields, the source permissions are checked and PDFKit makes a detached document copy, so native form edits or page changes cannot alter later pages of an in-progress export. Cancellation is checked between pages and recognition stages. The recognition image uses the unrotated crop at 144 pixels/inch so `/Rotate` metadata does not make the words sideways to Vision. Vision provides normalized lower-left-origin text boxes; Core Text draws an invisible text line fitted to each box, using the same quarter-turn transformation as the visible page.

By default, pages with selectable text retain their existing vector/text drawing and are not recognized again. Scanned pages receive invisible OCR text over their original visible PDF drawing. The searchable output normalizes each displayed crop to a new media box with zero rotation. This preserves displayed page dimensions and geometry, while discarding material outside the displayed crop. Forms and annotation appearances are flattened into visible content. Source annotation display flags and rotations are restored.

The optional “Recognize pages that already contain text” mode recognizes every page. Its 144 ppi raster becomes the visible background so old and new text layers do not duplicate words. This has a visible quality tradeoff explained beside the toggle. OCR text is approximate: recognition order, language detection, mathematical notation, handwriting, small text, complex tables, and unusually oriented artwork may require correction. No accuracy percentage is claimed. Explicit language choices are checked against Vision's supported languages on the running Mac.

## Permissions and writes

Locked PDFs are rejected. Text extraction requires copying permission. Rendering and OCR require copying and printing permissions. Compression additionally requires document-change permission. None of these gates use commenting permission as a substitute for content permissions.

Batch processing stages each result in the selected output folder and moves it into place with a filesystem operation that refuses replacement. An existing name is assigned a numbered suffix; a race with another writer retries the next name. Multipage image outputs are staged as a whole folder. Each file is processed independently, so a damaged input does not discard successful siblings. Image pages are encoded and written sequentially rather than retained as an entire batch of image data in memory. Temporary staging files are removed on success or failure. Single-document save dialogs use the shared application output helper, which prevents replacing the open source PDF.

## Validation and remaining parity gaps

`ConversionTests` covers actual DOCX/DOC/ODT/RTF/TXT/HTML round trips with Unicode; multipage Office/text import with every numbered paragraph retained; all image outputs at all four page rotations; TIFF multi-page import; compression preserving text, marker notes, and an interactive form value; and rejected malformed, empty, oversized-render and restricted inputs. `ConversionBatchTests` covers per-file failure isolation, byte-identical preservation of an existing file, numbered names, ordered multipage image output and staging cleanup. `OCRTests` uses generated image-only scanned PDFs and verifies two-page recognition, search selection location, red-sentinel visual geometry at all four rotations, retained source text without duplication, forced recognition, and language validation.

The PDFgear page advertises over 30 output formats and Excel/PowerPoint conversion. This implementation offers the 13 actual output formats above, including Excel text-cell and PowerPoint page-image exports; it does not claim equivalent Excel table/formula or PowerPoint object reconstruction. Excel and PowerPoint import require exporting to PDF in their originating app. Fully faithful Office layout conversion, proprietary formats and certificate-preserving rewrite are outside the native implementation. These are substantive parity gaps rather than hidden menu placeholders.

## Original sources

Eleven original web sources informed this scope and design (one vendor page, seven Apple references, two Microsoft format references, and the PKWARE ZIP specification), plus the installed Apple SDK headers. Relevant SDK declarations were verified in Xcode-beta's macOS 27 SDK; the project deployment target remains macOS 26.

1. [PDFgear for Mac](https://www.pdfgear.com/pdfgear-for-mac/) — requested product scope; vendor claims are not treated as independently validated facts.
2. [Apple: PDFPage drawing](https://developer.apple.com/documentation/pdfkit/pdfpage/draw(with:to:)) — page drawing API. `PDFPage.h` additionally documents that drawing accounts for page rotation and the selected display box.
3. [Apple: saveImagesAsJPEGOption](https://developer.apple.com/documentation/pdfkit/pdfdocumentwriteoption/saveimagesasjpegoption) — native image encoding option; behavior is also documented in `PDFDocument.h`.
4. [Apple: optimizeImagesForScreenOption](https://developer.apple.com/documentation/pdfkit/pdfdocumentwriteoption/optimizeimagesforscreenoption) — native screen image optimization option; behavior is also documented in `PDFDocument.h`.
5. [Apple: Office Open XML attributed-string document type](https://developer.apple.com/documentation/foundation/nsattributedstring/documenttype/officeopenxml) — native Word text document format. `NSAttributedString.h` declares the input/output document types and serialization interfaces.
6. [Apple: NSLayoutManager](https://developer.apple.com/documentation/appkit/nslayoutmanager) — text layout and glyph drawing used to paginate imported attributed text and supported attachments.
7. [Apple: Recognizing text in images](https://developer.apple.com/documentation/vision/recognizing-text-in-images) — accurate recognition, language settings, and recognized text observations.
8. [Apple: Invisible Core Graphics text drawing mode](https://developer.apple.com/documentation/coregraphics/cgtextdrawingmode/invisible) — hidden text rendering used for the searchable PDF layer.

9. [Microsoft: SpreadsheetML document structure](https://learn.microsoft.com/en-us/office/open-xml/spreadsheet/structure-of-a-spreadsheetml-document) — workbook, sheet, relationship, and package-part structure.
10. [Microsoft: PresentationML document structure](https://learn.microsoft.com/en-us/office/open-xml/presentation/structure-of-a-presentationml-document) — slides, master, layout, theme, and relationship requirements.
11. [PKWARE: ZIP file format specification](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT) — stored ZIP records and CRC32.

`OfficeExportTests` verifies ZIP CRCs, well-formed XML, preserved Unicode and literal formula-like strings, worksheet and slide counts, PNG payload dimensions, rotated crop dimensions, invalid-source handling, and archive path/duplicate rejection. An independent Python standard-library ZIP reader validated all generated CRCs and parsed every XML part. macOS QuickLook generated and displayed thumbnails for both a sample XLSX and PPTX, providing an independent format-consumer smoke check. Microsoft Excel and PowerPoint desktop applications were not used for these checks; their edit-and-resave behavior remains a separate interoperability validation.
