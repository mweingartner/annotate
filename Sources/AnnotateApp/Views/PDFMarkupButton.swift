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
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
