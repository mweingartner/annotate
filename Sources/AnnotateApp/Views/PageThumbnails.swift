import Atrium
import PDFKit
import SwiftUI

/// Page thumbnails, as in Preview: PDFKit's own thumbnail view, bound to the reader so
/// it follows the current page and moves the reader when a page is chosen.
struct PageThumbnails: NSViewRepresentable {
    @Bindable var model: ReaderModel

    func makeNSView(context: Context) -> SidebarThumbnailView {
        let view = SidebarThumbnailView()
        view.maximumNumberOfColumns = 1
        view.backgroundColor = .clear
        view.allowsDragging = false
        view.allowsMultipleSelection = false
        view.setAccessibilityLabel("Page thumbnails")
        return view
    }

    func updateNSView(_ view: SidebarThumbnailView, context: Context) {
        // The PDF view is registered once it exists; revisions and page counts change
        // after edits and page operations, so reading them here keeps the binding fresh.
        _ = model.documentRevision
        _ = model.pageCount
        if view.pdfView !== model.pdfView { view.pdfView = model.pdfView }
    }
}

/// Sizes thumbnails to the sidebar's width, leaving room for the selection ring.
final class SidebarThumbnailView: PDFThumbnailView {
    override func layout() {
        super.layout()
        let width = max(Metrics.row, bounds.width - Spacing.room)
        // Letter-shaped cells; PDFKit fits each page inside its cell.
        let size = CGSize(width: width, height: (width * 1.3).rounded())
        if thumbnailSize != size { thumbnailSize = size }
    }
}
