import Foundation

enum WorkspaceTool: String, CaseIterable, Identifiable {
    case edit, pages, forms, sign, convert, redact, assistant
    var id: String { rawValue }
    var title: String {
        switch self {
        case .edit: "Edit"
        case .pages: "Pages"
        case .forms: "Forms"
        case .sign: "Sign"
        case .convert: "Convert & OCR"
        case .redact: "Redact"
        case .assistant: "Assistant"
        }
    }
    var symbol: String {
        switch self {
        case .edit: "pencil.and.outline"
        case .pages: "square.grid.2x2"
        case .forms: "list.bullet.rectangle"
        case .sign: "signature"
        case .convert: "arrow.triangle.2.circlepath"
        case .redact: "rectangle.fill"
        case .assistant: "sparkles"
        }
    }
    var help: String {
        switch self {
        case .edit: "Select PDF text to edit its words and formatting, or insert new text and images"
        case .pages: "Reorder, insert, rotate, extract, or remove pages"
        case .forms: "Fill existing fields or add interactive form fields"
        case .sign: "Place a typed, drawn, or imported electronic signature"
        case .convert: "Export a copy, compress a PDF, or recognize scanned text"
        case .redact: "Remove selected content from a separate sanitized copy"
        case .assistant: "Ask questions and inspect the PDF passages behind each answer"
        }
    }
}
