import SwiftUI

struct MarkerIconButton: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let option: MarkerIconOption
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: option.symbol)
                .font(.body)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(selected ? ReaderStyle.accent.opacity(0.13) : Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(ReaderStyle.outline(selected: selected, contrast: contrast), lineWidth: selected ? 2 : 1)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(option.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(option.name) margin icon")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
