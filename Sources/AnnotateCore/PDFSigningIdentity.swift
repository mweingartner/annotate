import Foundation
import Security

@MainActor
public struct PDFSigningIdentity: Identifiable {
    public let id = UUID()
    public let name: String
    public let fingerprint: String
    public let identity: SecIdentity

    public init(identity: SecIdentity) throws {
        var certificate: SecCertificate?
        try PDFCertificateError.check(SecIdentityCopyCertificate(identity, &certificate))
        guard let certificate else { throw PDFCertificateError.security(errSecItemNotFound) }
        self.identity = identity
        name = SecCertificateCopySubjectSummary(certificate) as String? ?? "Unnamed signing certificate"
        fingerprint = PDFCertificateX509.fingerprint(certificate)
    }

    /// Only enumerate after the user opens identity setup. Listing does not sign
    /// anything or read/export private key material.
    public static func available() throws -> [PDFSigningIdentity] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassIdentity, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll] as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try PDFCertificateError.check(status)
        guard let values = result as? [SecIdentity] else { return [] }
        return try values.map { try PDFSigningIdentity(identity: $0) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
