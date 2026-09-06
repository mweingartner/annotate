import AnnotateCore
import SwiftUI

struct CertificateValidationRow: View {
    let report: PDFCertificateValidation

    private var verified: Bool {
        report.integrity == .intact && report.trust == .trusted && report.coversWholeFile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(report.status, systemImage: verified ? "checkmark.seal" : "exclamationmark.triangle")
                .font(.subheadline.bold())
            Text(report.signerName).font(.subheadline).textSelection(.enabled)
            DisclosureGroup("Validation details") {
                Text(report.detail).font(.caption).textSelection(.enabled)
                Text("Field: \(report.fieldName)").font(.caption).foregroundStyle(.secondary)
            }.font(.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: .rect(cornerRadius: 8))
    }
}
