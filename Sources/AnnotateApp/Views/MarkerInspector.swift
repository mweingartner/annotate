import Atrium
import SwiftUI

/// Writing a marker: what it is, what it looks like, and what the reader thinks.
struct MarkerInspector: View {
    @Bindable var model: ReaderModel

    var body: some View {
        if let draft = model.draft {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: Spacing.tight) {
                                Text(title(for: draft))
                                    .font(Typography.title)
                                    .accessibilityAddTraits(.isHeader)
                                Text(MarkerPresentation.pageLabel(regions: draft.regions))
                                    .font(Typography.supporting)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: Spacing.snug)
                            if !draft.isEditing, !draft.quote.isEmpty {
                                PassageActions(model: model)
                            }
                        }
                        .padding(.bottom, Spacing.margin)
                        MarkerDraftEditor(draft: draft)
                    }
                    .padding(Spacing.group)
                }
                Hairline()
                HStack {
                    Button("Cancel", action: model.cancelDraft)
                        .keyboardShortcut(.escape, modifiers: [])
                        .help("Discard this draft")
                    Spacer()
                    Button(draft.isEditing ? "Save Changes" : draft.quote.isEmpty ? "Add Bookmark" : "Add Annotation",
                           action: model.saveDraft)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!model.canEdit)
                        .help("Save (⌘Return)")
                }
                .controlSize(.large)
                .padding(Spacing.group)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Marker editor")
        }
    }

    private func title(for draft: MarkerDraft) -> String {
        if draft.isEditing { return draft.quote.isEmpty ? "Edit Bookmark" : "Edit Annotation" }
        return draft.quote.isEmpty ? "Bookmark Page" : "Annotate Passage"
    }
}
