import AnnotateCore
import PDFKit

extension ReaderModel {
    /// Extract the actual selection by line so multi-page passages retain their real source page.
    func assistantSelection() throws -> [DocumentAssistantSource] {
        guard let document = pdfDocument, !document.isLocked, document.allowsCopying else {
            throw DocumentAssistantError.copyingRestricted
        }
        guard let selection = pdfView?.currentSelection else { return [] }
        var byPage: [Int: [String]] = [:]
        for line in selection.selectionsByLine() {
            guard let page = line.pages.first, let text = line.string, !text.isEmpty else { continue }
            let index = document.index(for: page)
            guard index != NSNotFound, index < document.pageCount else { continue }
            byPage[index + 1, default: []].append(text)
        }
        return byPage.keys.sorted().map {
            DocumentAssistantSource(pageNumber: $0, text: byPage[$0, default: []].joined(separator: "\n"))
        }
    }
}
