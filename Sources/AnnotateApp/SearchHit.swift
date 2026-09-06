import PDFKit
import SwiftUI

struct SearchHit: Identifiable {
    let id = UUID()
    let pageIndex: Int
    let snippet: AttributedString
    let selection: PDFSelection?
    let bounds: CGRect?

    init(pageIndex: Int, snippet: AttributedString, selection: PDFSelection) {
        self.pageIndex = pageIndex; self.snippet = snippet; self.selection = selection; bounds = nil
    }

    init(pageIndex: Int, snippet: AttributedString, bounds: CGRect) {
        self.pageIndex = pageIndex; self.snippet = snippet; selection = nil; self.bounds = bounds
    }
}
