import Atrium
import PDFKit
import SwiftUI

/// One page in the Pages inspector: a selection check, the thumbnail that opens the page,
/// and arrows that move it one place for keyboard users.
struct PageThumbnailRow: View {
    @Bindable var model: ReaderModel
    let index: Int
    let selected: Bool
    let toggle: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: Spacing.snug) {
            Button(selected ? "Deselect page \(index + 1)" : "Select page \(index + 1)",
                   systemImage: selected ? "checkmark.circle.fill" : "circle", action: toggle)
                .labelStyle(.iconOnly)
                .buttonStyle(.quiet)
            Button(action: navigate) {
                HStack(spacing: Spacing.snug) {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                            .frame(width: Spacing.room, height: Metrics.row + Metrics.doubleRow)
                            .accessibilityHidden(true)
                    }
                    Text("Page \(index + 1)").font(Typography.body.weight(model.pageNumber == index + 1 ? .bold : .regular))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Spacing.tight)
                .contentShape(.rect)
            }
            .buttonStyle(.quiet)
            VStack(spacing: 0) {
                Button("Move page \(index + 1) earlier", systemImage: "chevron.up") { model.movePage(index, to: index - 1) }
                    .labelStyle(.iconOnly).disabled(index == 0)
                Button("Move page \(index + 1) later", systemImage: "chevron.down") { model.movePage(index, to: index + 1) }
                    .labelStyle(.iconOnly).disabled(index + 1 == model.pageCount)
            }
            .buttonStyle(.quiet)
        }
        .padding(.horizontal, Spacing.tight)
        // Selection is the one persistent fill; hover and press washes come from the quiet buttons.
        .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: Radius.field))
        .task(id: model.documentRevision) { thumbnail = model.pdfDocument?.page(at: index)?.thumbnail(of: CGSize(width: 108, height: 144), for: .cropBox) }
    }
    private func navigate() { model.goToPage(index + 1) }
}
