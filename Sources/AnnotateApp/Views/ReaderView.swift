import Atrium
import SwiftUI

/// The document window: a glass sidebar of markers and pages, the PDF canvas edge to
/// edge beneath a unified glass toolbar, and one inspector for the active tool or the
/// marker being written. Atrium's main-window recipe; see Docs/INTERFACE_DESIGN.md.
struct ReaderView: View {
    @Bindable var model: ReaderModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        if model.pdfDocument == nil {
            WelcomeWindowContent(model: model)
        } else {
            reader
        }
    }

    private var reader: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            ReaderSidebar(model: model)
                .navigationSplitViewColumnWidth(min: Metrics.sidebar.min, ideal: Metrics.sidebar.ideal, max: Metrics.sidebar.max)
        } detail: {
            ReaderCanvas(model: model)
        }
        .inspector(isPresented: inspectorPresented) {
            ReaderInspector(model: model)
                .inspectorColumnWidth(min: Metrics.inspector.min, ideal: Metrics.inspector.max, max: Metrics.inspector.max)
        }
        .toolbar { ReaderToolbar(model: model) }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search PDF")
        .searchFocused($searchFocused)
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
        .onChange(of: model.query) { _, query in
            // Results are listed in the sidebar, so a search brings it back.
            if !query.isEmpty, !model.sidebarVisible { model.sidebarVisible = true }
        }
        .atriumAnimation(value: model.activeTool)
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { model.sidebarVisible ? .all : .detailOnly },
                set: { model.sidebarVisible = $0 != .detailOnly })
    }

    /// The inspector shows the active tool, or else the marker draft. Closing it is the
    /// same as the panel's close button: finish the tool, or discard the draft.
    private var inspectorPresented: Binding<Bool> {
        Binding(get: { model.activeTool != nil || (model.inspectorVisible && model.draft != nil) },
                set: { presented in
                    guard !presented else { return }
                    if model.activeTool != nil { model.closeActiveTool() } else { model.cancelDraft() }
                })
    }
}

/// The welcome window has no document: its own page, or the converter when asked.
private struct WelcomeWindowContent: View {
    @Bindable var model: ReaderModel

    var body: some View {
        VStack(spacing: 0) {
            if let message = model.errorMessage {
                ReaderErrorBanner(message: message) { model.errorMessage = nil }
                    .padding(Spacing.group)
            }
            if model.activeTool == .convert {
                WorkspacePanel(model: model, tool: .convert)
                    .frame(maxWidth: Metrics.readableWidth)
                    .frame(maxWidth: .infinity)
            } else {
                WelcomeView(model: model)
            }
        }
        .background(.background)
    }
}

/// The inspector column's content.
private struct ReaderInspector: View {
    @Bindable var model: ReaderModel

    var body: some View {
        if let tool = model.activeTool {
            WorkspacePanel(model: model, tool: tool)
        } else if model.draft != nil {
            MarkerInspector(model: model)
        }
    }
}
