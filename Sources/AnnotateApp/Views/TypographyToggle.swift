import SwiftUI

struct TypographyToggle: View {
    let title: String
    let symbol: String
    let selected: Bool
    var enabled = true
    let action: () -> Void
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .frame(minWidth: 28, minHeight: 24)
            .buttonStyle(.bordered)
            .tint(selected ? ReaderStyle.accent : .secondary)
            .background(selected ? ReaderStyle.accent.opacity(0.15) : .clear, in: .rect(cornerRadius: 6))
            .overlay(alignment: .bottomTrailing) {
                if selected, differentiateWithoutColor { Image(systemName: "checkmark").font(.caption2).padding(2) }
            }
            .disabled(!enabled)
            .help(enabled ? title : "This font has no \(title.lowercased()) variant")
            .accessibilityValue(selected ? "On" : "Off")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
