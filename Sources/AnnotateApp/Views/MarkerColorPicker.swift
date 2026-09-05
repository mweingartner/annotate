import SwiftUI
import AnnotateCore

struct MarkerColorPicker: View {
    @Bindable var draft: MarkerDraft

    private let names = ["Amber", "Green", "Blue", "Purple", "Pink", "Orange"]

    var body: some View {
        VStack(alignment: .leading, spacing: ReaderStyle.compactSpacing) {
            HStack {
                Text("Highlight color")
                    .font(.headline)
                Spacer()
                ColorPicker("Custom", selection: $draft.color, supportsOpacity: false)
                    .fixedSize()
                    .accessibilityLabel("Custom highlight color")
            }

            HStack(spacing: 10) {
                ForEach(MarkerColor.palette.indices, id: \.self) { index in
                    MarkerColorSwatch(markerColor: MarkerColor.palette[index], name: names.indices.contains(index) ? names[index] : "Color \(index + 1)", selection: $draft.color)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Highlight color presets")
        }
    }
}
