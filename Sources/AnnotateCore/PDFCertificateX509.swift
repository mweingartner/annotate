import CryptoKit
import Foundation
import Security

/// Reads the few X.509 fields validation reports beyond what Security exposes: the
/// issuer's name and the key usage extensions. The certificate comes from an
/// untrusted PDF, so every structure is bounded and anything unexpected throws.
enum PDFCertificateX509 {
    struct Contents: Equatable, Sendable {
        /// The issuer's common name and organization, as claimed; nil when it names neither.
        let issuer: String?
        let usage: PDFCertificateUsage
    }

    /// Large enough for any real certificate chain member; bounds work on hostile input.
    private static let maximumCertificateBytes = 131_072
    /// RFC 5280 extensions: key usage 2.5.29.15 and extended key usage 2.5.29.37.
    private static let keyUsageOID: [UInt8] = [0x55, 0x1D, 0x0F]
    private static let extendedKeyUsageOID: [UInt8] = [0x55, 0x1D, 0x25]
    /// X.520 name attributes: common name 2.5.4.3, organization 2.5.4.10.
    private static let commonNameOID: [UInt8] = [0x55, 0x04, 0x03]
    private static let organizationOID: [UInt8] = [0x55, 0x04, 0x0A]

    /// The SHA-256 fingerprint of the certificate's DER bytes, as colon-separated hex pairs.
    static func fingerprint(_ certificate: SecCertificate) -> String {
        SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func read(_ data: Data) throws -> Contents {
        guard !data.isEmpty, data.count <= maximumCertificateBytes else { throw PDFCertificateError.invalidEnvelope }
        let bytes = [UInt8](data)
        func elements(_ range: Range<Int>, maximumCount: Int = 64) throws -> [PDFCertificateDER.Element] {
            try PDFCertificateDER.elements(bytes, in: range, maximumCount: maximumCount)
        }
        let root = try elements(0..<bytes.count, maximumCount: 1)
        guard root.count == 1, root[0].tag == 0x30 else { throw PDFCertificateError.invalidEnvelope }
        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
        let certificate = try elements(root[0].body, maximumCount: 3)
        guard certificate.count == 3, certificate[0].tag == 0x30 else { throw PDFCertificateError.invalidEnvelope }
        // TBSCertificate: optional [0] version, serial, signature, issuer, validity, subject,
        // subject key, then optional [1] and [2] unique IDs and [3] extensions.
        let fields = try elements(certificate[0].body, maximumCount: 10)
        let first = fields.first?.tag == 0xA0 ? 1 : 0
        guard fields.count >= first + 6, fields[first].tag == 0x02,
              fields[(first + 1)...(first + 5)].allSatisfy({ $0.tag == 0x30 }) else { throw PDFCertificateError.invalidEnvelope }
        let issuer = try name(bytes, fields[first + 2].body)
        var usage = PDFCertificateUsage()
        let optional = fields[(first + 6)...]
        guard optional.allSatisfy({ [0x81, 0xA1, 0x82, 0xA2, 0xA3].contains($0.tag) }),
              optional.filter({ $0.tag == 0xA3 }).count <= 1 else { throw PDFCertificateError.invalidEnvelope }
        if let wrapper = optional.first(where: { $0.tag == 0xA3 }) {
            let sequence = try elements(wrapper.body, maximumCount: 1)
            guard sequence.count == 1, sequence[0].tag == 0x30 else { throw PDFCertificateError.invalidEnvelope }
            var seen: Set<[UInt8]> = []
            for extensionValue in try elements(sequence[0].body) {
                // Extension ::= SEQUENCE { extnID, critical BOOLEAN DEFAULT FALSE, extnValue OCTET STRING }
                guard extensionValue.tag == 0x30 else { throw PDFCertificateError.invalidEnvelope }
                let parts = try elements(extensionValue.body, maximumCount: 3)
                guard (2...3).contains(parts.count), parts[0].tag == 0x06, parts.last?.tag == 0x04,
                      parts.count == 2 || parts[1].tag == 0x01, let value = parts.last else { throw PDFCertificateError.invalidEnvelope }
                let identifier = Array(bytes[parts[0].body])
                // RFC 5280 forbids repeating an extension; two answers to one question fail closed.
                guard seen.insert(identifier).inserted else { throw PDFCertificateError.invalidEnvelope }
                if identifier == keyUsageOID { usage.keyUsage = try keyUsage(bytes, value.body) }
                if identifier == extendedKeyUsageOID { usage.extendedKeyUsage = try purposes(bytes, value.body) }
            }
        }
        return Contents(issuer: issuer, usage: usage)
    }

    /// KeyUsage ::= BIT STRING, bit 0 (digitalSignature) in the high bit of the first byte.
    private static func keyUsage(_ bytes: [UInt8], _ range: Range<Int>) throws -> PDFCertificateUsage.KeyUsage {
        let value = try PDFCertificateDER.elements(bytes, in: range, maximumCount: 1)
        guard value.count == 1, value[0].tag == 0x03, !value[0].body.isEmpty,
              bytes[value[0].body.lowerBound] < 8 else { throw PDFCertificateError.invalidEnvelope }
        // Nine bits are defined, so only the first two content bytes after the unused-bit count matter.
        var raw: UInt16 = 0
        for (index, byte) in bytes[value[0].body].dropFirst().prefix(2).enumerated() {
            for bit in 0..<8 where byte & (0x80 >> bit) != 0 { raw |= 1 << UInt16(index * 8 + bit) }
        }
        return PDFCertificateUsage.KeyUsage(rawValue: raw)
    }

    /// ExtKeyUsageSyntax ::= SEQUENCE SIZE (1..MAX) OF KeyPurposeId
    private static func purposes(_ bytes: [UInt8], _ range: Range<Int>) throws -> [String] {
        let value = try PDFCertificateDER.elements(bytes, in: range, maximumCount: 1)
        guard value.count == 1, value[0].tag == 0x30 else { throw PDFCertificateError.invalidEnvelope }
        let identifiers = try PDFCertificateDER.elements(bytes, in: value[0].body)
        guard !identifiers.isEmpty, identifiers.allSatisfy({ $0.tag == 0x06 }) else { throw PDFCertificateError.invalidEnvelope }
        return try identifiers.map { try dottedOID(Array(bytes[$0.body])) }
    }

    /// Decodes an OBJECT IDENTIFIER's content bytes to dotted form, such as 1.3.6.1.5.5.7.3.4.
    static func dottedOID(_ content: [UInt8]) throws -> String {
        guard let last = content.last, last & 0x80 == 0 else { throw PDFCertificateError.invalidEnvelope }
        var arcs: [UInt64] = [], arc: UInt64 = 0, started = false
        for byte in content {
            // A leading 0x80 pads an arc non-minimally; DER forbids it.
            guard started || byte != 0x80 else { throw PDFCertificateError.invalidEnvelope }
            // Seven bits per byte: stop before an arc can overflow 64 bits.
            guard arc >> 57 == 0 else { throw PDFCertificateError.invalidEnvelope }
            arc = arc << 7 | UInt64(byte & 0x7F)
            started = byte & 0x80 != 0
            if !started { arcs.append(arc); arc = 0 }
        }
        // The first encoded arc combines the first two: 40 × first + second, first at most 2.
        let head = arcs[0] < 80 ? [arcs[0] / 40, arcs[0] % 40] : [2, arcs[0] - 80]
        return (head + arcs.dropFirst()).map(String.init).joined(separator: ".")
    }

    /// Name ::= SEQUENCE OF SET OF { type, value }: the common name and organization, as claimed.
    private static func name(_ bytes: [UInt8], _ range: Range<Int>) throws -> String? {
        var commonName: String?, organization: String?
        for set in try PDFCertificateDER.elements(bytes, in: range) {
            guard set.tag == 0x31 else { throw PDFCertificateError.invalidEnvelope }
            for attribute in try PDFCertificateDER.elements(bytes, in: set.body, maximumCount: 16) {
                guard attribute.tag == 0x30 else { throw PDFCertificateError.invalidEnvelope }
                let parts = try PDFCertificateDER.elements(bytes, in: attribute.body, maximumCount: 2)
                guard parts.count == 2, parts[0].tag == 0x06 else { throw PDFCertificateError.invalidEnvelope }
                let type = Array(bytes[parts[0].body])
                if type == commonNameOID, commonName == nil { commonName = string(bytes, parts[1]) }
                if type == organizationOID, organization == nil { organization = string(bytes, parts[1]) }
            }
        }
        let names = [commonName, organization].compactMap { $0 }.filter { !$0.isEmpty }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// The directory string types X.520 names use; anything else is not shown.
    private static func string(_ bytes: [UInt8], _ element: PDFCertificateDER.Element) -> String? {
        let content = Data(bytes[element.body])
        switch element.tag {
        case 0x0C: return String(data: content, encoding: .utf8)              // UTF8String
        case 0x13, 0x16: return String(data: content, encoding: .ascii)       // PrintableString, IA5String
        case 0x14: return String(data: content, encoding: .isoLatin1)         // TeletexString, read as Latin-1
        case 0x1E: return String(data: content, encoding: .utf16BigEndian)    // BMPString
        case 0x1C: return String(data: content, encoding: .utf32BigEndian)    // UniversalString
        default: return nil
        }
    }
}
