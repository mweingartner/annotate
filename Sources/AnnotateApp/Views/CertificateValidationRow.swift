import AnnotateCore
import Atrium
import SwiftUI

/// One signature found in a validated file: its verdict as symbol and words, the signer,
/// and the details behind the verdict.
///
/// Names come from the PDF and its certificates, so they are shown as claimed, on one
/// line, through `UntrustedText`: a crafted name cannot add a line, reorder the text
/// around it, or pass itself off as the verdict.
struct CertificateValidationRow: View {
    let report: PDFCertificateValidation

    /// Generous, because the explanation wraps; the limit only bounds a hostile flood of
    /// signer names quoted back by trust evaluation.
    private static let detailLimit = 4_000

    /// Only a trusted certificate issued for signing documents earns the positive seal.
    private var verified: Bool {
        report.integrity == .intact && report.trust == .trusted && report.coversWholeFile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            // Symbol and words, like a StatusBadge, but free to wrap: statuses run long.
            Label {
                Text(report.status).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(verified ? Palette.Status.positive : Palette.Status.caution)
            }
            .font(Typography.heading)
            VStack(alignment: .leading, spacing: 0) {
                Text("Certificate subject (as claimed)").font(Typography.meta).foregroundStyle(.secondary)
                Text(UntrustedText.display(report.signerName)).font(Typography.body)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            DisclosureGroup("Validation details") {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(UntrustedText.display(report.detail, limit: Self.detailLimit))
                        .font(Typography.supporting).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(report.signerCertificates.enumerated()), id: \.offset) { _, certificate in
                        certificateDetails(certificate)
                    }
                    Text("Field: \(UntrustedText.display(report.fieldName))").font(Typography.supporting)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .padding(.top, Spacing.tight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Who issued one signer certificate, as claimed, and the fingerprint that identifies it exactly.
    private func certificateDetails(_ certificate: PDFCertificateValidation.SignerCertificate) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // With several signers, say which certificate the issuer and fingerprint belong to.
            if report.signerCertificates.count > 1 {
                Text("Subject (as claimed): \(UntrustedText.display(certificate.subject))")
                    .font(Typography.supporting).lineLimit(1).truncationMode(.middle)
            }
            Text("Issuer (as claimed): \(UntrustedText.display(certificate.issuer))")
                .font(Typography.supporting).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Text("SHA-256: \(certificate.fingerprint)")
                .font(Typography.meta.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
