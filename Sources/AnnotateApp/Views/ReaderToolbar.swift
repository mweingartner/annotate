import SwiftUI

/// The unified glass toolbar: the workspace modes in the centre, then zoom, bookmark and
/// document actions. Three groups, symbols only, a tooltip on every item (Atrium).
struct ReaderToolbar: ToolbarContent {
    @Bindable var model: ReaderModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            modeToggle(title: "Read", symbol: "book", help: "Read and annotate: select a passage to mark it",
                       isOn: model.activeTool == nil) { model.closeActiveTool() }
            ForEach(WorkspaceTool.allCases) { tool in
                modeToggle(title: tool.title, symbol: tool.symbol, help: tool.help, isOn: model.activeTool == tool) {
                    if model.activeTool != tool { model.showTool(tool) }
                }
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                Button("Zoom Out", systemImage: "minus.magnifyingglass", action: model.zoomOut)
                    .help("Zoom out (⌘−)")
                Button("Zoom In", systemImage: "plus.magnifyingglass", action: model.zoomIn)
                    .help("Zoom in (⌘+)")
            } label: {
                Label("Zoom", systemImage: "magnifyingglass")
            }
            .help("Zoom")

            Button("Add Bookmark", systemImage: "bookmark", action: model.markCurrentPageFromWorkspace)
                .disabled(!model.canEdit || model.isProcessing)
                .help("Bookmark this page (⇧⌘M). Select text first to annotate a passage instead.")

            Menu("Document", systemImage: "ellipsis") {
                Button("Save", systemImage: "square.and.arrow.down", action: model.saveDocument)
                    .disabled(!model.canEdit)
                Button("Export Annotated PDF…", systemImage: "square.and.arrow.up", action: model.exportDocument)
                Button("Print…", systemImage: "printer", action: model.printDocument)
                Divider()
                Button("Fit Width", systemImage: "arrow.left.and.right", action: model.fitPage)
                Button("Open PDF…", systemImage: "folder", action: model.openDocument)
            }
            .menuIndicator(.hidden)
            .help("Save, export, print and view options")
        }
    }

    /// A mode button that reads as selected while its mode is active. Toggles, not a
    /// segmented picker, so every mode keeps its own tooltip.
    private func modeToggle(title: String, symbol: String, help: String, isOn: Bool,
                            activate: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { if $0 { activate() } })) {
            Label(title, systemImage: symbol)
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .help(help)
        .accessibilityLabel(title)
    }
}
