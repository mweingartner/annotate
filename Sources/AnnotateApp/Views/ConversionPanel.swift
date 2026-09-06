import AnnotateCore
import SwiftUI

struct ConversionPanel: View {
    @Bindable var model: ReaderModel
    @State private var format: PDFConversionFormat = .docx
    @State private var scale = 2.0
    @State private var compression: PDFCompressionLevel = .balanced
    @State private var compressionResult = ""
    @State private var language = ""
    @State private var recognizeEveryPage = false
    @State private var recognitionResult = ""
    @State private var batchMode: ConversionBatchMode = .convert
    @State private var batchResults: [PDFConversionBatchResult] = []

    private var ocrOptions: PDFOCROptions { PDFOCROptions(languages: language.isEmpty ? [] : [language], recognizeEveryPage: recognizeEveryPage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Convert & recognize").font(.title2).fontDesign(.serif).bold()
            importSection
            Divider()
            exportSection
            Divider()
            compressionSection
            Divider()
            recognitionSection
            Divider()
            batchSection
        }
        .padding(18)
        .disabled(model.isProcessing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversion tools")
    }

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Create a PDF").font(.headline)
            Text("Import images, TXT, RTF, Word, and OpenDocument text. Word files are reflowed onto PDF pages; check their layout. Export Excel or PowerPoint files to PDF in their original app first.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Import file…", systemImage: "square.and.arrow.down", action: model.importForConversion)
        }
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Export this document").font(.headline)
            Picker("Format", selection: $format) {
                ForEach(PDFConversionFormat.allCases.filter { $0 != .pdf }) { item in Text(item.title).tag(item) }
            }
            if format.isImage {
                Picker("Resolution", selection: $scale) {
                    Text("72 pixels/inch").tag(1.0)
                    Text("144 pixels/inch").tag(2.0)
                    Text("216 pixels/inch").tag(3.0)
                }
            }
            Text(format.detail).font(.caption).foregroundStyle(.secondary)
            Button(format.isImage ? "Export page images…" : "Export document…", systemImage: "square.and.arrow.up") {
                model.exportConverted(format: format, scale: scale)
            }
            .disabled(format.isImage ? !model.canRenderContent : !model.canExtractContent)
        }
    }

    private var compressionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compress PDF").font(.headline)
            Picker("Quality", selection: $compression) {
                ForEach(PDFCompressionLevel.allCases) { item in Text(item.title).tag(item) }
            }
            Text(compression.detail + " Text, forms, and annotations remain available. File size is measured; a smaller result is not guaranteed.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Prepare compressed copy…", systemImage: "arrow.down.right.and.arrow.up.left") {
                model.compressCurrentDocument(level: compression) { compressionResult = $0 }
            }
            .disabled(!model.canCompressContent)
            if !compressionResult.isEmpty { Text(compressionResult).font(.caption).textSelection(.enabled) }
        }
    }

    private var recognitionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recognize text (OCR)").font(.headline)
            Picker("Language", selection: $language) {
                Text("Detect automatically").tag("")
                Text("English").tag("en-US")
                Text("French").tag("fr-FR")
                Text("German").tag("de-DE")
                Text("Spanish").tag("es-ES")
                Text("Italian").tag("it-IT")
                Text("Portuguese").tag("pt-BR")
                Text("Chinese (Simplified)").tag("zh-Hans")
                Text("Chinese (Traditional)").tag("zh-Hant")
                Text("Japanese").tag("ja-JP")
                Text("Korean").tag("ko-KR")
            }
            Toggle("Recognize pages that already contain text", isOn: $recognizeEveryPage)
            Text(recognizeEveryPage
                 ? "Recognizes every page from a 144 ppi image, replacing its text layer. This reduces vector quality."
                 : "Recognizes scanned pages throughout the document. Pages with selectable text retain their existing text and vector artwork.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Runs on this Mac. The searchable copy preserves visible page layout; forms and annotations become permanent page content. Review recognized words for errors.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Make searchable copy", systemImage: "text.viewfinder") {
                model.recognizeCurrentDocument(options: ocrOptions, exportText: false) { recognitionResult = $0 }
            }
            .disabled(!model.canRenderContent)
            Button("Export recognized text…", systemImage: "text.alignleft") {
                model.recognizeCurrentDocument(options: ocrOptions, exportText: true) { recognitionResult = $0 }
            }
            .disabled(!model.canRenderContent)
            if !recognitionResult.isEmpty { Text(recognitionResult).font(.caption).textSelection(.enabled) }
        }
    }

    private var batchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Batch processing").font(.headline)
            Picker("Operation", selection: $batchMode) {
                ForEach(ConversionBatchMode.allCases) { item in Text(item.rawValue).tag(item) }
            }
            Text(batchDescription).font(.caption).foregroundStyle(.secondary)
            Button("Choose files and output folder…", systemImage: "doc.on.doc") {
                let operation: PDFConversionBatchOperation = switch batchMode {
                case .convert: .convert(format, scale: scale)
                case .createPDF: .convert(.pdf)
                case .compress: .compress(compression)
                case .ocr: .ocr(ocrOptions)
                }
                model.beginConversionBatch(operation: operation) { batchResults = $0 }
            }
            Text("Each file has its own result. Existing files are never replaced.")
                .font(.caption).foregroundStyle(.secondary)
            ConversionResultsView(results: batchResults)
        }
    }

    private var batchDescription: String {
        switch batchMode {
        case .convert: "Convert to \(format.title) using the export settings above."
        case .createPDF: "Create a PDF for each supported input document or image."
        case .compress: "Compress using \(compression.title.lowercased())."
        case .ocr: "Create searchable PDFs using the recognition settings above."
        }
    }
}
