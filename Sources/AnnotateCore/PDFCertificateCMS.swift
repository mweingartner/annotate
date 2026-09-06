import Foundation
import Security

@MainActor
enum PDFCertificateCMS {
    struct Verification {
        let intact: Bool
        let trusted: Bool
        let names: String
        let detail: String
    }

    static func sign(_ data: Data, identity: SecIdentity) throws -> Data {
        var value: CMSEncoder?
        try PDFCertificateError.check(CMSEncoderCreate(&value))
        guard let encoder = value else { throw PDFCertificateError.malformedSignature }
        try PDFCertificateError.check(CMSEncoderSetSignerAlgorithm(encoder, kCMSEncoderDigestAlgorithmSHA256))
        try PDFCertificateError.check(CMSEncoderAddSigners(encoder, identity))
        try PDFCertificateError.check(CMSEncoderSetHasDetachedContent(encoder, true))
        try PDFCertificateError.check(CMSEncoderAddSignedAttributes(encoder, .attrSigningTime))
        try PDFCertificateError.check(CMSEncoderSetCertificateChainMode(encoder, .chain))
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, !bytes.isEmpty else { throw PDFCertificateError.malformedSignature }
            try PDFCertificateError.check(CMSEncoderUpdateContent(encoder, base, bytes.count))
        }
        var encoded: CFData?
        try PDFCertificateError.check(CMSEncoderCopyEncodedContent(encoder, &encoded))
        guard let encoded else { throw PDFCertificateError.malformedSignature }
        return try PDFCertificateDER.encode(encoded as Data)
    }

    static func verify(_ envelope: Data, content: Data, anchors: [SecCertificate]? = nil) throws -> Verification {
        try PDFCertificateDER.requireDetachedSignedData(envelope)
        var value: CMSDecoder?
        try PDFCertificateError.check(CMSDecoderCreate(&value))
        guard let decoder = value else { throw PDFCertificateError.malformedSignature }
        try envelope.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, !bytes.isEmpty else { throw PDFCertificateError.malformedSignature }
            try PDFCertificateError.check(CMSDecoderUpdateMessage(decoder, base, bytes.count))
        }
        try PDFCertificateError.check(CMSDecoderFinalizeMessage(decoder))
        var embedded: CFData?
        try PDFCertificateError.check(CMSDecoderCopyContent(decoder, &embedded))
        guard embedded == nil else { throw PDFCertificateError.invalidEnvelope }
        try PDFCertificateError.check(CMSDecoderSetDetachedContent(decoder, content as CFData))
        var count = 0
        try PDFCertificateError.check(CMSDecoderGetNumSigners(decoder, &count))
        guard (1...64).contains(count) else { throw PDFCertificateError.malformedSignature }
        var trusted = true, names: [String] = [], details: [String] = []
        for index in 0..<count {
            var status = CMSSignerStatus.unsigned
            var trust: SecTrust?
            try PDFCertificateError.check(CMSDecoderCopySignerStatus(decoder, index, SecPolicyCreateBasicX509(), false, &status, &trust, nil))
            guard status == .valid else {
                return Verification(intact: false, trusted: false, names: "Unknown signer", detail: "The signed bytes do not match the certificate signature.")
            }
            var certificate: SecCertificate?
            try PDFCertificateError.check(CMSDecoderCopySignerCert(decoder, index, &certificate))
            names.append(certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "Unnamed signer")
            guard let trust else { throw PDFCertificateError.malformedSignature }
            try PDFCertificateError.check(SecTrustSetNetworkFetchAllowed(trust, false))
            // A CMS signingTime is chosen by its signer, not a trusted timestamp.
            try PDFCertificateError.check(SecTrustSetVerifyDate(trust, Date.now as CFDate))
            if let anchors {
                try PDFCertificateError.check(SecTrustSetAnchorCertificates(trust, anchors as CFArray))
                try PDFCertificateError.check(SecTrustSetAnchorCertificatesOnly(trust, true))
            }
            var error: CFError?
            if !SecTrustEvaluateWithError(trust, &error) {
                trusted = false
                details.append(error.map { CFErrorCopyDescription($0) as String } ?? "The certificate chain is not trusted on this Mac.")
            }
        }
        return Verification(intact: true, trusted: trusted, names: names.joined(separator: ", "),
            detail: details.isEmpty ? "The signed bytes match and the certificate chain is trusted by this Mac." : details.joined(separator: " "))
    }
}
