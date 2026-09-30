import Atrium
import SwiftUI

/// Letter, line and paragraph spacing for the open text, in points.
struct LiveTextSpacingControls: View {
    @Bindable var session: LiveTextEdit
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Spacing", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: Spacing.control) {
                spacing("Between letters", value: $session.letterSpacing)
                spacing("Between lines", value: $session.lineSpacing)
                spacing("After paragraph", value: $session.paragraphSpacing)
                Text("Letter spacing affects selected characters. Line and paragraph spacing affect their paragraphs.")
                    .font(Typography.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.top, Spacing.snug)
        }
    }

    private func spacing(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: Spacing.snug) {
            Text(label).font(Typography.body)
            Spacer(minLength: Spacing.snug)
            TextField(label, value: value, format: .number.precision(.fractionLength(0...2)))
                .frame(width: Metrics.row * 2).textFieldStyle(.roundedBorder).accessibilityLabel(label + " in points")
            Text("pt").font(Typography.meta).foregroundStyle(.secondary)
        }
    }
}
