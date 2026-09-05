import SwiftUI

struct MarkerIconButton: View {
    let option: MarkerIconOption
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: option.symbol)
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(selected ? ReaderStyle.accent.opacity(0.13) : Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selected ? ReaderStyle.accent : Color.primary.opacity(0.12), lineWidth: selected ? 1.5 : 1)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(option.name)
        .accessibilityLabel("\(option.name) margin icon")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
