import Atrium
import SwiftUI

/// The inspector for a workspace tool: a pane title, then the tool's controls.
struct WorkspacePanel: View {
    @Bindable var model: ReaderModel
    let tool: WorkspaceTool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(Typography.title)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: Spacing.snug)
                    Button("Close", systemImage: "xmark", action: model.closeActiveTool)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.quiet)
                        .help("Close \(tool.title) and return to reading")
                }
                .padding(.bottom, Spacing.group)
                Group {
                    switch tool {
                    case .edit: EditPanel(model: model)
                    case .pages: PagesPanel(model: model)
                    case .forms: FormsPanel(model: model)
                    case .sign: SignaturesPanel(model: model)
                    case .convert: ConversionPanel(model: model)
                    case .redact: RedactionPanel(model: model)
                    case .assistant: AssistantPanel(model: model)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Spacing.group)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private var title: String {
        guard tool == .edit, let session = model.liveEdit else { return tool.title }
        return session.isExistingContent ? "Edit Text" : "New Text"
    }
}
