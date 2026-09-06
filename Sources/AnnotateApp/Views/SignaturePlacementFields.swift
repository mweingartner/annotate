import SwiftUI

struct SignaturePlacementFields: View {
    @Binding var left: Double
    @Binding var top: Double
    @Binding var width: Double
    @Binding var height: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Position and size (% of visible page)").font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Left")
                    TextField("Left %", value: $left, format: .number).accessibilityLabel("Left position percent")
                    Text("Top")
                    TextField("Top %", value: $top, format: .number).accessibilityLabel("Top position percent")
                }
                GridRow {
                    Text("Width")
                    TextField("Width %", value: $width, format: .number).accessibilityLabel("Width percent")
                    Text("Height")
                    TextField("Height %", value: $height, format: .number).accessibilityLabel("Height percent")
                }
            }.font(.caption)
        }
    }
}
