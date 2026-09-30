import AnnotateCore
import Atrium
import PDFKit
import SwiftUI

/// The Pages inspector: insert, select, rotate, extract, delete, split and reorder pages.
struct PagesPanel: View {
    @Bindable var model: ReaderModel
    @State private var selected = IndexSet()
    @State private var range = ""
    @State private var splitSize = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Drag a thumbnail onto another page to move it there. Use the arrows for keyboard control.")
                .font(Typography.supporting).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Spacing.group)
            PageSection("Insert") {
                // Side by side when the column allows, stacked when it doesn't.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.snug) { insertButtons }
                    VStack(alignment: .leading, spacing: Spacing.snug) { insertButtons }
                }
            }
            PageSection("Selected pages") {
                VStack(alignment: .leading, spacing: Spacing.control) {
                    HStack(spacing: Spacing.snug) {
                        TextField("Pages, e.g. 1, 3–5", text: $range)
                            .accessibilityLabel("Page selection range")
                        Button("Select", action: selectRange)
                    }
                    HStack(spacing: Spacing.tight) {
                        Button("Rotate left", systemImage: "rotate.left") { model.rotatePages(selection, clockwise: false) }
                            .labelStyle(.iconOnly).help("Rotate selected pages left")
                        Button("Rotate right", systemImage: "rotate.right") { model.rotatePages(selection, clockwise: true) }
                            .labelStyle(.iconOnly).help("Rotate selected pages right")
                        Button("Extract…", action: extract)
                        Button("Delete", systemImage: "trash", role: .destructive, action: remove)
                            .labelStyle(.iconOnly).help("Delete selected pages")
                            .disabled(selection.count == model.pageCount)
                    }
                    .buttonStyle(.quiet)
                }
            }
            PageSection("Split") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.snug) { splitControls }
                    VStack(alignment: .leading, spacing: Spacing.snug) { splitControls }
                }
            }
            Text("\(selection.count) selected • \(model.pageCount) pages")
                .font(Typography.meta).foregroundStyle(.secondary)
                .padding(.bottom, Spacing.snug)
            LazyVStack(spacing: 0) {
                ForEach(0..<model.pageCount, id: \.self) { index in
                    if index > 0 { Hairline() }
                    PageThumbnailRow(model: model, index: index, selected: selected.contains(index), toggle: { toggle(index) })
                        .padding(.vertical, Spacing.hair)
                        .draggable(String(index))
                        .dropDestination(for: String.self) { values, _ in
                            guard let value = values.first, let source = Int(value), source != index,
                                  (0..<model.pageCount).contains(source) else { return false }
                            model.movePage(source, to: index)
                            selected = IndexSet(integer: index)
                            return true
                        }
                }
            }
        }
        .onChange(of: model.documentRevision) { selected = IndexSet(selected.filter { $0 < model.pageCount }) }
        .disabled(model.isProcessing)
    }

    @ViewBuilder
    private var insertButtons: some View {
        Button("Insert files…", systemImage: "doc.badge.plus", action: model.importPages)
        Button("Blank", systemImage: "plus.rectangle", action: model.insertBlankPage)
    }

    @ViewBuilder
    private var splitControls: some View {
        Stepper("Split every \(splitSize) page(s)", value: $splitSize, in: 1...max(1, model.pageCount))
        Button("Split…") { model.splitPages(every: splitSize) }
    }

    private var selection: IndexSet { selected.isEmpty ? IndexSet(integer: max(0, model.pageNumber - 1)) : selected }
    private func toggle(_ index: Int) {
        if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
    }
    private func selectRange() {
        do { selected = try PDFPageRange.parse(range, pageCount: model.pageCount) }
        catch { model.errorMessage = error.localizedDescription }
    }
    private func extract() { model.extractPages(selection) }
    private func remove() { model.deletePages(selection); selected = [] }
}
