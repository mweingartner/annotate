import SwiftUI

struct LiveTextControls: View {
    let model: ReaderModel
    @Bindable var session: LiveTextEdit
    @State private var color = Color.black
    @State private var showTextEditor = true
    @State private var showGeometry = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.isExistingContent ? "Edit existing text" : "Edit text box").font(.title3.bold())
                    Text("Page \(session.pageIndex + 1)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", systemImage: "checkmark", action: finish)
                    .buttonStyle(.borderedProminent)
            }
            if session.nativeUpdateFailed {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Some text changes were not applied", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                    Text(session.nativeFailureMessage ?? "The PDF still contains the last successfully applied text.")
                        .font(.caption)
                    Button("Discard unapplied text", role: .destructive) { model.discardPendingLiveText() }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 8))
            }
            if session.canEditScannedText, !session.usesScannedTextEditing {
                VStack(alignment: .leading, spacing: 8) {
                    Label("This text comes from a scan", systemImage: "doc.text.viewfinder").font(.subheadline.weight(.semibold))
                    Text("For a scan on a plain background, remove the selected words from the image and insert selectable text. Choose a font to match the scan. Surrounding image pixels stay intact.")
                        .font(.caption)
                    Button("Edit scanned text", systemImage: "pencil", action: model.enableScannedTextEditing)
                }.padding(10).background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
            }
            if let message = session.fontSubstitutionMessage {
                Label(message, systemImage: "textformat.alt").font(.caption).foregroundStyle(.secondary)
            }
            if session.usesScannedTextEditing {
                Label("Editing scanned text", systemImage: "doc.text.viewfinder").font(.caption).foregroundStyle(.secondary)
            }
            Text("Type on the page or below. Select characters to change their style.")
                .font(.callout).foregroundStyle(.secondary)
            DisclosureGroup("Text", isExpanded: $showTextEditor) {
                SidebarRichTextEditor(session: session)
                    .frame(minHeight: 120, idealHeight: 150, maxHeight: 220)
                    .clipShape(.rect(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).stroke(.separator) }
                    .padding(.top, 7)
            }
            if session.textOverflows {
                Label("The text does not fit. Widen or heighten the box, or reduce the font size.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                Button("Fit text height", systemImage: "arrow.up.and.down", action: fitHeight)
            }
            Divider()
            Text(session.selectedRange.length > 0 ? "Format selected text" : "Format entire text block")
                .font(.subheadline.weight(.semibold))
            FontFamilyPicker(font: session.font, choose: chooseFamily)
            FontFacePicker(session: session)
            HStack(spacing: 10) {
                Text("Size").font(.callout)
                TextField("Size in points", value: $session.fontSize, format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 60).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Font size in points")
                    .onSubmit(normalizeFontSize)
                Text("pt").font(.caption).foregroundStyle(.secondary)
                Stepper("Font size", value: $session.fontSize, in: 4...144)
                    .labelsHidden().accessibilityLabel("Adjust font size")
                Spacer(minLength: 0)
            }
            if !session.fontSizeIsValid {
                Text("Enter a font size from 4 to 144 points.").font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                TypographyToggle(title: "Bold", symbol: "bold", selected: FontCatalog.hasTrait(.boldFontMask, font: session.font), enabled: FontCatalog.toggling(.boldFontMask, font: session.font) != nil) { toggle(.boldFontMask) }
                TypographyToggle(title: "Italic", symbol: "italic", selected: FontCatalog.hasTrait(.italicFontMask, font: session.font), enabled: FontCatalog.toggling(.italicFontMask, font: session.font) != nil) { toggle(.italicFontMask) }
                TypographyToggle(title: "Underline", symbol: "underline", selected: session.isUnderlined) { session.isUnderlined.toggle() }
                Spacer()
            }
            ColorPicker("Text color", selection: $color, supportsOpacity: false)
                .onChange(of: color) { _, value in
                    if value != Color(nsColor: session.color) { session.color = NSColor(value) }
                }
            TextAlignmentPicker(alignment: $session.alignment)
            LiveTextSpacingControls(session: session)
            Divider()
            DisclosureGroup("Position & size", isExpanded: $showGeometry) {
                VStack(alignment: .leading, spacing: 10) {
                    LiveTextGeometryControls(session: session)
                    Button("Fit height to text", systemImage: "arrow.up.and.down", action: fitHeight)
                }.padding(.top, 8)
            }
        }
        .onAppear(perform: synchronizeColor)
        .onChange(of: session.color) { synchronizeColor() }
    }

    private func toggle(_ trait: NSFontTraitMask) {
        if session.attributedText.length == 0 {
            if let changed = FontCatalog.toggling(trait, font: session.font) { session.fontName = changed.fontName }
            return
        }
        let enabled = !FontCatalog.hasTrait(trait, font: session.font)
        let changed = RichTextTypography.settingTrait(trait, enabled: enabled, in: session.attributedText, selection: session.selectedRange)
        session.updateAttributedText(changed, selectedRange: session.selectedRange)
    }
    private func chooseFamily(_ font: NSFont) {
        if session.attributedText.length == 0 { session.fontName = font.fontName; return }
        let changed = RichTextTypography.changingFamily(FontCatalog.family(of: font), in: session.attributedText, selection: session.selectedRange)
        session.updateAttributedText(changed, selectedRange: session.selectedRange)
    }
    private func normalizeFontSize() {
        guard !session.fontSizeIsValid else { return }
        session.fontSize = session.fontSize.isFinite ? min(144, max(4, session.fontSize)) : 14
    }
    private func synchronizeColor() { color = Color(nsColor: session.color) }
    private func fitHeight() {
        if !session.fitHeightToText() { model.errorMessage = "The text needs more room than is available below this box. Move it upward or increase its width." }
    }
    private func finish() { normalizeFontSize(); model.finishLiveText() }
}
