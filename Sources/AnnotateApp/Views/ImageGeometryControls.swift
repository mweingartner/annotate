import SwiftUI

struct ImageGeometryControls: View {
    @Bindable var session: ImageEditSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("X")
                    TextField("Horizontal position", value: $session.x, format: .number.precision(.fractionLength(0...1)))
                        .accessibilityLabel("Image horizontal position in PDF points")
                    Text("Y")
                    TextField("Vertical position", value: $session.y, format: .number.precision(.fractionLength(0...1)))
                        .accessibilityLabel("Image vertical position in PDF points")
                }
                GridRow {
                    Text("Width")
                    TextField("Width", value: $session.width, format: .number.precision(.fractionLength(0...1)))
                        .accessibilityLabel("Image width in PDF points")
                    Text("Height")
                    TextField("Height", value: $session.height, format: .number.precision(.fractionLength(0...1)))
                        .accessibilityLabel("Image height in PDF points")
                }
            }.font(.caption).textFieldStyle(.roundedBorder)
            Toggle("Keep frame proportions", isOn: $session.keepsAspectRatio).toggleStyle(.checkbox)
            Text("PDF points from the page’s lower-left corner. The outline previews the new frame.")
                .font(.caption).foregroundStyle(.secondary)
            if !session.geometryIsValid {
                Label("Keep the image within the page, at least 1 pt wide and high.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
