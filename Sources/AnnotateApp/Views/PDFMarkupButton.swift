import PDFKit
import SwiftUI

struct PDFMarkupButton: View {
    let model: ReaderModel
    let title: String
    let icon: String
    let type: PDFAnnotationSubtype
    let color: Color

    var body: some View {
        Button(title, systemImage: icon) { model.addToolMarkup(type, color: NSColor(color)) }
            .buttonStyle(.quiet)
            .help("\(title) the selected text or area")
    }
}
