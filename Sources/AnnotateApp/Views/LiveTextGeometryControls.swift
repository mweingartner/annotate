import SwiftUI

struct LiveTextGeometryControls: View {
    @Bindable var session: LiveTextEdit

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
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
            }.font(.caption).textFieldStyle(.roundedBorder)
            Text("PDF points, measured from the page’s lower-left corner.")
                .font(.caption).foregroundStyle(.secondary)
            if !session.geometryIsValid {
                Label("Keep the box within the page with a positive width and height.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
