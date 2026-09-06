import AnnotateCore
import PDFKit
import SwiftUI

struct PagesPanel: View {
    @Bindable var model: ReaderModel
    @State private var selected = IndexSet()
    @State private var range = ""
    @State private var splitSize = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Organize pages").font(.title2.bold())
            Text("Drag a thumbnail onto another page to move it there. Use the arrows for keyboard control.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Insert files…", systemImage: "doc.badge.plus", action: model.importPages)
                Button("Blank", systemImage: "plus.rectangle", action: model.insertBlankPage)
            }
            HStack {
                TextField("Pages, e.g. 1, 3–5", text: $range)
                    .accessibilityLabel("Page selection range")
                Button("Select", action: selectRange)
            }
            HStack {
                Button("Rotate left", systemImage: "rotate.left") { model.rotatePages(selection, clockwise: false) }
                    .labelStyle(.iconOnly).help("Rotate selected pages left")
                Button("Rotate right", systemImage: "rotate.right") { model.rotatePages(selection, clockwise: true) }
                    .labelStyle(.iconOnly).help("Rotate selected pages right")
                Button("Extract…", action: extract)
                Button("Delete", systemImage: "trash", role: .destructive, action: remove)
                    .labelStyle(.iconOnly).help("Delete selected pages")
                    .disabled(selection.count == model.pageCount)
            }
            HStack {
                Stepper("Split every \(splitSize) page(s)", value: $splitSize, in: 1...max(1, model.pageCount))
                Button("Split…") { model.splitPages(every: splitSize) }
            }.font(.caption)
            Text("\(selection.count) selected • \(model.pageCount) pages").font(.caption).foregroundStyle(.secondary)
            LazyVStack(spacing: 8) {
                ForEach(0..<model.pageCount, id: \.self) { index in
                    PageThumbnailRow(model: model, index: index, selected: selected.contains(index), toggle: { toggle(index) })
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
