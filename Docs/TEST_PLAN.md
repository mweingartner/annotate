# Annotate verification plan

## Recorded original-reader baseline

`swift test` passed on September 5, 2026: **57 test functions in ten suites, covering 137 scenarios** when parameterized cases are counted separately. The two targets reported 33 core tests and 24 app tests. The build emitted no compiler warnings. Execution used Apple Swift 6.4 on macOS 27.0 (26A5425a), Apple silicon, with a macOS 26 deployment target.

These are real PDFKit, CoreGraphics, CoreText, AppKit and document-model tests, without third-party dependencies or mocked PDF rendering. The document lifecycle test creates and closes an offscreen native reader window. The invalid-input test deliberately passes non-PDF bytes; CoreGraphics may log a PDF parser diagnostic while the test verifies a clean error.

This is the original reader baseline. Current workspace, native text, and assistant results are recorded separately in [WORKSPACE_VERIFICATION.md](WORKSPACE_VERIFICATION.md).

Run from the project directory:

```sh
swift test
```

For focused diagnosis:

```sh
swift test --filter MarkerCodecTests
swift test --filter PDFExporterTests
swift test --filter ReaderModelTests
swift test --filter AnnotateDocumentTests
```

## Automated acceptance coverage

| Area | What is verified |
| --- | --- |
| Sample document | Four readable, selectable-text pages; `attention` search hits on all four pages; no default annotations |
| PDF persistence | Categories, RGB color, icon, Unicode note, question, UUID, date and precise page regions survive actual PDF serialization and reopening |
| Annotation interoperability | Standard highlight and FreeText marker objects exist; human-readable comments survive; another reader's sticky note and popup are preserved during replacement/deletion |
| Safe replacement | Invalid page, negative dimensions, non-finite color, missing regions/categories and excessive note size fail before replacing existing saved work |
| Untrusted metadata | Malformed JSON, unsupported version, oversized payload, wrong data type, absent metadata, unknown categories and invalid page references are ignored while visible annotations remain |
| Line geometry | A full paragraph yields separate short line rectangles within its page; disconnected selections retain both source pages; empty selections produce no regions |
| Traversal | Reading position takes precedence over marker creation time; forward/backward traversal wraps; out-of-range page requests, including Int.min/Int.max, are ignored |
| Categories | Important and Revisit marks also appear in Notes or Questions when those fields are populated; whitespace-only supplemental text is excluded |
| Flattened export | Original text remains searchable; no annotation arrays with objects remain in underlying CoreGraphics page dictionaries; full notes/questions and source-page references appear in the index |
| Long content | A 220-item note spans eight index pages, with every numbered item and the final note/question sentinels recovered from the exported PDF |
| Existing PDF comments | Foreign sticky-note text is included in the readable appendix after its interactive popup is flattened away |
| Crop and rotation | All eight combinations of 0/90/180/270-degree rotation and uncropped/nonzero-origin crop retain expected dimensions, searchable text and a red visual sentinel's size/location |
| Appearance | A real rendered comparison verifies marker appearance survives flattening and the source page's annotation-display flag is restored |
| PDF permissions | Locked PDFs and reader-password PDFs with printing/copying/commenting disabled reject forbidden operations |
| Draft workflows | Selecting text opens a draft; color, icon, combined categories, note and question save together; changing selection cannot discard a changed draft; Cancel leaves the PDF unchanged |
| Location markers | A page with no selectable text accepts a Revisit location marker with a note and navigates to the saved bounds |
| Undo and Redo | Adding, editing and deleting each restore exact prior and next marker values, including the creation date |
| Search | Every case-insensitive match has a contextual snippet, emphasized search term, actual PDFSelection and correct page; rapid query replacement and clearing cancel stale results |
| Native documents | NSDocument reads and writes annotated PDFs; invalid input fails; close-cancellation invokes the Objective-C completion exactly once with false and the original document/context |

## Installed application acceptance checklist

The automated harness establishes data and rendering behavior. Run the following against the installed application and record results separately; this checklist itself does not claim that a UI step or physical print has passed.

1. Start an awake-session guard for the UI test. Launch the installed Annotate app and open the sample. Confirm the welcome screen, four-page tour and readable page layout at the default window size.
2. Select a multi-line passage on page 2. Confirm the annotation panel opens after selection, not while the mouse is still dragging. Enter both a note and a question; combine Important and Revisit, pick a custom color and a different icon, then save.
3. Confirm each line highlights separately, the marker icon is visible and the original text remains legible. Confirm the entry appears in Important, Revisit, Notes and Questions.
4. Add a second marker on page 4. Select entries in the panel and use previous/next controls. Confirm the reader reaches the exact saved passages and wraps at the ends of the list.
5. Edit a saved entry, cancel a changed draft, delete an entry, then exercise Undo and Redo from the app menu. Verify the visible PDF and lists match each action.
6. Search for `attention`. Confirm contextual rows and emphasized hits. Click a page-4 result and confirm the visible result matches the row. Replace the query quickly and clear it; stale results must not remain.
7. Save to a new PDF. Close and reopen it through Finder or the Open dialog. Verify categories, custom color, selected quote, notes, questions and locations are editable and unchanged.
8. Export to a different filename. Open the exported copy in Preview. Confirm visible highlights/icons and the readable notes index. Confirm original page count plus index pages, correct source-page references, selectable source text and complete notes.
9. Open Print. Check page preview, scaling and orientation. Cancel the dialog unless a physical print is intentionally requested. To include the notes appendix in printing, print the exported PDF.
10. Enter invalid page numbers, resize the window with both panels open, and check keyboard navigation, VoiceOver labels, light/dark appearance and Reduce Motion behavior.
11. Change a draft and close the window. Check Save Marker, Discard Changes and Cancel. Cancel must leave the app responsive, including when quitting the application.
12. Stop the awake-session guard and record that it stopped.

## Scope and release risks

- Runtime testing on this machine proves macOS 27 behavior. The macOS 26 deployment target is compiled but needs execution on a macOS 26 machine before claiming version-wide runtime compatibility.
- No finite test suite proves behavior for every malformed or unusual PDF. The synthetic crop/rotation cases and real PDFKit round trips cover the explicitly exercised cases; complex external PDFs, digital signatures, interactive forms and accessibility tagging need a broader fixture corpus.
- Flattened exports deliberately turn annotation objects into page content. The readable index preserves annotation comments, but interactive PDF features and digital-signature validity are not promised by this export route. Preserve the editable original.
- Source text remains searchable in the generated text fixtures. This does not promise OCR or searchable text for every image-only source PDF.
- A print dialog and correct preview do not prove a successful physical print. Report physical printer output separately.

## Primary references

Three Apple primary references informed the verification boundaries. Runtime assertions are the evidence for this implementation's actual behavior.

1. [PDFSelection](https://developer.apple.com/documentation/pdfkit/pdfselection) — selections can be contiguous or noncontiguous; per-line selections and per-page bounds support exact passage geometry.
2. [PDFPage.draw(with:to:)](https://developer.apple.com/documentation/pdfkit/pdfpage/draw%28with%3Ato%3A%29) — native page rendering into the export graphics context. Render equivalence and the absence of annotation dictionaries are tested independently.
3. [PDFDocument.accessPermissions](https://developer.apple.com/documentation/pdfkit/pdfdocument/accesspermissions) — the native permission boundary. The harness writes an encrypted test PDF and verifies the actual printing, copying and commenting restrictions after reader-password unlock.

## Note panel and readability regressions (1.0.1)

- Real PDF hit targets: two marker identities, four rotations and three zoom levels; owned comment tags/badges receive clicks, while highlights and unmarked text remain in PDFKit's selection view.
- Foreign comments, links, forms, overlapping annotations, malformed ownership and modified clicks retain native handling. Tag drags and releases outside/on another marker cancel the click.
- Legacy appearance migration preserves metadata and foreign annotations, is idempotent, and respects PDF commenting permissions. Explicit comment tags remain above/right after PDFKit save/reopen normalization.
- Five comment update/save/reopen cycles and final deletion do not accumulate owned popup companions or remove foreign ones.
- Black/white marker ink has at least 4.5:1 contrast for all presets, dark/custom cases, 1,331 sampled RGB colors and 256 grays; actual saved and flattened PDF raster pixels verify the ink and background.
- Accent colors are checked against light/dark and increased-contrast native backgrounds; the action fill's white label contrast exceeds 7:1.
- An 80-paragraph note remains in a bounded, fully scrollable popover in light and dark appearance. Delete and Undo dismiss captured details rather than leaving stale editable content.

See [the 1.0.1 report](POLISH_VERIFICATION.md) for observed installed-app checks and remaining limits.

## Version 2 workspace regression

Run `swift test` from the repository root. New suites cover full snapshot undo/redo and failed-operation rollback; native source-glyph removal and embedded replacement text surviving save/reopen; unchanged neighboring text coordinates, vector operators, annotations and shared-form invocations; actual installed font families/typefaces and mixed-run style preservation; selection synchronization without dirtying the PDF; invalid geometry/font input, overflow, fit-height and unapplied-edit recovery; and rotated/cropped live editor placement at multiple zoom levels. Marker actions also verify opening the editor from workspace tools, protecting unsaved drafts and unapplied native text, complete deletion undo, and accurate multi-page descriptions.

Other workspace suites cover actual redaction bitmap removal and absence of source text/metadata; page remapping, merge collisions, extraction/splitting; standard form widgets and electronic signature pixel persistence; native conversion roundtrips, OpenXML ZIP/XML validity and whole-document OCR; batch collision/failure isolation; and document-assistant provider contracts, context completeness, cancellation, source isolation, and bounded transport. Assistant interaction tests distinguish one-action local completion from mandatory cloud preparation/review, plus source-only recovery when no local model is available.

For installed-app acceptance, use a disposable generated PDF. Save it under one intentional `.pdf` name. Select original PDF text and replace it on the page, format a subset using installed font family, size, color, bold and italic, then confirm neighboring source text remains selectable. Move/resize the replacement, recover from overflow, save/reopen and verify both its appearance and searchable text. Exercise a page operation plus undo, form creation/filling, a nonbinding test signature, conversion/OCR, redaction output, one-action local Ollama generation with source links, cloud preparation without sending, and original marker/tag/search/navigation. From another tool, open a saved marker, change combined categories, and undo its deletion. Reopen the exact saved PDF and visually inspect exported copies in Preview. Record source/runtime limitations separately; transport fixtures do not prove a paid provider account works. Current results are in [WORKSPACE_VERIFICATION.md](WORKSPACE_VERIFICATION.md).

## Version 2 release result

The final default run passed 250 functions / 431 expanded scenarios across the core and app suites, with the opt-in Ollama test skipped by default. Enabling that test separately passed its real local request, exercising all 251 functions. See [WORKSPACE_VERIFICATION.md](WORKSPACE_VERIFICATION.md) for exact environment, commands/logs, installed-application evidence, and limitations.
