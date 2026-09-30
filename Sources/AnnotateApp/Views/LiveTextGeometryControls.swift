import Atrium
import SwiftUI

/// Position and size of the text block's frame, in PDF points.
struct LiveTextGeometryControls: View {
    @Bindable var session: LiveTextEdit

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Grid(alignment: .leading, horizontalSpacing: Spacing.snug, verticalSpacing: Spacing.snug) {
                GridRow {
                    Text("X")
                    TextField("Horizontal position", value: $session.x, format: .number.precision(.fractionLength(0...1)))
                        .accessibilityLabel("Text box horizontal position in points")
                    Text("Y")
                    TextField("Vertical position", value: $session.y, format: .number.precision(.fractionLength(0...1)))
                        .accessibilityLabel("Text box vertical position in points")
                }
                GridRow {
                    Text("Width")
                    TextField("Width", value: $session.width, format: .number.precision(.fractionLength(0...1)))
                        .accessibilityLabel("Text box width in points")
                    Text("Height")
                    TextField("Height", value: $session.height, format: .number.precision(.fractionLength(0...1)))
                        .accessibilityLabel("Text box height in points")
                }
            }.font(Typography.supporting).textFieldStyle(.roundedBorder)
            Text("PDF points, measured from the page’s lower-left corner.")
                .font(Typography.supporting).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !session.geometryIsValid {
                Label {
                    Text("Keep the box within the page with a positive width and height.").fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.Status.caution)
                }
                .font(Typography.supporting)
            }
        }
    }
}
