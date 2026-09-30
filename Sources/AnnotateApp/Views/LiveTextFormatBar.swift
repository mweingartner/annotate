import Atrium
import SwiftUI

/// A small glass bar that floats beside the text being edited, holding the formatting a
/// person reaches for while typing. Everything else stays in the Edit inspector.
struct LiveTextFormatBar: View {
    let model: ReaderModel
    @Bindable var session: LiveTextEdit
    @State private var color = Color.black

    var body: some View {
        HStack(spacing: Spacing.tight) {
            FontFamilyMenu(session: session)
            sizeControl
            Divider().frame(height: Metrics.minimumControl)
            trait("Bold", symbol: "bold", trait: .boldFontMask)
            trait("Italic", symbol: "italic", trait: .italicFontMask)
            Toggle(isOn: $session.isUnderlined) { Label("Underline", systemImage: "underline") }
                .toggleStyle(.button)
                .help("Underline")
            ColorPicker("Text Color", selection: $color, supportsOpacity: false)
                .labelsHidden()
                .help("Text color")
                .onChange(of: color) { _, value in
                    if value != Color(nsColor: session.color) { session.color = NSColor(value) }
                }
            Divider().frame(height: Metrics.minimumControl)
            Button("Done", systemImage: "checkmark", action: finish)
                .buttonStyle(.glassProminent)
                .help("Finish editing this text (Escape)")
        }
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.tight)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
        .onAppear { color = Color(nsColor: session.color) }
        .onChange(of: session.color) { color = Color(nsColor: session.color) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Text formatting")
    }

    private var sizeControl: some View {
        HStack(spacing: Spacing.hair) {
            TextField("Size", value: $session.fontSize, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(Typography.numeric)
                .frame(width: Metrics.control)
                .onSubmit(session.normalizeFontSize)
                .accessibilityLabel("Font size in points")
            Stepper("Font Size", value: $session.fontSize, in: 4...144)
                .labelsHidden()
                .help("Font size in points")
        }
    }

    private func trait(_ title: String, symbol: String, trait: NSFontTraitMask) -> some View {
        Toggle(isOn: Binding(get: { session.hasTrait(trait) }, set: { _ in session.toggle(trait) })) {
            Label(title, systemImage: symbol)
        }
        .toggleStyle(.button)
        .disabled(!session.canToggle(trait))
        .help(session.canToggle(trait) ? title : "This font has no \(title.lowercased()) style")
    }

    private func finish() {
        session.normalizeFontSize()
        model.finishLiveText()
    }
}

/// The font family as a compact menu of installed families.
private struct FontFamilyMenu: View {
    @Bindable var session: LiveTextEdit

    private var family: String { FontCatalog.family(of: session.font) }

    var body: some View {
        Menu {
            ForEach(FontCatalog.families, id: \.self) { name in
                Button {
                    if let font = FontCatalog.font(in: name, matching: session.font) { session.chooseFamily(of: font) }
                } label: {
                    if name == family { Label(FontCatalog.displayName(for: name), systemImage: "checkmark") }
                    else { Text(FontCatalog.displayName(for: name)) }
                }
            }
        } label: {
            Text(FontCatalog.displayName(for: family))
                .lineLimit(1)
                .frame(maxWidth: Metrics.inspector.min / 2, alignment: .leading)
        }
        .menuStyle(.button)
        .labelStyle(.titleOnly)
        .fixedSize()
        .help("Font family")
        .accessibilityLabel("Font family, \(FontCatalog.displayName(for: family))")
    }
}
