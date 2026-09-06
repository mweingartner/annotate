import SwiftUI

struct FontFamilyRow: View {
    let family: String
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack {
                Text(FontCatalog.displayName(for: family)).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(ReaderStyle.accent) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(selected ? ReaderStyle.accent.opacity(0.12) : .clear, in: .rect(cornerRadius: 6))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
