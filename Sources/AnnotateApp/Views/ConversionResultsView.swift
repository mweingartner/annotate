import AnnotateCore
import Atrium
import SwiftUI

enum ConversionBatchMode: String, CaseIterable, Identifiable {
    case convert = "Convert files"
    case createPDF = "Create PDFs"
    case compress = "Compress PDFs"
    case ocr = "Recognize text"
    var id: String { rawValue }
}

/// One row per batch file: its name, whether it worked (symbol and word), what happened,
/// and where the result went. Rows are separated by hairlines, not boxes.
struct ConversionResultsView: View {
    let results: [PDFConversionBatchResult]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(results) { result in
                Hairline()
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.snug) {
                        Text(result.input.lastPathComponent)
                            .font(Typography.heading)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        StatusBadge(result.succeeded ? "Done" : "Failed", kind: result.succeeded ? .positive : .caution)
                            .fixedSize()
                    }
                    Text(result.message)
                        .font(Typography.supporting)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let output = result.output {
                        Button("Show result in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([output])
                        }
                        .buttonStyle(.quiet)
                        .font(Typography.supporting)
                    }
                }
                .padding(.vertical, Spacing.snug)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
