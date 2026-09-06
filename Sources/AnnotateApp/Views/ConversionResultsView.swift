import AnnotateCore
import SwiftUI

enum ConversionBatchMode: String, CaseIterable, Identifiable {
    case convert = "Convert files"
    case createPDF = "Create PDFs"
    case compress = "Compress PDFs"
    case ocr = "Recognize text"
    var id: String { rawValue }
}

struct ConversionResultsView: View {
    let results: [PDFConversionBatchResult]
    var body: some View {
        ForEach(results) { result in
            VStack(alignment: .leading, spacing: 4) {
                Label(result.input.lastPathComponent, systemImage: result.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.callout).bold()
                Text(result.message).font(.caption).textSelection(.enabled)
                if let output = result.output {
                    Button("Show result in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([output])
                    }
                    .font(.caption)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: .rect(cornerRadius: 8))
        }
    }
}
