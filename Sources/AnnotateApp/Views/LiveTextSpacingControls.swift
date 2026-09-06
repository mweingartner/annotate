import SwiftUI

struct LiveTextSpacingControls: View {
    @Bindable var session: LiveTextEdit
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Spacing", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                spacing("Between letters", value: $session.letterSpacing)
                spacing("Between lines", value: $session.lineSpacing)
                spacing("After paragraph", value: $session.paragraphSpacing)
                Text("Letter spacing affects selected characters. Line and paragraph spacing affect their paragraphs.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 8)
        }
    }

    private func spacing(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).font(.callout)
            Spacer()
            TextField(label, value: value, format: .number.precision(.fractionLength(0...2)))
                .frame(width: 60).textFieldStyle(.roundedBorder).accessibilityLabel(label + " in points")
            Text("pt").font(.caption).foregroundStyle(.secondary)
        }
    }
}
