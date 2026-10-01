import CoreGraphics
import Foundation
import PDFKit
import Security

@MainActor
public enum PDFCertificateSignature {
    public static let maximumPDFBytes = 256 * 1_024 * 1_024
    private static let reservedSignatureBytes = 32_768

    /// Produces final signed bytes. Never load and reserialize the result before saving it.
    public static func signedData(document: PDFDocument, identity: SecIdentity, reason: String = "") throws -> Data {
        guard !document.isLocked, document.allowsCopying, document.allowsDocumentChanges else { throw PDFCertificateError.permission }
        guard !document.isEncrypted else { throw PDFCertificateError.encrypted }
        guard let input = document.dataRepresentation() else { throw PDFCertificateError.invalidPDF }
        let source = try pdf(input)
        guard try PDFCertificateInspection.entries(in: source).isEmpty else { throw PDFCertificateError.alreadySigned }
        let graph = try PDFNativeObjectGraph(document: source)
        guard case .dictionary(var catalog) = graph[graph.rootID], let page = source.page(at: 1),
              let pageDictionary = page.dictionary, let pageID = graph.objectID(for: pageDictionary),
              case .dictionary(var pageValues) = graph[pageID] else { throw PDFCertificateError.invalidPDF }
        var placeholder = Data(count: reservedSignatureBytes)
        let randomStatus = placeholder.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try PDFCertificateError.check(randomStatus)
        let sentinels = [0, 1_111_111_111_111_111_111, 2_222_222_222_222_222_222, 3_333_333_333_333_333_333]
        var signature: [String: PDFNativeValue] = ["Type": .name("Sig"), "Filter": .name("Adobe.PPKLite"),
            "SubFilter": .name("adbe.pkcs7.detached"), "ByteRange": .array(sentinels.map(PDFNativeValue.integer)), "Contents": .string(placeholder)]
        if !reason.isEmpty {
            guard reason.utf8.count <= 2_000 else { throw PDFCertificateError.reasonTooLong }
            signature["Reason"] = .string(textData(reason))
        }
        let signatureReference = try graph.append(.dictionary(signature))
        let fieldReference = try graph.append(.dictionary(["Type": .name("Annot"), "Subtype": .name("Widget"), "FT": .name("Sig"),
            "T": .string(Data("Annotate Certificate Signature \(UUID().uuidString)".utf8)), "V": signatureReference,
            "Rect": .array([.integer(0), .integer(0), .integer(0), .integer(0)]), "F": .integer(132), "P": .reference(pageID)]))
        var form: [String: PDFNativeValue] = [:]
        if let existing = catalog["AcroForm"] {
            guard case .dictionary(let values) = try graph.resolved(existing) else { throw PDFCertificateError.invalidPDF }
            form = values
        }
        var fields: [PDFNativeValue] = []
        if let existing = form["Fields"] {
            guard case .array(let values) = try graph.resolved(existing) else { throw PDFCertificateError.invalidPDF }
            fields = values
        }
        fields.append(fieldReference); form["Fields"] = .array(fields); form["SigFlags"] = .integer(3)
        catalog["AcroForm"] = try graph.append(.dictionary(form)); graph[graph.rootID] = .dictionary(catalog)
        var annotations: [PDFNativeValue] = []
        if let existing = pageValues["Annots"] {
            guard case .array(let values) = try graph.resolved(existing) else { throw PDFCertificateError.invalidPDF }
            annotations = values
        }
        annotations.append(fieldReference); pageValues["Annots"] = .array(annotations); graph[pageID] = .dictionary(pageValues)
        var output = try graph.write()
        guard output.count <= maximumPDFBytes else { throw PDFCertificateError.tooLarge }
        let contents = Data(nativePDFHex(Array(placeholder)).utf8)
        let contentsRange = try uniqueRange(of: contents, in: output)
        let rangeMarker = Data(("[" + sentinels.map { "\($0) " }.joined() + "]").utf8)
        let markerRange = try uniqueRange(of: rangeMarker, in: output)
        let values = [0, contentsRange.lowerBound, contentsRange.upperBound, output.count - contentsRange.upperBound]
        let literal = "[" + values.map { "\($0) " }.joined()
        guard literal.utf8.count < markerRange.count else { throw PDFCertificateError.tooLarge }
        let replacement = Data((literal + String(repeating: " ", count: markerRange.count - literal.utf8.count - 1) + "]").utf8)
        output.replaceSubrange(markerRange, with: replacement)
        var signed = output.subdata(in: 0..<contentsRange.lowerBound)
        signed.append(output.subdata(in: contentsRange.upperBound..<output.count))
        let cms = try PDFCertificateCMS.sign(signed, identity: identity)
        guard cms.count <= reservedSignatureBytes else { throw PDFCertificateError.signatureTooLarge }
        var padded = cms; padded.append(Data(count: reservedSignatureBytes - cms.count))
        output.replaceSubrange(contentsRange, with: Data(nativePDFHex(Array(padded)).utf8))
        let checked = try validate(data: output)
        guard checked.count == 1, checked[0].integrity == .intact, checked[0].coversWholeFile else {
            throw PDFCertificateError.verificationFailed(checked.map(\.detail).joined(separator: " "))
        }
        return output
    }

    public static func validate(data: Data) throws -> [PDFCertificateValidation] { try validate(data: data, anchors: nil) }

    static func validate(data: Data, anchors: [SecCertificate]?) throws -> [PDFCertificateValidation] {
        let document = try pdf(data)
        return try PDFCertificateInspection.entries(in: document).map { entry in
            do {
                guard let dictionary = entry.dictionary else { throw PDFCertificateError.malformedSignature }
                guard nativeName(dictionary, "SubFilter") == "adbe.pkcs7.detached" else { throw PDFCertificateError.unsupportedSignature }
                let signed = try PDFCertificateInspection.signedContent(dictionary, data: data)
                let checked = try PDFCertificateCMS.verify(signed.envelope, content: signed.content, anchors: anchors)
                return PDFCertificateValidation(fieldName: entry.name, signerName: checked.names,
                    integrity: checked.intact ? .intact : .invalid, trust: checked.intact ? checked.trust : .notEvaluated,
                    coversWholeFile: signed.coversWholeFile,
                    detail: checked.detail + (signed.coversWholeFile ? "" : " Additional bytes were appended after this signature; their changes have not been validated."),
                    signerCertificates: checked.certificates)
            } catch {
                let unsupported = (error as? PDFCertificateError).map { if case .unsupportedSignature = $0 { return true }; return false } ?? false
                return PDFCertificateValidation(fieldName: entry.name, signerName: "Unknown signer", integrity: unsupported ? .unsupported : .invalid,
                                                trust: .notEvaluated, coversWholeFile: false, detail: error.localizedDescription, signerCertificates: [])
            }
        }
    }

    private static func pdf(_ data: Data) throws -> CGPDFDocument {
        guard data.count <= maximumPDFBytes else { throw PDFCertificateError.tooLarge }
        guard let provider = CGDataProvider(data: data as CFData), let result = CGPDFDocument(provider), result.numberOfPages > 0 else { throw PDFCertificateError.invalidPDF }
        guard !result.isEncrypted else { throw PDFCertificateError.encrypted }
        return result
    }
    private static func uniqueRange(of needle: Data, in data: Data) throws -> Range<Data.Index> {
        guard let range = data.range(of: needle), data.range(of: needle, in: range.upperBound..<data.endIndex) == nil else { throw PDFCertificateError.malformedSignature }
        return range
    }
    private static func textData(_ text: String) -> Data {
        var result = Data([0xFE, 0xFF]); result.append(text.data(using: .utf16BigEndian) ?? Data()); return result
    }
}
