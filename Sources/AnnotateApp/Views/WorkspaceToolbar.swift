import SwiftUI

struct WorkspaceToolbar: View {
    @Bindable var model: ReaderModel
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
            Button("Read", systemImage: "book") {
                if model.finishLiveText() { model.activeTool = nil; model.selectingToolArea = false }
            }
            .tint(model.activeTool == nil ? ReaderStyle.accent : .secondary)
            .help("Read, select passages to annotate, and open saved marker tags")
            .accessibilityAddTraits(model.activeTool == nil ? .isSelected : [])
            Divider().frame(height: 20)
            ForEach(WorkspaceTool.allCases) { tool in
                Button(tool.title, systemImage: tool.symbol) { model.showTool(tool) }
                    .tint(model.activeTool == tool ? ReaderStyle.accent : .secondary)
                    .disabled(model.pdfDocument == nil && tool != .convert)
                    .accessibilityAddTraits(model.activeTool == tool ? .isSelected : [])
                    .help(tool.help)
            }
            Spacer(minLength: 0)
            if model.isProcessing {
                ProgressView().controlSize(.small)
                Text(model.operationProgress).font(.caption).lineLimit(1)
                Button("Cancel operation", systemImage: "xmark") { model.operationTask?.cancel() }.labelStyle(.iconOnly)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
