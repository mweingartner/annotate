import Foundation
import Testing
@testable import AnnotateCore

@Suite("Certificate usage for signing documents")
struct CertificateUsageTests {
    typealias Usage = PDFCertificateUsage

    @Test("The usage rule: absent extensions are unrestricted; present ones must allow signing documents", arguments: [
        (Usage(), Usage.Verdict.permitted),
        (Usage(extendedKeyUsage: ["1.3.6.1.5.5.7.3.36"]), .permitted),
        (Usage(extendedKeyUsage: ["1.3.6.1.5.5.7.3.4"]), .permitted),
        (Usage(extendedKeyUsage: ["1.3.6.1.4.1.311.10.3.12"]), .permitted),
        (Usage(extendedKeyUsage: ["1.2.840.113583.1.1.5"]), .permitted),
        (Usage(extendedKeyUsage: ["2.5.29.37.0"]), .permitted),
        (Usage(extendedKeyUsage: ["1.3.6.1.5.5.7.3.1", "1.3.6.1.5.5.7.3.4"]), .permitted),
        (Usage(extendedKeyUsage: ["1.3.6.1.5.5.7.3.1"]), .purposeExcludesDocuments),
        (Usage(extendedKeyUsage: ["1.3.6.1.5.5.7.3.1", "1.3.6.1.5.5.7.3.2", "1.3.6.1.5.5.7.3.3"]), .purposeExcludesDocuments),
        // A near miss on an accepted OID is a different purpose.
        (Usage(extendedKeyUsage: ["1.3.6.1.5.5.7.3.40", "1.3.6.1.5.5.7.3.4.1"]), .purposeExcludesDocuments),
        (Usage(extendedKeyUsage: []), .purposeExcludesDocuments),
        (Usage(keyUsage: .digitalSignature), .permitted),
        (Usage(keyUsage: .nonRepudiation), .permitted),
        (Usage(keyUsage: [.keyEncipherment, .digitalSignature]), .permitted),
        (Usage(keyUsage: .keyEncipherment), .keyUsageExcludesSignatures),
        (Usage(keyUsage: [.keyCertSign, .cRLSign]), .keyUsageExcludesSignatures),
        (Usage(keyUsage: []), .keyUsageExcludesSignatures),
        (Usage(extendedKeyUsage: ["1.3.6.1.5.5.7.3.4"], keyUsage: .keyAgreement), .keyUsageExcludesSignatures),
        (Usage(extendedKeyUsage: ["1.3.6.1.5.5.7.3.1"], keyUsage: .digitalSignature), .purposeExcludesDocuments)
    ])
    func verdict(usage: Usage, expected: Usage.Verdict) {
        #expect(usage.verdict == expected)
        #expect(usage.permitsSigningDocuments == (expected == .permitted))
        #expect((PDFCertificateCMS.signingRefusal(usage) == nil) == (expected == .permitted))
    }

    @Test("Unreadable usage is refused rather than assumed unrestricted")
    func unreadableUsage() {
        #expect(PDFCertificateCMS.signingRefusal(nil) != nil)
    }

    @Test("Object identifiers decode to dotted form", arguments: [
        ([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x04], "1.3.6.1.5.5.7.3.4"),
        ([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x24], "1.3.6.1.5.5.7.3.36"),
        ([0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x0A, 0x03, 0x0C], "1.3.6.1.4.1.311.10.3.12"),
        ([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x2F, 0x01, 0x01, 0x05], "1.2.840.113583.1.1.5"),
        ([0x55, 0x1D, 0x25, 0x00], "2.5.29.37.0"),
        ([0x88, 0x37], "2.999"),
        ([0x00], "0.0")
    ] as [([UInt8], String)])
    func dottedOID(content: [UInt8], expected: String) throws {
        #expect(try PDFCertificateX509.dottedOID(content) == expected)
    }

    @Test("Empty, unterminated, padded, and overflowing identifiers fail closed", arguments: [
        [], [0x2B, 0x86], [0x80, 0x01], [0x2B, 0x80, 0x01],
        Array(repeating: UInt8(0xFF), count: 10) + [0x7F]
    ] as [[UInt8]])
    func malformedOID(content: [UInt8]) {
        #expect(throws: PDFCertificateError.self) { try PDFCertificateX509.dottedOID(content) }
    }

    @Test("A version 3 certificate's issuer and usage extensions are read; other extensions are ignored")
    func readsExtensions() throws {
        let data = DER.certificate(extensions: [
            DER.extension(DER.basicConstraints, critical: true, value: DER.tlv(0x30, [])),
            DER.extension(DER.extendedKeyUsage, value: DER.tlv(0x30, DER.oid(DER.serverAuth) + DER.oid(DER.emailProtection))),
            DER.extension(DER.keyUsage, critical: true, value: DER.tlv(0x03, [0x06, 0xC0]))
        ])
        let contents = try PDFCertificateX509.read(data)
        #expect(contents.issuer == "Example Issuing CA, Example Trust Services")
        #expect(contents.usage.extendedKeyUsage == ["1.3.6.1.5.5.7.3.1", "1.3.6.1.5.5.7.3.4"])
        #expect(contents.usage.keyUsage == [.digitalSignature, .nonRepudiation])
        #expect(contents.usage.permitsSigningDocuments)
    }

    @Test("A version 1 certificate has no extensions and is unrestricted")
    func versionOne() throws {
        let contents = try PDFCertificateX509.read(DER.certificate(version: false, extensions: nil))
        #expect(contents.usage == PDFCertificateUsage())
        #expect(contents.usage.permitsSigningDocuments)
    }

    @Test("Unique identifiers before the extensions are skipped")
    func uniqueIdentifiers() throws {
        let data = DER.certificate(extensions: [DER.extension(DER.keyUsage, value: DER.tlv(0x03, [0x05, 0x20]))],
                                   beforeExtensions: DER.tlv(0x81, [0x00, 0x01]) + DER.tlv(0x82, [0x00, 0x02]))
        let contents = try PDFCertificateX509.read(data)
        #expect(contents.usage.keyUsage == .keyEncipherment)
        #expect(contents.usage.verdict == .keyUsageExcludesSignatures)
    }

    @Test("Key usage beyond the first byte is read in RFC 5280 bit order")
    func decipherOnly() throws {
        let data = DER.certificate(extensions: [DER.extension(DER.keyUsage, value: DER.tlv(0x03, [0x07, 0x00, 0x80]))])
        #expect(try PDFCertificateX509.read(data).usage.keyUsage == .decipherOnly)
    }

    @Test("Issuer names decode from BMPString, and an issuer without a common name or organization has none")
    func issuerNames() throws {
        let bmp = Array("Ünïcode CA".data(using: .utf16BigEndian) ?? Data())
        let unicode = DER.certificate(issuer: DER.name([(DER.commonName, DER.tlv(0x1E, bmp))]), extensions: nil)
        #expect(try PDFCertificateX509.read(unicode).issuer == "Ünïcode CA")
        let unitOnly = DER.certificate(issuer: DER.name([([0x55, 0x04, 0x0B], DER.tlv(0x0C, Array("Unit".utf8)))]), extensions: nil)
        #expect(try PDFCertificateX509.read(unitOnly).issuer == nil)
    }

    @Test("Repeated, empty, or malformed usage extensions fail closed", arguments: [
        DER.certificate(extensions: [DER.extension(DER.extendedKeyUsage, value: DER.tlv(0x30, DER.oid(DER.emailProtection))),
                                     DER.extension(DER.extendedKeyUsage, value: DER.tlv(0x30, DER.oid(DER.serverAuth)))]),
        DER.certificate(extensions: [DER.extension(DER.extendedKeyUsage, value: DER.tlv(0x30, []))]),
        DER.certificate(extensions: [DER.extension(DER.extendedKeyUsage, value: DER.tlv(0x30, DER.tlv(0x0C, [0x41])))]),
        DER.certificate(extensions: [DER.extension(DER.extendedKeyUsage, value: DER.oid(DER.emailProtection))]),
        DER.certificate(extensions: [DER.extension(DER.keyUsage, value: DER.tlv(0x03, [0x08, 0x80]))]),
        DER.certificate(extensions: [DER.extension(DER.keyUsage, value: DER.tlv(0x03, []))]),
        DER.certificate(extensions: [DER.extension(DER.keyUsage, value: DER.tlv(0x03, [0x07, 0x80]) + [0x00])]),
        DER.certificate(extensions: [DER.tlv(0x30, DER.tlv(0x06, DER.keyUsage))]),
        DER.certificate(extensions: [], beforeExtensions: DER.tlv(0xA3, DER.tlv(0x30, []))),
        DER.certificate(extensions: [], beforeExtensions: DER.tlv(0x04, [])),
        DER.certificate(extensions: nil) + Data([0x00]),
        Data(), Data([0x30, 0x80, 0x00, 0x00]), Data(repeating: 0x30, count: 70_000)
    ])
    func malformedCertificate(data: Data) {
        #expect(throws: PDFCertificateError.self) { try PDFCertificateX509.read(data) }
    }

    @Test("Every truncation of a certificate fails closed")
    func truncations() {
        let data = DER.certificate(extensions: [DER.extension(DER.keyUsage, value: DER.tlv(0x03, [0x07, 0x80]))])
        for length in 0..<data.count {
            #expect(throws: PDFCertificateError.self) { try PDFCertificateX509.read(data.prefix(length)) }
        }
    }
}

/// Hand-built DER for certificate structure tests. Only the fields the reader inspects
/// carry meaningful values; the algorithm, validity, and key are empty sequences.
private enum DER {
    static let keyUsage: [UInt8] = [0x55, 0x1D, 0x0F]
    static let extendedKeyUsage: [UInt8] = [0x55, 0x1D, 0x25]
    static let basicConstraints: [UInt8] = [0x55, 0x1D, 0x13]
    static let commonName: [UInt8] = [0x55, 0x04, 0x03]
    static let organization: [UInt8] = [0x55, 0x04, 0x0A]
    static let serverAuth: [UInt8] = [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01]
    static let emailProtection: [UInt8] = [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x04]

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        let count = content.count
        let length: [UInt8] = count < 0x80 ? [UInt8(count)] : count <= 0xFF ? [0x81, UInt8(count)] : [0x82, UInt8(count >> 8), UInt8(count & 0xFF)]
        return [tag] + length + content
    }

    static func oid(_ content: [UInt8]) -> [UInt8] { tlv(0x06, content) }

    static func name(_ attributes: [([UInt8], [UInt8])]) -> [UInt8] {
        tlv(0x30, attributes.flatMap { tlv(0x31, tlv(0x30, oid($0.0) + $0.1)) })
    }

    static func `extension`(_ identifier: [UInt8], critical: Bool = false, value: [UInt8]) -> [UInt8] {
        tlv(0x30, oid(identifier) + (critical ? [0x01, 0x01, 0xFF] : []) + tlv(0x04, value))
    }

    static func certificate(version: Bool = true, issuer: [UInt8]? = nil, extensions: [[UInt8]]?, beforeExtensions: [UInt8] = []) -> Data {
        let issuer = issuer ?? name([(commonName, tlv(0x0C, Array("Example Issuing CA".utf8))),
                                     (organization, tlv(0x13, Array("Example Trust Services".utf8)))])
        let empty = tlv(0x30, [])
        var fields = (version ? tlv(0xA0, tlv(0x02, [0x02])) : []) + tlv(0x02, [0x01]) + empty + issuer + empty
        fields += name([(commonName, tlv(0x0C, Array("Example Signer".utf8)))]) + empty + beforeExtensions
        if let extensions { fields += tlv(0xA3, tlv(0x30, extensions.flatMap { $0 })) }
        return Data(tlv(0x30, tlv(0x30, fields) + empty + tlv(0x03, [0x00])))
    }
}
