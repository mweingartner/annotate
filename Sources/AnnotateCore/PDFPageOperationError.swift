import Foundation

public enum PDFPageOperationError: LocalizedError {
    case noSelection, invalidOrder, lastPage, invalidDimensions, invalidImage, assemblyRestricted, sourceRestricted
    public var errorDescription: String? {
        switch self {
        case .noSelection: "Select at least one page."
        case .invalidOrder: "Enter valid page numbers within this PDF."
        case .lastPage: "Keep at least one page in the PDF."
        case .invalidDimensions: "Page dimensions must be between 36 and 14,400 points."
        case .invalidImage: "The selected image could not be read."
        case .assemblyRestricted: "This PDF does not permit inserting, deleting, rotating, or rearranging pages."
        case .sourceRestricted: "The source PDF must be unlocked and allow copying and page assembly."
        }
    }
}
