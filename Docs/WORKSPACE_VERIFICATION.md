# Annotate 2.0 verification

Verification date: September 5, 2026. Environment: Apple Silicon, macOS 27, Xcode 27 beta, Swift 6.4. The deployment target remains macOS 26; macOS 26 and Intel runtime behavior were not exercised. Building the Apple Intelligence integration requires the macOS 26.4 SDK or newer.

## Scope and research

The document workspace retains composable passage markers and adds genuine native text replacement/insertion, rich typography and spacing, source-image editing/insertion and markup, page organization, interactive forms (including list boxes), electronic signatures, certificate signing/validation, conversion, compression, OCR, sanitized redaction, and assistance with Ollama, OpenAI, Claude, and Apple Intelligence.

The [reference-product audit](PDFGEAR_RESEARCH.md) uses **10 original sources**. Engineering designs identify their own primary Apple, Adobe, PDF Association, and provider references. Vendor descriptions establish requested scope; they do not independently verify PDFgear's binary, fidelity, or accuracy.

## Automated evidence

The baseline had 57 test functions. Expanded suites exercise generated PDFs, saved/reopened outputs, original glyph removal, source font/color recovery, rendered pixels, mixed typography, field persistence, whole-document OCR, archive structures, bounded native PDF parsing, provider contracts, and document lifecycle. The final release run passed 250 test functions across 53 suites and 431 expanded scenarios: the core runner reported 157 functions (one opt-in runtime test skipped), and the app runner reported 94. The separately enabled real Ollama test then passed in 1.153 seconds, so all 251 functions were exercised successfully across both runs. The full-suite core/app times were 13.824/3.306 seconds. Local logs are build/annotate-2-release-tests.log and build/annotate-2-ollama-test.log; generated artifacts and logs are excluded from Git.

Native text tests cover compressed subset fonts, Unicode maps, positioned text, shared Form XObjects, crops/rotations, mixed fonts, deletion/insertion/movement, overflow, and paint order. Scan tests separately verify source pixels, hidden OCR removal, visible replacement, neighboring content, shared images, and rejection of ambiguous backgrounds. Annotation comparisons use saved input baselines because PDFKit normalizes some newly created note bounds and appearances on first serialization.

Actual AppKit input tests caught and fixed a selection-before-text-change callback that could replace freshly typed characters with old text. Tests now verify repeated typing, caret position, first responder, shared rich text, PDF content, and undo/redo. Other tests cover save checkpoints, dirty state returning to clean after undo, blocked saves for unapplied edits, and native form values changed while an edit is pending.

The final bounded review found and repaired two security/privacy defects: repeated CMap ranges could evade per-range limits and perform unbounded aggregate expansion; previous local AI questions could enter a later cloud request without appearing in its review. Adversarial font-map tests now enforce aggregate work/storage limits. Provider switching clears follow-up context, and same-provider context is explicitly shown in the request review.

The opt-in local assistant test passed with the downloaded granite4.1:8b model in 1.153 seconds during final release verification. It performed metadata preflight and a real chat response containing the synthetic Cedar Compass codename and page-two citation. No paid API requests were made.

Certificate tests generate disposable self-signed certificates and import them into memory only. System OpenSSL independently verifies detached SHA-256 CMS signatures and rejects changed bytes. Tests distinguish integrity, local certificate trust, unsupported envelopes, and appended unsigned bytes. Temporary private keys are removed. The retained UI fixture contains only the public certificate and signed synthetic PDF.

Independent ZIP/XML inspection and macOS QuickLook rendered generated XLSX/PPTX packages. This verifies basic consumer compatibility; Microsoft Excel/PowerPoint edit-and-resave behavior was not exercised.

## Installed application evidence

Applications previews used disposable reading guides. Earlier workspace checks verified page insertion plus undo, native field creation/filling and save/reopen, a nonbinding test signature, composable marker categories with note/question/color/icon, direct tag popovers, and search navigation. The fixture is build/Workspace-Smoke-20260905.pdf, with one intentional extension.

The genuine editing preview saved build/Native-Editing-Smoke.pdf. Its heading “A better way to return” became “A clearer way back.” Only “clearer” uses Helvetica-Bold at 16 points; surrounding words remain Helvetica at 14 points. Independent reopening confirmed the old heading is absent, the replacement appears once, neighboring text remains searchable, all four pages remain, and page one has no annotations. This is real mixed-style PDF text, not a saved text-box overlay.

The installed local assistant correctly answered the guide's question about comparing search results and its Page 3 button opened the evidence. OpenAI and Claude each exposed secure Keychain setup and model controls. Preparing an OpenAI summary stopped at review of all four pages with a separate named Send action. No keys were entered or cloud generation sent. The original local provider/model preference was restored after testing.

The corrected installed text editor opened the untouched “A better way to return” heading at System Font Semibold, 14 points, with every character visible and no overflow warning. Its sidebar displayed black source text on white paper in dark appearance. Actual on-page typing updated the heading while retaining the viewport. Independent reopening of Native-Editing-Release.pdf confirmed four pages, exactly one replacement, no original heading, and no page-one annotations.

In Scanned-Editing-Smoke.pdf, the installed editor identified the OCR source before typing. Explicit Edit scanned text followed by on-page typing changed TARGET to EDITED. After intentional saving, independent reopening confirmed EDITED and NEIGHBOR on page one, absence of TARGET there, and unchanged TARGET on page two. The lossless source-image rewrite enlarged this small fixture from approximately 19 KB to 983 KB.

The installed Sign panel validated the public-only synthetic certificate fixture as “Signature intact · certificate not trusted,” correctly identifying its disposable self-signed certificate. No user identities were loaded or used. The marker fixture's direct flag tag opened its saved details, sidebar navigation reached page two, an edited note survived explicit Save/close/reopen, and export produced Workspace-Release-Shared.pdf with one extension. Preview rendered its five pages and complete notes/questions index. Independent PDFKit reopening confirmed zero annotations in the sharing copy and the full saved note/question text.

## Performance and practical limits

A debug benchmark measured native replacement, full graph writing, and reopening at approximately 24 ms for four pages (37 KB input), and 122 ms for 100 generated pages (312 KB input). This is fixture evidence, not a bound for arbitrary documents. Large image-heavy PDFs can take longer; updates execute synchronously on the main actor.

- **Native editing:** fixed-area word/line/paragraph editing preserves surrounding content; nearby paragraphs do not automatically reflow. Unsupported maps, Type 3 fonts, clipping text, inline-image streams, missing fonts, and ambiguous mapping have explicit limits. Font substitutions are visible. Encrypted editing and preserving existing certificate validity through edits are unsupported. See [the engine design](NATIVE_TEXT_EDITING.md).
- **Scans:** explicit scan editing requires usable OCR, one safely mapped opaque image, and a flat background. It changes selected source pixels and inserts native text. Patterned backgrounds, masks, overlaps, and unsupported transforms are rejected. OCR does not restore original font metadata; a lossless image rewrite can enlarge files.
- **Images:** source Image XObjects can be selected, replaced, removed, moved, and resized; neighboring text/vectors and other shared invocations are retained. Movement is restricted for skew, clipping, and unsupported transforms. Thumbnails show the rendered page area, including overlapping content. Vector artwork is separate. See [image editing](IMAGE_EDITING_DESIGN.md).
- **Conversion:** 13 output types are implemented. Word-style exports reflow text; XLSX exports text cells; PPTX exports page images. Faithful Office layout, tables, formulas, slide objects, and XLSX/PPTX import remain gaps.
- **Signatures:** electronic appearances and certificate approval signatures are distinct. Trusted timestamps, revocation/LTV, DocMDP certification, and additional signatures on already signed PDFs are unsupported. Validation uses exact original bytes.
- **Redaction:** the sanitized copy intentionally removes searchable text, fields, links, annotations, attachments, and source metadata throughout the output. The open source remains unredacted; inspect the exported copy before sharing.
- **AI:** Ollama has runtime evidence. OpenAI/Claude have transport-fixture coverage, not authenticated account/model evidence. Apple Intelligence depends on system availability. Answers require source checking.
- **Distribution:** local ad-hoc signing and Applications installation, not a notarized public binary release.

These differences mean this release must not be described as complete PDFgear parity.

The installed image workflow exercised position and proportional resize (width 100→120, height 80→96), Apply, single-step Undo back to the original geometry, source-image deletion, Undo, local bitmap replacement, and Save. The first image became a 32×16 blue/white bitmap while the second stayed 20×10 green and the native heading remained visible. A final runtime finding exposed stale sidebar thumbnails after Apply: fingerprint-aware row task identity fixes that lifecycle race. A rendered SwiftUI regression fails with the old key and passes with the fix, and the core preview is pixel-checked before and after save/reopen.

## Final build and Applications installation

`./Scripts/install.sh` completed a fresh release build in 21.91 seconds, retained the previous app as a timestamped local backup, installed `/Applications/Annotate.app`, and launched that exact path. The installed app reports version **2.0.0 (4)**. Strict deep code-signature verification passed. The build and installed executable both have SHA-256 `1a870ced9ac1a14f1e6c6dc1f6a8d7522dc98a939663b1685955132a2bdb0409`. Local evidence is in `build/annotate-2-install.log`.

The final installed thumbnail fix was exercised after native image Apply and Save: the blue/white replacement and unchanged green neighbor both retained their correct sidebar previews. Local AI again returned the expected surrounding-sentence guidance with page-three navigation and explicit Ollama/model provenance. OpenAI preparation stopped at a separate named Send action; no cloud generation occurred. Ollama and the original `qwen3.8:27b-mlx` preference were restored.
