import SwiftUI

struct ReaderView: View {
    @Bindable var model: ReaderModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ReaderHeader(model: model)
            Divider()
            WorkspaceToolbar(model: model)
            Divider()
            if let message = model.errorMessage {
                ReaderErrorBanner(message: message, dismiss: dismissError)
                Divider()
            }
            if model.pdfDocument == nil {
                if model.activeTool == .convert { WorkspacePanel(model: model, tool: .convert).frame(maxWidth: 640) }
                else { WelcomeView(model: model) }
            } else {
                HSplitView {
                    if model.sidebarVisible {
                        MarkerSidebar(model: model)
                            .frame(minWidth: ReaderStyle.panelMinimum, idealWidth: ReaderStyle.panelIdeal, maxWidth: ReaderStyle.panelMaximum)
                            .transition(panelTransition(edge: .leading))
                    }
                    PDFReaderView(model: model)
                        .frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("PDF document")
                    if let tool = model.activeTool {
                        WorkspacePanel(model: model, tool: tool)
                            .frame(minWidth: 360, idealWidth: 390, maxWidth: 460)
                    } else if model.inspectorVisible, model.draft != nil {
                        MarkerInspector(model: model)
                            .frame(minWidth: 292, idealWidth: 318, maxWidth: ReaderStyle.panelMaximum)
                            .transition(panelTransition(edge: .trailing))
                    }
                }
                Divider()
                ReaderStatusBar(model: model)
            }
        }
        .tint(ReaderStyle.accent)
        .background(.background)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.sidebarVisible)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.inspectorVisible)
    }

    private func panelTransition(edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    private func dismissError() {
        model.errorMessage = nil
    }
}
