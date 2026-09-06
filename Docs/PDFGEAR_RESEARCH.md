# PDFgear for Mac: verified requirements and limits of the evidence

Reviewed September 5, 2026. This audit references **10 original sources: nine PDFgear pages and one Apple support page**. PDFgear pages establish the publisher's advertised behavior, not independent proof of the shipped binary, fidelity, security, or accuracy. No PDFgear binary was installed or exercised for this audit.

The requested [Mac product page](https://www.pdfgear.com/pdfgear-for-mac/) explicitly advertises the following Mac capabilities. They cannot be dismissed as Windows-only requirements merely because older versions or older reviews had narrower support.

| Advertised capability | Product requirement |
| --- | --- |
| Existing text and image editing | Change original wording, typography, spacing, and images. |
| AI reading | Summarize, explain, translate, answer questions, and identify details alongside the PDF. |
| Compression | Quality choices and batch processing. |
| Conversion | Word, Excel, PowerPoint, RTF, TXT, JPG, PNG, and a claimed 30-plus outputs; Office/image/blank-PDF creation. |
| Pages | Reorder, insert, rotate, extract, and delete. |
| Signatures | Drawn, typed, and imported electronic signatures; multiple pages; certificate signatures. |
| OCR | Process an entire scanned PDF for usable text. |
| Forms | Fill existing/noninteractive forms and create interactive fields. |
| Redaction | Permanently remove selected content. |
| Product experience | Free, no ads/accounts/watermarks; mostly local processing with online AI. |

## Mac, Windows, and online distinctions

The [Mac editing guide](https://www.pdfgear.com/pdf-editor-reader/edit-pdf-text-on-mac.htm) explicitly separates the online editor's added text/annotations from the Mac app's ability to alter existing text. Overlay text alone is therefore insufficient to claim this editing requirement. Matching the visible appearance without retaining editable original content is a different implementation tradeoff and must be documented.

The [Mac Word conversion guide](https://www.pdfgear.com/how-to/how-to-convert-pdf-to-word-on-mac.htm) describes offline batch PDF-to-Word processing in the Mac app. It supports that specific workflow; it does not enumerate or verify every one of the advertised 30-plus distinct output formats. Treat “30 outputs,” “30 format changes,” and the number of conversion directions as different claims. Never inflate Annotate's export count by counting import directions or merely changing extensions.

The [Mac signing guide](https://www.pdfgear.com/sign-pdf/how-to-sign-pdf-on-mac.htm) expressly claims both visual electronic signatures and certificate-based signatures. The guide's certificate instructions use the label “Encrypt with Certificate,” which is ambiguous as a description of signing; this audit does not validate the resulting cryptographic artifact. A drawn signature, signature image, filled signature field, password-protected PDF, or flattened page must not be described as a cryptographically verified digital signature. Certificate signing remains a distinct acceptance test requiring independently verified signed output.

The [Mac OCR guide](https://www.pdfgear.com/pdf-editor-reader/mac-preview-ocr.htm) documents current-file OCR and export/copy of recognized text. For Annotate, a panel containing recognized text and a PDF containing a persistent searchable text layer are separate outcomes; tests must establish whichever the product claims.

The [Mac form creation guide](https://www.pdfgear.com/pdf-editor-reader/how-to-make-a-fillable-pdf-on-mac.htm) describes offline field creation for text, checkbox, radio, dropdown, and list widgets. Adding free text over a blank line fills a noninteractive document visually but does not create an interactive form field. The same article has a separate online workflow; the two must not be conflated.

The product page's “See all features” link leads to the [online tools catalog](https://www.pdfgear.com/online-tools/). A feature in that catalog alone does not establish its presence in the offline Mac app. Remote signature requesting/tracking is also described by the signing article as a separate eSignGear service; it is not evidence that the Mac PDF editor itself provides that service.

## Claims requiring particular caution

The [redaction guide](https://www.pdfgear.com/pdf-editor-reader/how-to-redact-a-pdf.htm) claims permanent removal on Windows and Mac. It also asserts that Preview only hides text. That characterization conflicts with [Apple's Preview documentation](https://support.apple.com/guide/preview/annotate-a-pdf-prvw11580/mac), which describes a dedicated permanent redaction operation. The contradiction is a reason to verify security outcomes directly, not to repeat comparative marketing. Verify reopened output, extraction/search, retained objects, annotations, metadata, attachments, and pixels; an opaque rectangle alone proves only visual concealment.

The [AI summary guide](https://www.pdfgear.com/how-to/summarize-pdf-with-ai.htm) names a GPT-3.5 integration and makes broad accuracy/completeness claims. It is dated February 2025 and includes dated descriptions of competing services. It establishes an advertised AI workflow, not current model identity, limitless context, perfect summaries, or universal language accuracy. Annotate must expose its actual provider, source coverage, model limitations, and whether document text leaves the Mac.

## Acceptance implications for Annotate

- Record every supported export format and its fidelity explicitly. Text-only Word reconstruction and slide images are useful outputs but differ from preservation of the original editable layout.
- Existing-content editing, image replacement, certificate signing, and secure redaction require separate verification. Annotation support does not prove those workflows.
- AI summaries must state whether every page was processed, which pages lacked text, and when a question was answered from retrieved excerpts. A bounded source subset must never be presented as a complete-document review.
- Current-task steering requires user-configured Ollama, OpenAI, and Claude providers. Remote API calls introduce provider charges and data transfer; disclose both before generation. This is an intentional difference from the reference product's advertised free bundled AI.
- Any feature not implemented or not proven in runtime testing remains an explicit parity gap. A large set of new features alone does not justify claiming complete PDFgear equivalence.
