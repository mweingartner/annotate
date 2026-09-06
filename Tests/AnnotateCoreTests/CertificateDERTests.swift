import Foundation
import Testing
@testable import AnnotateCore

@Suite("Certificate ASN.1 container boundaries")
struct CertificateDERTests {
    @Test("Indefinite nested sequences become definite lengths without changing primitive bytes")
    func definiteContainers() throws {
        let ber = Data([0x30, 0x80, 0x30, 0x80, 0x04, 0x03, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00])
        #expect(try PDFCertificateDER.encode(ber) == Data([0x30, 0x07, 0x30, 0x05, 0x04, 0x03, 0x00, 0x00, 0xFF]))
        var long = Data([0x30, 0x80, 0x04, 0x81, 0x80]); long.append(Data(repeating: 0xFF, count: 128)); long.append(contentsOf: [0, 0])
        let output = try PDFCertificateDER.encode(long)
        #expect(output.prefix(3) == Data([0x30, 0x81, 0x83]))
        #expect(output.suffix(128) == Data(repeating: 0xFF, count: 128))
    }

    @Test("Truncated, primitive-indefinite, trailing, and deeply nested containers fail closed", arguments: [
        Data(), Data([0x30, 0x80]), Data([0x30, 0x03, 0x04, 0x02, 0xFF]),
        Data([0x30, 0x04, 0x04, 0x80, 0x00, 0x00]), Data([0x30, 0x00, 0x00]),
        Data(Array(repeating: [UInt8(0x30), 0x80], count: 80).flatMap { $0 } + Array(repeating: UInt8(0), count: 160))
    ])
    func malformed(data: Data) {
        #expect(throws: PDFCertificateError.self) { try PDFCertificateDER.encode(data) }
    }
}
