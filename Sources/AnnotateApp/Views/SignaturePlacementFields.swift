import Atrium
import SwiftUI

/// Where a signature or form field goes, as percentages of the visible page.
struct SignaturePlacementFields: View {
    @Binding var left: Double
    @Binding var top: Double
    @Binding var width: Double
    @Binding var height: Double

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Text("Position and size (% of visible page)")
                .font(Typography.supporting).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: Spacing.snug, verticalSpacing: Spacing.snug) {
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
            }
            .font(Typography.supporting)
        }
    }
}
