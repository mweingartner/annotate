import Foundation
import UniformTypeIdentifiers

public enum PDFConversionFormat: String, CaseIterable, Identifiable, Sendable {
    case pdf, docx, doc, odt, rtf, text, html, xlsx, pptx, png, jpeg, tiff, heic

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .pdf: "PDF"
        case .docx: "Word document (.docx)"
        case .doc: "Word 97–2004 (.doc)"
        case .odt: "OpenDocument text (.odt)"
        case .rtf: "Rich text (.rtf)"
        case .text: "Plain text (.txt)"
        case .html: "Web page (.html)"
        case .xlsx: "Excel text cells (.xlsx)"
        case .pptx: "PowerPoint page images (.pptx)"
        case .png: "PNG images"
        case .jpeg: "JPEG images"
        case .tiff: "TIFF images"
        case .heic: "HEIC images"
        }
    }
    public var fileExtension: String {
        switch self {
        case .text: "txt"
        case .jpeg: "jpg"
        default: rawValue
        }
    }
    public var isImage: Bool { [.png, .jpeg, .tiff, .heic].contains(self) }
    public var contentType: UTType { UTType(filenameExtension: fileExtension) ?? .data }
    public var detail: String {
        if self == .xlsx { return "Creates one worksheet per PDF page. Lines become rows; tabs and repeated spaces separate text cells. Tables, formulas, numeric types, and charts are not reconstructed. Run OCR first for scanned pages. " + PDFPageText.orderingDescription }
        if self == .pptx { return "Creates one slide per PDF page, including visible annotations, as a 144 ppi image. Pages fit without distortion; text and images within each page are not separate editable slide objects." }
        if isImage { return "Exports every visible page as a separate image, including annotations." }
        if self == .pdf { return "Creates a PDF from supported documents or images." }
        return "Exports selectable text with available styling; page layouts, images, and tables are not reconstructed. Run OCR first for scanned pages. " + PDFPageText.orderingDescription
    }
}

public enum PDFCompressionLevel: String, CaseIterable, Identifiable, Sendable {
    case lossless, balanced, compact
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .lossless: "Original quality"
        case .balanced: "Balanced · JPEG images"
        case .compact: "Compact · screen images"
        }
    }
    public var detail: String {
        switch self {
        case .lossless: "Rewrites the PDF without requesting lossy image changes."
        case .balanced: "Uses JPEG encoding for images. Fine image detail may change."
        case .compact: "Uses JPEG and screen-optimized images. Best for reading on screen."
        }
    }
}

public struct PDFCompressionResult: Sendable {
    public let data: Data
    public let originalBytes: Int
    public var outputBytes: Int { data.count }
    public var savedBytes: Int { originalBytes - outputBytes }
    public var sizeDescription: String {
        let before = ByteCountFormatter.string(fromByteCount: Int64(originalBytes), countStyle: .file)
        let after = ByteCountFormatter.string(fromByteCount: Int64(outputBytes), countStyle: .file)
        if savedBytes > 0 {
            let percent = Double(savedBytes) / Double(max(originalBytes, 1))
            return "\(before) → \(after) (\(percent.formatted(.percent.precision(.fractionLength(1)))) smaller)"
        }
        return "\(before) → \(after). This PDF did not become smaller."
    }
}

public enum PDFConversionError: LocalizedError {
    case noText, unsupportedInput(String), invalidImage, invalidPage, failed, outputDirectory, inputTooLarge, permissionDenied
    public var errorDescription: String? {
        switch self {
        case .noText: "No selectable text was found. Use Recognize text (OCR) for scanned pages, then export the searchable PDF."
        case .unsupportedInput(let name): "\(name) cannot be imported. Supported inputs: PDF, images, TXT, RTF, RTFD, DOC, DOCX, and ODT. Excel and PowerPoint files need to be exported to PDF in their originating app first."
        case .invalidImage: "The image could not be decoded or encoded by macOS."
        case .invalidPage: "A page has invalid dimensions or is too large to render safely."
        case .failed: "macOS could not complete this conversion. The original document has not been changed."
        case .outputDirectory: "Choose a writable output folder."
        case .inputTooLarge: "This input exceeds the 512 MB conversion limit. Split it into smaller documents first."
        case .permissionDenied: "The PDF's security permissions do not allow this conversion. Owner authorization is required."
        }
    }
}
