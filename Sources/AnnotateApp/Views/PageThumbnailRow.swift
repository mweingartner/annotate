import PDFKit
import SwiftUI

struct PageThumbnailRow: View {
    @Bindable var model: ReaderModel
    let index: Int
    let selected: Bool
    let toggle: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            Button(selected ? "Deselect page \(index + 1)" : "Select page \(index + 1)",
                   systemImage: selected ? "checkmark.circle.fill" : "circle", action: toggle)
                .labelStyle(.iconOnly)
            Button(action: navigate) {
                HStack {
                    if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit().frame(width: 54, height: 72).accessibilityHidden(true) }
                    Text("Page \(index + 1)").font(.body.weight(model.pageNumber == index + 1 ? .bold : .regular))
                    Spacer()
                }
            }.buttonStyle(.plain)
            VStack {
                Button("Move page \(index + 1) earlier", systemImage: "chevron.up") { model.movePage(index, to: index - 1) }
                    .labelStyle(.iconOnly).disabled(index == 0)
                Button("Move page \(index + 1) later", systemImage: "chevron.down") { model.movePage(index, to: index + 1) }
                    .labelStyle(.iconOnly).disabled(index + 1 == model.pageCount)
            }
        }
        .padding(8)
        .background(selected ? ReaderStyle.accent.opacity(0.12) : Color.secondary.opacity(0.06), in: .rect(cornerRadius: 8))
        .task(id: model.documentRevision) { thumbnail = model.pdfDocument?.page(at: index)?.thumbnail(of: CGSize(width: 108, height: 144), for: .cropBox) }
    }
    private func navigate() { model.goToPage(index + 1) }
}
