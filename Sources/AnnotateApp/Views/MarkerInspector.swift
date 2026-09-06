import SwiftUI

struct MarkerInspector: View {
    @Bindable var model: ReaderModel

    var body: some View {
        if let draft = model.draft {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(draft.isEditing ? "Edit marker" : draft.quote.isEmpty ? "Mark this page" : "Annotate passage")
                            .font(.title2)
                            .fontDesign(.serif)
                            .bold()
                        Text(MarkerPresentation.pageLabel(regions: draft.regions))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: ReaderStyle.compactSpacing)
                    Button("Cancel annotation", systemImage: "xmark", action: model.cancelDraft)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Discard this draft and close the annotation panel")
                }
                .padding(ReaderStyle.panelPadding)
                Divider()

                if !draft.isEditing, !draft.quote.isEmpty {
                    PassageActions(model: model)
                    Divider()
                }

                MarkerDraftEditor(draft: draft)

                Divider()
                HStack {
                    Button("Cancel", action: model.cancelDraft)
                        .keyboardShortcut(.escape, modifiers: [])
                    Spacer()
                    Button(draft.isEditing ? "Save changes" : "Add marker", systemImage: draft.isEditing ? "checkmark" : "plus", action: model.saveDraft)
                        .buttonStyle(.borderedProminent)
                        .tint(ReaderStyle.actionFill)
                        .foregroundStyle(.white)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!model.canEdit)
                        .help("Save this annotation (⌘Return)")
                }
                .padding(ReaderStyle.panelPadding)
            }
            .background(.background.secondary)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Annotation editor")
        }
    }
}
