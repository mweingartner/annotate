import SwiftUI
import AnnotateCore

struct MarkerColorSwatch: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let markerColor: MarkerColor
    let name: String
    @Binding var selection: Color

    private var color: Color { Color(nsColor: markerColor.nsColor) }
    private var selected: Bool { selection == color }

    var body: some View {
        Button(action: selectColor) {
            Circle()
                .fill(color)
                .stroke(ReaderStyle.outline(contrast: contrast), lineWidth: 1)
                .frame(width: 25, height: 25)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.caption.bold())
                            .foregroundStyle(Color(nsColor: markerColor.readableInkColor))
                            .accessibilityHidden(true)
                    }
                }
                .padding(3)
                .overlay {
                    Circle().stroke(selected ? Color.primary : .clear, lineWidth: 2)
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
