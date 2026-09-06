import Foundation
import PDFKit

public enum PDFConversionBatchOperation: Sendable {
    case convert(PDFConversionFormat, scale: Double = 2)
    case compress(PDFCompressionLevel)
    case ocr(PDFOCROptions)
}

public struct PDFConversionBatchResult: Identifiable, Sendable {
    public var id: URL { input }
    public let input: URL
    public let output: URL?
    public let message: String
    public var succeeded: Bool { output != nil }
}

@MainActor
public enum PDFConversionBatch {
    public static func run(inputs: [URL], outputDirectory: URL, operation: PDFConversionBatchOperation,
                           progress: ((_ completed: Int, _ total: Int, _ filename: String) -> Void)? = nil) async -> [PDFConversionBatchResult] {
        var results: [PDFConversionBatchResult] = []
        for (index, input) in inputs.enumerated() {
            if Task.isCancelled { break }
            progress?(index, inputs.count, input.lastPathComponent)
            do {
                let document = try PDFConversion.importDocument(from: input)
                let name = input.deletingPathExtension().lastPathComponent
                let output: URL
                var message: String
                switch operation {
                case .convert(let format, let scale):
                    output = try await export(document: document, format: format, name: name, to: outputDirectory, scale: scale)
                    message = format.isImage ? "Exported \(document.pageCount) page images." : "Converted to \(format.title)."
                case .compress(let level):
                    let sourceSize = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize
                    let result = try PDFConversion.compressedData(document: document, level: level, originalBytes: input.pathExtension.lowercased() == "pdf" ? sourceSize : nil)
                    output = try write(result.data, name: name + "-compressed.pdf", to: outputDirectory)
                    message = result.sizeDescription
                case .ocr(let options):
                    let result = try await PDFOCR.recognize(document: document, options: options)
                    output = try write(result.data, name: name + "-searchable.pdf", to: outputDirectory)
                    message = "Recognized \(result.recognizedLineCount) lines across \(result.recognizedPageCount) pages; retained \(result.retainedTextPageCount) text pages."
                }
                results.append(PDFConversionBatchResult(input: input, output: output, message: message))
            } catch {
                results.append(PDFConversionBatchResult(input: input, output: nil, message: error.localizedDescription))
            }
            progress?(index + 1, inputs.count, input.lastPathComponent)
            await Task.yield()
        }
        return results
    }

    public static func export(document sourceDocument: PDFDocument, format: PDFConversionFormat, name: String, to directory: URL,
                              scale: Double = 2, progress: ((_ completed: Int, _ total: Int) -> Void)? = nil) async throws -> URL {
        try Task.checkCancellation()
        let document = try PDFConversion.snapshot(document: sourceDocument, needsPrinting: format.isImage)
        guard format.isImage else {
            return try write(PDFConversion.exportData(document: document, format: format), name: name + "." + format.fileExtension, to: directory)
        }
        try validateDirectory(directory)
        let staging = directory.appending(path: ".annotate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw AnnotateError.invalidPage(index) }
            let data = try PDFConversion.imageData(page: page, format: format, scale: scale)
            let padded = String(repeating: "0", count: max(0, max(4, String(document.pageCount).count) - String(index + 1).count)) + String(index + 1)
            try data.write(to: staging.appending(path: "Page-\(padded).\(format.fileExtension)"), options: .withoutOverwriting)
            progress?(index + 1, document.pageCount)
            await Task.yield()
        }
        try Task.checkCancellation()
        return try moveWithoutReplacing(staging, name: name + "-" + format.rawValue, to: directory)
    }

    /// Stages each result and uses a filesystem move that refuses to replace an existing item.
    /// A collision selects the next numbered name, including races with another writer.
    public static func write(_ data: Data, name: String, to directory: URL) throws -> URL {
        try validateDirectory(directory)
        let staging = directory.appending(path: ".annotate-\(UUID().uuidString)")
        try data.write(to: staging, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: staging) }
        return try moveWithoutReplacing(staging, name: name, to: directory)
    }

    private static func validateDirectory(_ directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true, FileManager.default.isWritableFile(atPath: directory.path) else {
            throw PDFConversionError.outputDirectory
        }
    }

    private static func moveWithoutReplacing(_ staging: URL, name: String, to directory: URL) throws -> URL {
        let safeName = name.replacing("/", with: "-").replacing(":", with: "-")
        let ext = (safeName as NSString).pathExtension
        let stem = (safeName as NSString).deletingPathExtension
        for number in 1...10_000 {
            let filename = number == 1 ? safeName : stem + "-\(number)" + (ext.isEmpty ? "" : "." + ext)
            let destination = directory.appending(path: filename)
            do {
                try FileManager.default.moveItem(at: staging, to: destination)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw PDFConversionError.failed
    }
}
