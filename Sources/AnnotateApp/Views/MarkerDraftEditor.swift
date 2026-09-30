import AnnotateCore
import Atrium
import SwiftUI

/// The body of the marker inspector: the passage, what kind of marker it is, how it
/// looks on the page, and the reader's own words. Space and labels group it; no boxes.
struct MarkerDraftEditor: View {
    @Bindable var draft: MarkerDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !draft.quote.isEmpty {
                Text(draft.quote)
                    .font(Typography.body)
                    .lineLimit(7)
                    .textSelection(.enabled)
                    .help(draft.quote)
                    .padding(.leading, Spacing.control)
                    .overlay(alignment: .leading) {
                        Capsule().fill(draft.color).frame(width: Spacing.tight)
                    }
                    .padding(.bottom, Spacing.section)
                    .accessibilityLabel("Selected passage: \(draft.quote)")
            }

            PageSection("Keep As") {
                Grid(alignment: .leading, horizontalSpacing: Spacing.group, verticalSpacing: Spacing.snug) {
                    GridRow { toggle(.important); toggle(.revisit) }
                    GridRow { toggle(.question); toggle(.note) }
                }
                Text("Choose one or more. Notes and questions join their lists on their own.")
                    .font(Typography.supporting)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.snug)
            }

            PageSection("Look") {
                MarkerColorPicker(draft: draft)
                MarkerIconPicker(draft: draft)
                    .padding(.top, Spacing.control)
            }

            PageSection("Note") {
                TextField("What would you like to remember?", text: $draft.note, axis: .vertical)
                    .lineLimit(3...8)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Marker note")
            }

            PageSection("Question") {
                TextField("What do you want to explore?", text: $draft.question, axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Marker question")
            }
        }
    }

    private func toggle(_ category: MarkerCategory) -> some View {
        Toggle(isOn: Binding(get: { draft.categories.contains(category) },
                             set: { if $0 { draft.categories.insert(category) } else { draft.categories.remove(category) } })) {
            Label(category.title, systemImage: category.symbol)
        }
        .toggleStyle(.checkbox)
        .accessibilityHint("A marker can belong to more than one category")
    }
}
