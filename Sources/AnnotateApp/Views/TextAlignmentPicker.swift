import Atrium
import SwiftUI

/// Paragraph alignment as a segmented row of symbols.
struct TextAlignmentPicker: View {
    @Binding var alignment: NSTextAlignment

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Text("Paragraph alignment").font(Typography.body)
            Picker("Paragraph alignment", selection: $alignment) {
                Label("Align left", systemImage: "text.alignleft").tag(NSTextAlignment.left)
                Label("Center", systemImage: "text.aligncenter").tag(NSTextAlignment.center)
                Label("Align right", systemImage: "text.alignright").tag(NSTextAlignment.right)
                Label("Justify", systemImage: "text.justify").tag(NSTextAlignment.justified)
                if alignment == .natural { Text("Natural").tag(NSTextAlignment.natural) }
            }
            .labelsHidden().labelStyle(.iconOnly).pickerStyle(.segmented)
            .accessibilityLabel("Paragraph alignment")
        }
    }
}
