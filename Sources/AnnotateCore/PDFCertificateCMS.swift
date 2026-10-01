import Foundation
import Security

@MainActor
enum PDFCertificateCMS {
    struct Verification {
        let intact: Bool
        let trust: PDFCertificateValidation.Trust
        let names: String
        let certificates: [PDFCertificateValidation.SignerCertificate]
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
        var untrusted = false, notForSigning = false, names: [String] = [], details: [String] = []
        var certificates: [PDFCertificateValidation.SignerCertificate] = []
        for index in 0..<count {
            var status = CMSSignerStatus.unsigned
            var trust: SecTrust?
            try PDFCertificateError.check(CMSDecoderCopySignerStatus(decoder, index, SecPolicyCreateBasicX509(), false, &status, &trust, nil))
            guard status == .valid else {
                return Verification(intact: false, trust: .notEvaluated, names: "Unknown signer", certificates: [],
                                    detail: "The signed bytes do not match the certificate signature.")
            }
            var signer: SecCertificate?
            try PDFCertificateError.check(CMSDecoderCopySignerCert(decoder, index, &signer))
            guard let signer, let trust else { throw PDFCertificateError.malformedSignature }
            let name = SecCertificateCopySubjectSummary(signer) as String? ?? "Unnamed signer"
            // A malformed extension cannot show what the key was issued for, so it counts against signing.
            let contents = try? PDFCertificateX509.read(SecCertificateCopyData(signer) as Data)
            names.append(name)
            certificates.append(.init(subject: name, issuer: contents?.issuer ?? "Unnamed issuer",
                                      fingerprint: PDFCertificateX509.fingerprint(signer)))
            try PDFCertificateError.check(SecTrustSetNetworkFetchAllowed(trust, false))
            // A CMS signingTime is chosen by its signer, not a trusted timestamp.
            try PDFCertificateError.check(SecTrustSetVerifyDate(trust, Date.now as CFDate))
            if let anchors {
                try PDFCertificateError.check(SecTrustSetAnchorCertificates(trust, anchors as CFArray))
                try PDFCertificateError.check(SecTrustSetAnchorCertificatesOnly(trust, true))
            }
            var error: CFError?
            if !SecTrustEvaluateWithError(trust, &error) {
                untrusted = true
                details.append(error.map { CFErrorCopyDescription($0) as String } ?? "The certificate chain is not trusted on this Mac.")
            } else if let refusal = signingRefusal(contents?.usage) {
                notForSigning = true
                details.append("The certificate chains to a root this Mac trusts, but it wasn't issued for signing documents. " + refusal)
            }
        }
        let trust: PDFCertificateValidation.Trust = untrusted ? .untrusted : notForSigning ? .notIssuedForSigning : .trusted
        return Verification(intact: true, trust: trust, names: names.joined(separator: ", "), certificates: certificates,
            detail: details.isEmpty ? "The signed bytes match, and the certificate chains to a root this Mac trusts and was issued for signing documents." : details.joined(separator: " "))
    }

    /// Why a trusted certificate's usage doesn't cover signing documents, or nil when it does.
    /// Unreadable usage is refused: the key's purpose is then unknown.
    nonisolated static func signingRefusal(_ usage: PDFCertificateUsage?) -> String? {
        guard let usage else { return "Its key usage extensions could not be read." }
        switch usage.verdict {
        case .permitted: return nil
        case .purposeExcludesDocuments: return "Its extended key usage names only purposes other than signing documents."
        case .keyUsageExcludesSignatures: return "Its key usage allows neither digital signatures nor non-repudiation."
        }
    }
}
