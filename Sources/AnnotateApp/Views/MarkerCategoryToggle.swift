import SwiftUI
import AnnotateCore

struct MarkerCategoryToggle: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Bindable var draft: MarkerDraft
    let category: MarkerCategory

    private var selected: Bool { draft.categories.contains(category) }

    var body: some View {
        Button(action: toggleCategory) {
            HStack(spacing: 6) {
                Image(systemName: category.symbol)
                    .accessibilityHidden(true)
                Text(category.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? ReaderStyle.accent : Color.secondary)
                    .accessibilityHidden(true)
            }
            .font(.callout)
            .padding(.horizontal, 9)
            .padding(.vertical, 11)
            .background(selected ? ReaderStyle.accent.opacity(0.1) : Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(ReaderStyle.outline(selected: selected, contrast: contrast), lineWidth: selected ? 2 : 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Toggle this category; multiple categories are allowed")
    }

    private func toggleCategory() {
        if selected { draft.categories.remove(category) }
        else { draft.categories.insert(category) }
    }
}
