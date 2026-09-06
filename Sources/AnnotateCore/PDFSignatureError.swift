import Foundation

public enum PDFSignatureError: LocalizedError {
    case emptySignature, invalidImage
    public var errorDescription: String? {
        switch self {
        case .emptySignature: "Type a signature of 1–200 characters or draw at least one stroke."
        case .invalidImage: "Choose a readable signature image."
        }
    }
}
