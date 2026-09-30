import Atrium
import SwiftUI

/// A bold, italic or underline switch. Selected reads as the system's pressed toggle
/// state, with a check mark added when Differentiate Without Colour is on.
struct TypographyToggle: View {
    let title: String
    let symbol: String
    let selected: Bool
    var enabled = true
    let action: () -> Void
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        Toggle(isOn: Binding(get: { selected }, set: { _ in action() })) {
            Label(title, systemImage: symbol)
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .frame(minWidth: Metrics.control, minHeight: Metrics.minimumControl)
        .overlay(alignment: .bottomTrailing) {
            if selected, differentiateWithoutColor { Image(systemName: "checkmark").font(Typography.meta).padding(Spacing.hair) }
        }
        .disabled(!enabled)
        .help(enabled ? title : "This font has no \(title.lowercased()) style")
        .accessibilityValue(selected ? "On" : "Off")
    }
}
