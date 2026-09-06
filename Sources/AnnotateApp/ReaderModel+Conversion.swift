import AnnotateCore
import AppKit
import PDFKit
import UniformTypeIdentifiers

extension ReaderModel {
    var conversionBaseName: String { (fileName as NSString).deletingPathExtension }
    var canExtractContent: Bool { pdfDocument.map { !$0.isLocked && $0.allowsCopying } ?? false }
    var canRenderContent: Bool { canExtractContent && (pdfDocument?.allowsPrinting ?? false) }
    var canCompressContent: Bool { canRenderContent && (pdfDocument?.allowsDocumentChanges ?? false) }

    func importForConversion() {
        let panel = conversionInputPanel(multiple: false)
        showConversionPanel(panel) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.performOperation("Importing \(url.lastPathComponent)") { [weak self] in
                let document = try PDFConversion.importDocument(from: url)
                self?.openCreatedPDF(document, name: url.deletingPathExtension().lastPathComponent + ".pdf")
            }
        }
    }

    func exportConverted(format: PDFConversionFormat, scale: Double) {
        if hasDraftChanges { saveDraft() }
        guard !hasDraftChanges, let document = pdfDocument else { return }
        if format.isImage {
            chooseConversionDirectory { [weak self] directory in
                guard let self else { return }
                self.performOperation("Exporting page images") { [weak self] in
                    guard let self else { return }
                    let output = try await PDFConversionBatch.export(document: document, format: format, name: self.conversionBaseName,
                                                                     to: directory, scale: scale) { [weak self] done, total in
                        self?.operationProgress = "Exporting images · \(done) of \(total) pages"
                    }
                    self.statusMessage = "Exported \(document.pageCount) page images"
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
            }
        } else {
            performOperation("Converting document") { [weak self] in
                guard let self else { return }
                let data = try PDFConversion.exportData(document: document, format: format)
                self.saveOutput(data: data, suggestedName: self.conversionBaseName + "." + format.fileExtension, contentType: format.contentType)
            }
        }
    }

    func compressCurrentDocument(level: PDFCompressionLevel, report: @escaping (String) -> Void) {
        if hasDraftChanges { saveDraft() }
        guard !hasDraftChanges, let document = pdfDocument else { return }
        performOperation("Preparing compressed PDF") { [weak self] in
            guard let self else { return }
            // The current in-memory serialization is the baseline, including unsaved edits.
            let result = try PDFConversion.compressedData(document: document, level: level)
            report(result.sizeDescription)
            self.saveOutput(data: result.data, suggestedName: self.conversionBaseName + "-compressed.pdf", contentType: .pdf)
        }
    }

    func recognizeCurrentDocument(options: PDFOCROptions, exportText: Bool, report: @escaping (String) -> Void) {
        if hasDraftChanges { saveDraft() }
        guard !hasDraftChanges, let document = pdfDocument else { return }
        performOperation("Recognizing document text") { [weak self] in
            guard let self else { return }
            let result = try await PDFOCR.recognize(document: document, options: options) { [weak self] page, total in
                self?.operationProgress = "Recognizing text · \(page) of \(total) pages"
            }
            let summary = "Recognized \(result.recognizedLineCount) lines on \(result.recognizedPageCount) pages. Retained existing text on \(result.retainedTextPageCount) pages."
            report(summary)
            if exportText {
                guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PDFConversionError.noText }
                self.saveOutput(data: Data(result.text.utf8), suggestedName: self.conversionBaseName + "-recognized.txt", contentType: .plainText)
            } else {
                guard let searchable = PDFDocument(data: result.data) else { throw PDFConversionError.failed }
                self.openCreatedPDF(searchable, name: self.conversionBaseName + "-searchable.pdf")
                self.statusMessage = summary
            }
        }
    }

    func beginConversionBatch(operation: PDFConversionBatchOperation, report: @escaping ([PDFConversionBatchResult]) -> Void) {
        let panel = conversionInputPanel(multiple: true)
        showConversionPanel(panel) { [weak self] response in
            guard response == .OK, let self, !panel.urls.isEmpty else { return }
            let inputs = panel.urls
            self.chooseConversionDirectory { [weak self] directory in
                guard let self else { return }
                self.performOperation("Starting batch") { [weak self] in
                    let results = await PDFConversionBatch.run(inputs: inputs, outputDirectory: directory, operation: operation) { [weak self] done, total, name in
                        self?.operationProgress = "\(done) of \(total) · \(name)"
                    }
                    report(results)
                    try Task.checkCancellation()
                    self?.statusMessage = "Batch finished: \(results.count(where: \.succeeded)) of \(results.count) files succeeded"
                }
            }
        }
    }

    private func conversionInputPanel(multiple: Bool) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple
        panel.allowedContentTypes = PDFConversion.importExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose PDFs, images, TXT, RTF, RTFD, Word, or OpenDocument text files. Office documents are reflowed; check layout after import."
        return panel
    }

    private func chooseConversionDirectory(_ completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose Output Folder"
        panel.message = "Results receive unique filenames. Existing files are never replaced."
        showConversionPanel(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
    }

    private func showConversionPanel(_ panel: NSOpenPanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = owner?.windowForSheet { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(panel.runModal()) }
    }
}
