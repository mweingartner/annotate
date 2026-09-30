import Atrium
import SwiftUI

/// The Edit inspector while text is open: every formatting control for the block, in
/// sections. The floating format bar on the page carries the everyday subset.
struct LiveTextControls: View {
    let model: ReaderModel
    @Bindable var session: LiveTextEdit
    @State private var color = Color.black
    @State private var showTextEditor = false
    @State private var showGeometry = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            status
                .padding(.bottom, Spacing.group)

            PageSection(session.selectedRange.length > 0 ? "Selected Text" : "Whole Block") {
                VStack(alignment: .leading, spacing: Spacing.control) {
                    FontFamilyPicker(font: session.font, choose: session.chooseFamily(of:))
                    FontFacePicker(session: session)
                    HStack(spacing: Spacing.snug) {
                        Text("Size")
                        TextField("Size in points", value: $session.fontSize, format: .number.precision(.fractionLength(0...2)))
                            .frame(width: Metrics.row * 2)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Font size in points")
                            .onSubmit(session.normalizeFontSize)
                        Stepper("Font size", value: $session.fontSize, in: 4...144)
                            .labelsHidden()
                            .accessibilityLabel("Adjust font size")
                        Text("pt").foregroundStyle(.secondary)
                    }
                    if !session.fontSizeIsValid {
                        StatusBadge("Use a size from 4 to 144 pt", kind: .caution)
                    }
                    HStack(spacing: Spacing.tight) {
                        TypographyToggle(title: "Bold", symbol: "bold", selected: session.hasTrait(.boldFontMask),
                                         enabled: session.canToggle(.boldFontMask)) { session.toggle(.boldFontMask) }
                        TypographyToggle(title: "Italic", symbol: "italic", selected: session.hasTrait(.italicFontMask),
                                         enabled: session.canToggle(.italicFontMask)) { session.toggle(.italicFontMask) }
                        TypographyToggle(title: "Underline", symbol: "underline", selected: session.isUnderlined) {
                            session.isUnderlined.toggle()
                        }
                        Spacer(minLength: Spacing.snug)
                        ColorPicker("Text color", selection: $color, supportsOpacity: false)
                            .labelsHidden()
                            .help("Text color")
                            .onChange(of: color) { _, value in
                                if value != Color(nsColor: session.color) { session.color = NSColor(value) }
                            }
                    }
                }
            }

            PageSection("Paragraph") {
                VStack(alignment: .leading, spacing: Spacing.control) {
                    TextAlignmentPicker(alignment: $session.alignment)
                    LiveTextSpacingControls(session: session)
                }
            }

            PageSection("Block") {
                VStack(alignment: .leading, spacing: Spacing.control) {
                    DisclosureGroup("Position and size", isExpanded: $showGeometry) {
                        LiveTextGeometryControls(session: session)
                            .padding(.top, Spacing.snug)
                    }
                    if !session.nativeUpdateFailed {
                        Button("Fit Height to Text", systemImage: "arrow.up.and.down", action: fitHeight)
                            .help("Grow or shrink the block downward to fit its text")
                    }
                    DisclosureGroup("Edit as Plain Text", isExpanded: $showTextEditor) {
                        SidebarRichTextEditor(session: session)
                            .frame(minHeight: Metrics.doubleRow * 2, idealHeight: Metrics.doubleRow * 3, maxHeight: Metrics.doubleRow * 5)
                            .clipShape(.rect(cornerRadius: Radius.field))
                            .overlay { RoundedRectangle(cornerRadius: Radius.field).strokeBorder(Palette.hairline) }
                            .padding(.top, Spacing.snug)
                    }
                    .help("The same text as on the page, for editing with a screen reader or at a larger size")
                }
            }

            Button("Done", action: finish)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help("Finish editing this text (Escape)")
        }
        .onAppear(perform: synchronizeColor)
        .onChange(of: session.color) { synchronizeColor() }
    }

    /// Problems and special modes, each as symbol plus words.
    @ViewBuilder
    private var status: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Text("Page \(session.pageIndex + 1)")
                .font(Typography.supporting)
                .foregroundStyle(.secondary)
            if session.nativeUpdateFailed, session.textOverflows {
                // One place for the problem: the block shows an overflow mark on the page.
                StatusBadge("Text doesn’t fit", kind: .caution)
                Text("Make the block taller, make the text smaller, or remove some words.")
                    .font(Typography.supporting)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Spacing.snug) {
                    Button("Fit Height to Text", systemImage: "arrow.up.and.down", action: fitHeight)
                    Button("Discard Changes", role: .destructive) { model.discardPendingLiveText() }
                }
            } else if session.nativeUpdateFailed {
                StatusBadge("Not applied yet", kind: .caution)
                Text(session.nativeFailureMessage ?? "The PDF still shows the last text that could be applied.")
                    .font(Typography.supporting)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Discard Changes", role: .destructive) { model.discardPendingLiveText() }
            }
            if session.canEditScannedText, !session.usesScannedTextEditing {
                StatusBadge("Text from a scan", kind: .info)
                Text("On a plain background, Annotate can remove these words from the scanned image and set selectable text in their place. Choose a font to match.")
                    .font(Typography.supporting)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Edit Scanned Text", systemImage: "doc.text.viewfinder", action: model.enableScannedTextEditing)
            }
            if session.usesScannedTextEditing {
                StatusBadge("Editing scanned text", kind: .info)
            }
            if let message = session.fontSubstitutionMessage {
                Label(message, systemImage: "textformat.alt")
                    .font(Typography.supporting)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func synchronizeColor() { color = Color(nsColor: session.color) }
    private func fitHeight() {
        if !session.fitHeightToText() { model.errorMessage = "The text needs more room than is available below this box. Move it upward or increase its width." }
    }
    private func finish() { session.normalizeFontSize(); model.finishLiveText() }
}
