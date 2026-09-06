import SwiftUI

struct WorkspacePanel: View {
    @Bindable var model: ReaderModel
    let tool: WorkspaceTool
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(tool.title, systemImage: tool.symbol).font(.headline)
                Spacer()
                Button("Close tool", systemImage: "xmark") {
                    if model.finishLiveText() { model.activeTool = nil; model.selectingToolArea = false }
                }.labelStyle(.iconOnly).buttonStyle(.borderless)
            }.padding(16)
            Divider()
            ScrollView {
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
                .padding(16)
            }
        }
        .background(.background)
    }
}
