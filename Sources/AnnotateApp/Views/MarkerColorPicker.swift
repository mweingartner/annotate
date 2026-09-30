import AnnotateCore
import Atrium
import SwiftUI

/// Preset marker colours as swatches, with the system colour well for anything else.
struct MarkerColorPicker: View {
    @Bindable var draft: MarkerDraft

    private let names = ["Amber", "Green", "Blue", "Purple", "Pink", "Orange"]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.control), spacing: Spacing.tight)],
                  alignment: .leading, spacing: Spacing.tight) {
            ForEach(MarkerColor.palette.indices, id: \.self) { index in
                MarkerColorSwatch(markerColor: MarkerColor.palette[index],
                                  name: names.indices.contains(index) ? names[index] : "Color \(index + 1)",
                                  selection: $draft.color)
            }
            ColorPicker("Custom Color", selection: $draft.color, supportsOpacity: false)
                .labelsHidden()
                .help("Choose any color")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Marker color")
    }
}
