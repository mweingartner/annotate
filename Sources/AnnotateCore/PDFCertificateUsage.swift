import Foundation

/// What a certificate says it was issued for, from its key usage and extended key
/// usage extensions, and the rule for when that covers signing documents.
///
/// A chain that ends at a trusted root proves who issued the certificate, not what
/// for: a web server's TLS certificate also chains to a trusted root. A signer
/// certificate counts as trusted for signing documents only when its usage allows it.
struct PDFCertificateUsage: Equatable, Sendable {
    /// Key usage bits, numbered as in RFC 5280 section 4.2.1.3.
    struct KeyUsage: OptionSet, Equatable, Sendable {
        let rawValue: UInt16
        static let digitalSignature = KeyUsage(rawValue: 1 << 0)
        /// Renamed contentCommitment in later X.509 editions; the bit is the same.
        static let nonRepudiation = KeyUsage(rawValue: 1 << 1)
        static let keyEncipherment = KeyUsage(rawValue: 1 << 2)
        static let dataEncipherment = KeyUsage(rawValue: 1 << 3)
        static let keyAgreement = KeyUsage(rawValue: 1 << 4)
        static let keyCertSign = KeyUsage(rawValue: 1 << 5)
        static let cRLSign = KeyUsage(rawValue: 1 << 6)
        static let encipherOnly = KeyUsage(rawValue: 1 << 7)
        static let decipherOnly = KeyUsage(rawValue: 1 << 8)
    }

    /// Whether the usage covers signing documents, and if not, which extension refuses it.
    enum Verdict: Equatable, Sendable {
        case permitted
        /// The extended key usage lists only purposes other than signing documents.
        case purposeExcludesDocuments
        /// The key usage allows neither digital signatures nor non-repudiation.
        case keyUsageExcludesSignatures
    }

    /// Extended key usage purposes that cover signing documents, as dotted OIDs.
    static let documentSigningPurposes: Set<String> = [
        "1.3.6.1.5.5.7.3.36",       // id-kp-documentSigning, RFC 9336
        "1.3.6.1.5.5.7.3.4",        // id-kp-emailProtection, used by most S/MIME and PDF signing certificates
        "1.3.6.1.4.1.311.10.3.12",  // Microsoft document signing
        "1.2.840.113583.1.1.5",     // Adobe Authentic Documents Trust
        "2.5.29.37.0"               // anyExtendedKeyUsage
    ]

    /// Extended key usage purposes as dotted OIDs, or nil when the extension is absent.
    var extendedKeyUsage: [String]?
    /// Key usage bits, or nil when the extension is absent.
    var keyUsage: KeyUsage?

    /// RFC 5280: an absent extension leaves the key unrestricted; a present one must
    /// name a document signing purpose and allow a digital signature or non-repudiation.
    var verdict: Verdict {
        if let extendedKeyUsage, Self.documentSigningPurposes.isDisjoint(with: extendedKeyUsage) {
            return .purposeExcludesDocuments
        }
        if let keyUsage, keyUsage.isDisjoint(with: [.digitalSignature, .nonRepudiation]) {
            return .keyUsageExcludesSignatures
        }
        return .permitted
    }

    var permitsSigningDocuments: Bool { verdict == .permitted }
}
