import Foundation

public struct PDFCertificateValidation: Identifiable, Sendable {
    public enum Integrity: Sendable { case intact, invalid, unsupported }
    public enum Trust: Sendable { case trusted, untrusted, notEvaluated }
    public let id = UUID()
    public let fieldName: String
    public let signerName: String
    public let integrity: Integrity
    public let trust: Trust
    public let coversWholeFile: Bool
    public let detail: String

    public var status: String {
        if integrity == .unsupported { return "Unsupported signature" }
        if integrity == .invalid { return "Signature invalid" }
        if !coversWholeFile { return "Document changed after signing" }
        return trust == .trusted ? "Signature intact · trusted certificate" : "Signature intact · certificate not trusted"
    }
}
