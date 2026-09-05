import SwiftUI
import AnnotateCore

struct MarkerFilterButton: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let filter: MarkerFilter
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Label(filter.title, systemImage: filter.symbol)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(selected ? ReaderStyle.accent.opacity(0.13) : Color.clear, in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(ReaderStyle.outline(selected: selected, contrast: contrast), lineWidth: selected ? 2 : 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(filter.title), \(count) markers")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
