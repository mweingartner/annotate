import AnnotateCore
import Atrium
import SwiftUI

/// The icon the marker wears on the page, previewed in the marker's own colour.
struct MarkerIconPicker: View {
    @Bindable var draft: MarkerDraft

    private var markerColor: MarkerColor {
        let rgb = NSColor(draft.color).usingColorSpace(.sRGB) ?? .systemYellow
        return MarkerColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
    }

    var body: some View {
        // Adaptive, so a narrow inspector wraps the icons instead of overflowing its column.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.control), spacing: Spacing.tight)],
                  alignment: .leading, spacing: Spacing.tight) {
            ForEach(MarkerIconOption.all) { option in
                let selected = draft.icon == option.symbol
                Button { draft.icon = option.symbol } label: {
                    MarkerGlyph(symbol: option.symbol, color: markerColor)
                        .padding(Spacing.hair)
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: Spacing.hair)
                        }
                        .frame(width: Metrics.control, height: Metrics.control)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(option.name)
                .accessibilityLabel("\(option.name) icon")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Marker icon")
    }
}
