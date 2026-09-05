# Verification — September 5, 2026

## Delivered artifact

- Installed and launched: `/Applications/Annotate.app`, version 1.0.0 (1).
- Release binary: Apple silicon arm64, built by Xcode 27 / Swift 6.4 for macOS 26+.
- Runtime exercised: macOS 27.0, build 26A5425a.
- Ad-hoc code signature passed `codesign --verify --deep --strict`.
- Installed executable and release-build executable have identical SHA-256:
  `ddf1e176977da7974aac2338ba81689031a56c183eebbd9b5f6ca520dd68a3dc`.
- At this original build checkpoint, the local repository was initialized on `main` without a remote. The project was subsequently prepared for public publication at [mweingartner/annotate](https://github.com/mweingartner/annotate) under the MIT License.
- The awake-session guard used for UI testing was stopped after the installed-app checks.

## Automated evidence

The final `swift test` run passed **35 test functions in five suites, covering 52 scenarios** including parameterized cases. There were no compiler warnings. The two test targets reported 23 core tests and 12 app tests. The optimized release build also passed.

Tests use actual PDFKit documents and rendered PDF pages, including file save/reopen, multi-line and multi-page selections, category membership, attached writing, exact locations, mutation and undo/redo, hostile metadata, negative/non-finite geometry, extreme page-number input, cancellable contextual search, image-only location marks, native document callbacks, PDF permissions, flattening and long-note pagination. See [the test plan](TEST_PLAN.md) for precise assertions and execution instructions.

Export geometry tests cover all eight crop/rotation combinations. A separate visual comparison across four rotations found identical source/export nonwhite pixel masks and mean normalized RGB difference below 0.000005. These are generated fixtures, not a claim about every PDF in circulation.

Local logs are retained in the ignored `TestResults` directory: `swift-test.log`, `release-build.log`, and `install.log`.

## Observed application workflows

The development bundle and installed Applications bundle were tested separately through their actual macOS interfaces.

| Workflow | Observed result |
| --- | --- |
| Startup and sample | Native welcome and four-page selectable reading tour opened successfully |
| Selection | Dragging across three lines opened the annotation panel with the selected passage |
| Combined marker | Important + Revisit, blue preset, a note, and a question produced one marker in all four lists |
| Editor persistence | Reopening the editor restored the selected color, categories, complete note and complete question |
| Search | `attention` returned seven contextual rows; clicking a page-3 result navigated to page 3 without creating a draft |
| Saving | Native Save dialog wrote an editable PDF with four pages, four annotation objects, and one embedded marker UUID |
| Reopen | Installed app opened that saved file through Open; all four category counts and attached writing were restored |
| Printing | Native system print dialog showed the four-page document and print settings; canceled without sending a physical job |
| Export | Native export dialog wrote a five-page sharing PDF containing zero annotation objects and the full note and question as page text |
| Interoperability | Apple Preview opened the sharing copy; its highlight and star badge were visible, and page 5 showed the complete readable annotation index |
| Draft close protection | Editing a note then closing showed Save Marker / Discard Changes / Cancel. Cancel preserved the draft and kept the app responsive; Discard closed only the temporary draft |
| Responsive page fitting | Final installed build initially fit the PDF width without manual adjustment; opening the editor after fitting also resized the page to the narrower reading area |

Live interaction used the macOS dark appearance already active on this Mac. The preset picker was exercised; arbitrary RGB persistence is covered by automated tests. The native color-well control is present, but its separate color-panel interaction was not fully visually verified by the automation interface. VoiceOver labels appear in the accessibility tree; a complete spoken VoiceOver session and separate light/Reduce Motion sessions were not performed.

## Defects corrected during verification

- Invalid negative rectangle dimensions could survive early validation. They now fail before mutating existing annotations.
- Entering the smallest representable integer as a page number could overflow during subtraction. Range checks now precede arithmetic, with regression coverage for both integer extremes.
- NSDocument close cancellation must call its Objective-C completion; that callback now executes exactly once with the original document/context and `false`.
- PDFKit zoom-limit assignments disable automatic scaling. Initial setup now enables fit-to-width after setting those limits, and the control is accurately labeled Fit Width.
- The sample's small heading used a dynamic color that lacked contrast on a white PDF in dark mode. It now uses a fixed gray.

## Practical limits

No OCR is implemented; scanned documents require an existing text layer for text search/selection, and otherwise support location markers. Opened editable PDFs autosave in place; use Save As first to preserve an untouched source. Other software may strip custom annotation metadata. Flattened exports permanently draw marks into the sharing copy and preserve comments in the index; they do not promise preservation of form interactivity, links, PDF accessibility tagging, or digital-signature validity.

The app is locally signed for this Mac, not notarized for public distribution. macOS 26 execution, Intel builds, physical printer output, very large real-world document collections, and complex signed/form PDFs remain outside the verified scope.

The implementation and test documentation link **10 distinct original Apple sources** in total (eight implementation references and three testing references, with one overlap). SDK headers and executable behavior were used to check the documented API assumptions.
