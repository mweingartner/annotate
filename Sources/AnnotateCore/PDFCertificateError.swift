import Foundation
import Security

public enum PDFCertificateError: Error, LocalizedError {
    case permission, encrypted, alreadySigned, invalidPDF, malformedSignature, unsupportedSignature, signatureTooLarge, tooLarge
    case security(OSStatus)
    case verificationFailed(String)
    case reasonTooLong
    case invalidByteRange, invalidContents, invalidEnvelope
    public var errorDescription: String? {
        switch self {
        case .permission: "This PDF does not permit creating a signed copy."
        case .encrypted: "Certificate signing requires an unencrypted working PDF. Encryption is never removed automatically."
        case .alreadySigned: "This PDF already contains a certificate signature. Annotate will not rewrite it and invalidate that signature."
        case .invalidPDF: "This file is not a readable PDF."
        case .malformedSignature: "The signature has an invalid byte range, contents value, or certificate envelope."
        case .unsupportedSignature: "This signature format is not supported. Annotate validates detached PKCS#7 signatures."
        case .signatureTooLarge: "The certificate chain exceeds the reserved signature space. No signed file was created."
        case .tooLarge: "Certificate signing and validation support PDFs up to 256 MB."
        case .reasonTooLong: "The signing reason must be at most 2,000 UTF-8 bytes."
        case .invalidByteRange: "The signature byte ranges are malformed or outside the file."
        case .invalidContents: "The excluded byte range does not match the signature contents."
        case .invalidEnvelope: "The certificate signature does not contain a valid DER envelope."
        case .verificationFailed(let detail): "The signed copy did not pass verification and was not saved. \(detail)"
        case .security(let status): "Security operation failed: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))."
        }
    }
    static func check(_ status: OSStatus) throws { if status != errSecSuccess { throw Self.security(status) } }
}
