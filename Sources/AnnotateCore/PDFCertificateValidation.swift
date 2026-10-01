import Foundation

public struct PDFCertificateValidation: Identifiable, Sendable {
    public enum Integrity: Sendable { case intact, invalid, unsupported }
    public enum Trust: Sendable {
        /// The chain ends at a root this Mac trusts and the certificate was issued for signing documents.
        case trusted
        /// The chain ends at a root this Mac trusts, but the certificate wasn't issued for
        /// signing documents: a web server's certificate, for example.
        case notIssuedForSigning
        case untrusted, notEvaluated
    }
    /// A certificate that signed, as it describes itself. Every name is claimed by the
    /// certificate, so it is untrusted text; the fingerprint identifies it exactly.
    public struct SignerCertificate: Sendable, Equatable {
        public let subject: String
        public let issuer: String
        /// SHA-256 of the certificate's DER bytes, as colon-separated hex pairs.
        public let fingerprint: String
    }
    public let id = UUID()
    public let fieldName: String
    public let signerName: String
    public let integrity: Integrity
    public let trust: Trust
    public let coversWholeFile: Bool
    public let detail: String
    /// Empty when the signature could not be verified far enough to identify its signers.
    public let signerCertificates: [SignerCertificate]

    public var status: String {
        if integrity == .unsupported { return "Unsupported signature" }
        if integrity == .invalid { return "Signature invalid" }
        if !coversWholeFile { return "Document changed after signing" }
        switch trust {
        case .trusted: return "Signature intact · trusted certificate"
        case .notIssuedForSigning: return "Signature intact · certificate not issued for signing documents"
        case .untrusted, .notEvaluated: return "Signature intact · certificate not trusted"
        }
    }
}
