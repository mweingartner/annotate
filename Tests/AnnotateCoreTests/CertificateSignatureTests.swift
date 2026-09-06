import AppKit
import CoreGraphics
import PDFKit
import Security
import Testing
@testable import AnnotateCore

@Suite("Certificate PDF signatures", .serialized)
@MainActor
struct CertificateSignatureTests {
    @Test("Native CMS returns detached content with an intact certificate signature")
    func nativeCMS() throws {
        let fixture = try CertificateFixture()
        defer { fixture.cleanUp() }
        let content = Data("Disposable synthetic evidence".utf8)
        let cms = try PDFCertificateCMS.sign(content, identity: fixture.identity)
        #expect(cms[1] != 0x80, "CMS must use definite-length DER, not indefinite-length BER.")
        let checked = try PDFCertificateCMS.verify(cms, content: content, anchors: [fixture.certificate])
        #expect(checked.intact)
        #expect(checked.trusted)
    }

    @Test("An intact signature on embedded content cannot authenticate unrelated PDF bytes")
    func attachedContentRejected() throws {
        let fixture = try CertificateFixture()
        defer { fixture.cleanUp() }
        try Data("Signed embedded content".utf8).write(to: fixture.directory.appendingPathComponent("embedded.bin"))
        try CertificateFixture.openssl(["cms", "-sign", "-binary", "-nodetach", "-in", "embedded.bin", "-signer", "certificate.pem", "-inkey", "key.pem", "-outform", "DER", "-out", "attached.der", "-md", "sha256"], in: fixture.directory)
        let attached = try Data(contentsOf: fixture.directory.appendingPathComponent("attached.der"))
        #expect(throws: PDFCertificateError.self) { try PDFCertificateCMS.verify(attached, content: Data("Unrelated PDF bytes".utf8)) }
        try CertificateFixture.openssl(["cms", "-encrypt", "-binary", "-in", "embedded.bin", "-outform", "DER", "-out", "encrypted.der", "certificate.pem"], in: fixture.directory)
        let encrypted = try Data(contentsOf: fixture.directory.appendingPathComponent("encrypted.der"))
        #expect(throws: PDFCertificateError.self) { try PDFCertificateCMS.verify(encrypted, content: Data("Unrelated PDF bytes".utf8)) }
    }

    @Test("Detached SHA256 signature independently verifies and preserves pages, forms, and annotations")
    func interoperableSignature() throws {
        let fixture = try CertificateFixture()
        defer { fixture.cleanUp() }
        let document = SamplePDF.make()
        let first = try #require(document.page(at: 0))
        _ = Fixtures.foreignAnnotation(on: first)
        let field = PDFAnnotation(bounds: CGRect(x: 40, y: 50, width: 160, height: 30), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text; field.fieldName = "Preserved field"; field.widgetStringValue = "Preserved value"
        first.addAnnotation(field)
        let originalAnnotationCount = first.annotations.count
        let signed = try PDFCertificateSignature.signedData(document: document, identity: fixture.identity, reason: "Disposable verification")
        let reports = try PDFCertificateSignature.validate(data: signed)
        let report = try #require(reports.first)
        #expect(reports.count == 1)
        #expect(report.integrity == .intact)
        #expect(report.trust == .untrusted)
        #expect(report.coversWholeFile)
        #expect(report.signerName == "Annotate Disposable Test Certificate")
        #expect(report.status == "Signature intact · certificate not trusted")
        let anchored = try PDFCertificateSignature.validate(data: signed, anchors: [fixture.certificate])
        #expect(anchored.first?.trust == .trusted)

        let output = fixture.directory.appendingPathComponent("signed.pdf")
        try signed.write(to: output)
        let reopened = try #require(PDFDocument(url: output))
        #expect(reopened.pageCount == document.pageCount)
        #expect(reopened.string == document.string)
        #expect(reopened.page(at: 0)?.annotations.contains { $0.contents == "Another reader's annotation — preserve this." } == true)
        #expect(reopened.page(at: 0)?.annotations.contains { $0.fieldName == "Preserved field" && $0.widgetStringValue == "Preserved value" } == true)
        #expect(document.page(at: 0)?.annotations.count == originalAnnotationCount)
        #expect(!first.annotations.contains { $0.widgetFieldType == .signature })

        // Independent extraction deliberately does not use the production parser.
        let extracted = try extract(signed)
        try extracted.content.write(to: fixture.directory.appendingPathComponent("content.bin"))
        try extracted.cms.write(to: fixture.directory.appendingPathComponent("signature.der"))
        try CertificateFixture.openssl(["cms", "-verify", "-binary", "-inform", "DER", "-in", "signature.der", "-content", "content.bin", "-noverify", "-out", "verified.bin"], in: fixture.directory)
        #expect(try Data(contentsOf: fixture.directory.appendingPathComponent("verified.bin")) == extracted.content)
        try CertificateFixture.openssl(["cms", "-cmsout", "-print", "-inform", "DER", "-in", "signature.der", "-out", "cms.txt"], in: fixture.directory)
        let cmsText = try String(contentsOf: fixture.directory.appendingPathComponent("cms.txt"), encoding: .utf8)
        #expect(cmsText.contains("sha256"))
        #expect(cmsText.contains("eContent: <ABSENT>"))
        if ProcessInfo.processInfo.environment["ANNOTATE_CERTIFICATE_SMOKE_OUTPUT"] == "1" {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let directory = root.appendingPathComponent("build", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Only public certificate + signed synthetic guide; private key/P12
            // remain in the disposable fixture and are erased by defer above.
            try signed.write(to: directory.appendingPathComponent("Certificate-Validation-Smoke.pdf"), options: .atomic)
        }
    }

    @Test("Changed signed bytes fail both native and independent verification; appended bytes are disclosed")
    func tamperingAndAppendedBytes() throws {
        let fixture = try CertificateFixture()
        defer { fixture.cleanUp() }
        let signed = try PDFCertificateSignature.signedData(document: SamplePDF.make(), identity: fixture.identity, reason: "Sentinel reason")
        var tampered = signed
        let marker = Data("/Reason <FEFF0053".utf8)
        let location = try #require(tampered.range(of: marker))
        tampered[location.upperBound - 1] = Character("4").asciiValue!
        let report = try #require(PDFCertificateSignature.validate(data: tampered).first)
        #expect(report.integrity == .invalid)
        #expect(report.trust == .notEvaluated)
        let extracted = try extract(tampered)
        try extracted.content.write(to: fixture.directory.appendingPathComponent("changed.bin"))
        try extracted.cms.write(to: fixture.directory.appendingPathComponent("signature.der"))
        let status = try CertificateFixture.openssl(["cms", "-verify", "-binary", "-inform", "DER", "-in", "signature.der", "-content", "changed.bin", "-noverify", "-out", "verified.bin"], in: fixture.directory, shouldSucceed: false)
        #expect(status != 0)
        var appended = signed; appended.append(Data("\n% Unsigned trailing update\n".utf8))
        let later = try #require(PDFCertificateSignature.validate(data: appended).first)
        #expect(later.integrity == .intact)
        #expect(!later.coversWholeFile)
        #expect(later.status == "Document changed after signing")
    }

    @Test("Malformed ranges, unsupported signatures, re-signing, and encryption fail clearly")
    func refusalCases() throws {
        let fixture = try CertificateFixture()
        defer { fixture.cleanUp() }
        let source = SamplePDF.make()
        let signed = try PDFCertificateSignature.signedData(document: source, identity: fixture.identity)
        let reopened = try #require(PDFDocument(data: signed))
        #expect(throws: PDFCertificateError.self) { try PDFCertificateSignature.signedData(document: reopened, identity: fixture.identity) }
        var malformed = signed
        let marker = try #require(malformed.range(of: Data("/ByteRange [0 ".utf8)))
        malformed[marker.upperBound - 2] = 0x31
        #expect(try PDFCertificateSignature.validate(data: malformed).first?.integrity == .invalid)
        var unsupported = signed
        let filter = try #require(unsupported.range(of: Data("adbe.pkcs7.detached".utf8)))
        unsupported.replaceSubrange(filter, with: Data("xxxx.pkcs7.detached".utf8))
        #expect(try PDFCertificateSignature.validate(data: unsupported).first?.integrity == .unsupported)
        let unsigned = try #require(source.dataRepresentation())
        #expect(try PDFCertificateSignature.validate(data: unsigned).isEmpty)
        let protectedData = try #require(source.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "owner", PDFDocumentWriteOption.userPasswordOption: "user"]))
        let protected = try #require(PDFDocument(data: protectedData))
        #expect(throws: PDFCertificateError.self) { try PDFCertificateSignature.signedData(document: protected, identity: fixture.identity) }
        #expect(throws: PDFCertificateError.self) { try PDFCertificateSignature.validate(data: protectedData) }
        #expect(throws: PDFCertificateError.self) { try PDFCertificateCMS.sign(Data(), identity: fixture.identity) }
        #expect(throws: PDFCertificateError.self) { try PDFCertificateCMS.verify(Data(), content: Data()) }
    }

    private func extract(_ data: Data) throws -> (content: Data, cms: Data) {
        let text = String(decoding: data, as: UTF8.self)
        let regex = try NSRegularExpression(pattern: #"/ByteRange\s*\[\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*\]"#)
        let match = try #require(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        let ranges = try (1...4).map { index -> Int in
            let range = try #require(Range(match.range(at: index), in: text))
            return try #require(Int(text[range]))
        }
        #expect(ranges[0] == 0)
        #expect(ranges[2] + ranges[3] == data.count)
        var content = data.subdata(in: 0..<ranges[1]); content.append(data.subdata(in: ranges[2]..<data.count))
        let hex = String(decoding: data[(ranges[1] + 1)..<(ranges[2] - 1)], as: UTF8.self)
        var cms = Data(); var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            cms.append(try #require(UInt8(hex[index..<end], radix: 16))); index = end
        }
        var length = Int(cms[1]), offset = 2
        if length >= 128 {
            let count = length - 128; length = 0
            for byte in cms[2..<(2 + count)] { length = length * 256 + Int(byte) }
            offset += count
        }
        return (content, cms.prefix(offset + length))
    }
}
