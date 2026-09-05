import SwiftUI
import AnnotateCore

struct MarkerDraftEditor: View {
    @Bindable var draft: MarkerDraft

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !draft.quote.isEmpty {
                    VStack(alignment: .leading, spacing: ReaderStyle.compactSpacing) {
                        Text("SELECTED PASSAGE")
                            .font(.caption)
                            .tracking(1)
                            .foregroundStyle(.secondary)
                        Text(draft.quote)
                            .font(.body)
                            .fontDesign(.serif)
                            .lineLimit(7)
                            .textSelection(.enabled)
                            .help(draft.quote)
                            .padding(.leading, 12)
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(draft.color)
                                    .frame(width: 3)
                            }
                    }
                }

                VStack(alignment: .leading, spacing: ReaderStyle.compactSpacing) {
                    Text("Keep it as…")
                        .font(.headline)
                    Text("Choose one or more categories.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: ReaderStyle.compactSpacing) {
                        ForEach([MarkerCategory.important, .revisit, .question, .note], id: \.self) { category in
                            MarkerCategoryToggle(draft: draft, category: category)
                        }
                    }
                }

                MarkerColorPicker(draft: draft)
                MarkerIconPicker(draft: draft)

                VStack(alignment: .leading, spacing: ReaderStyle.compactSpacing) {
                    Label("Your note", systemImage: "note.text")
                        .font(.headline)
                    TextField("What would you like to remember?", text: $draft.note, axis: .vertical)
                        .lineLimit(3...8)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(.background, in: .rect(cornerRadius: 9))
                        .overlay { RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.12), lineWidth: 1) }
                        .accessibilityLabel("Annotation note")
                }

                VStack(alignment: .leading, spacing: ReaderStyle.compactSpacing) {
                    Label("Your question", systemImage: "questionmark.bubble")
                        .font(.headline)
                    TextField("What do you want to explore?", text: $draft.question, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(.background, in: .rect(cornerRadius: 9))
                        .overlay { RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.12), lineWidth: 1) }
                        .accessibilityLabel("Annotation question")
                }

                Text("Notes and questions join their lists automatically. You can return to this passage from any of its categories.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(ReaderStyle.panelPadding)
        }
    }
}
