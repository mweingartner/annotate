import SwiftUI

struct MarkerColorSwatch: View {
    let color: Color
    let name: String
    @Binding var selection: Color

    private var selected: Bool { selection == color }

    var body: some View {
        Button(action: selectColor) {
            Circle()
                .fill(color)
                .stroke(.primary.opacity(0.15), lineWidth: 1)
                .frame(width: 25, height: 25)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.caption.bold())
                            .foregroundStyle(.black.opacity(0.8))
                    }
                }
                .padding(3)
                .overlay {
                    Circle().stroke(selected ? Color.primary.opacity(0.7) : .clear, lineWidth: 1.5)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel("\(name) highlight")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func selectColor() { selection = color }
}
