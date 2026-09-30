import AnnotateCore
import Atrium
import SwiftUI

/// One preset colour. The selected swatch carries a ring and a check mark, never colour alone.
struct MarkerColorSwatch: View {
    let markerColor: MarkerColor
    let name: String
    @Binding var selection: Color

    private var color: Color { Color(nsColor: markerColor.nsColor) }
    private var selected: Bool { selection == color }

    var body: some View {
        Button { selection = color } label: {
            Circle()
                .fill(color)
                .strokeBorder(.black.opacity(0.12), lineWidth: 0.5)
                .frame(width: Metrics.minimumControl, height: Metrics.minimumControl)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(Typography.label)
                            .foregroundStyle(Color(nsColor: markerColor.readableInkColor))
                    }
                }
                .padding(Spacing.hair)
                .overlay { Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: Spacing.hair) }
                .frame(width: Metrics.control, height: Metrics.control)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
