import PDFKit
import SwiftUI

struct SearchHit: Identifiable {
    let id = UUID()
    let pageIndex: Int
    let snippet: AttributedString
    let selection: PDFSelection
}
