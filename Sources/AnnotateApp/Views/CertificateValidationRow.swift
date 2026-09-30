import AnnotateCore
import Atrium
import SwiftUI

/// One signature found in a validated file: its verdict as symbol and words, the signer,
/// and the details behind the verdict.
struct CertificateValidationRow: View {
    let report: PDFCertificateValidation

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
            Text(report.signerName).font(Typography.body).textSelection(.enabled)
            DisclosureGroup("Validation details") {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(report.detail).font(Typography.supporting).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Field: \(report.fieldName)").font(Typography.supporting).foregroundStyle(.secondary)
                }
                .padding(.top, Spacing.tight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
