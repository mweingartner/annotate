import AnnotateCore
import Atrium
import SwiftUI
import UniformTypeIdentifiers

/// Signing a copy with a Keychain certificate, and validating a signed PDF.
struct CertificateSignaturePanel: View {
    @Bindable var model: ReaderModel
    @State private var identities: [PDFSigningIdentity] = []
    @State private var selectedID: UUID?
    @State private var loadedIdentities = false
    @State private var reason = ""
    @State private var reports: [PDFCertificateValidation] = []
    @State private var validatedFile: String?

    private var selectedIdentity: PDFSigningIdentity? { identities.first { $0.id == selectedID } }

    var body: some View {
        PageSection("Certificate signature") {
            VStack(alignment: .leading, spacing: Spacing.control) {
                note("Sign a copy to let readers verify its exact contents and signing certificate. Place any visible signature above first.")
                Button(loadedIdentities ? "Reload signing identities" : "Load identities from Keychain", systemImage: "key", action: loadIdentities)
                if loadedIdentities {
                    if identities.isEmpty {
                        note("No signing identities were found. Add a certificate with its private key in Keychain Access, then reload.")
                    } else {
                        Picker("Signing identity", selection: $selectedID) {
                            Text("Choose a certificate").tag(nil as UUID?)
                            ForEach(identities) { identity in
                                Text("\(identity.name) · \(identity.fingerprint.suffix(8))").tag(Optional(identity.id))
                            }
                        }
                        if let selectedIdentity {
                            DisclosureGroup("Certificate fingerprint") {
                                Text("SHA-256: \(selectedIdentity.fingerprint)")
                                    .font(Typography.meta.monospaced()).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.top, Spacing.tight)
                            }
                        }
                        TextField("Reason for signing (optional)", text: $reason, axis: .vertical).lineLimit(1...3)
                        // Placing the visible signature is the pane's primary action; this is secondary.
                        Button("Sign a copy…", systemImage: "seal", action: signCopy)
                            .disabled(selectedIdentity == nil)
                        note("Only Sign a copy uses your private key. macOS may ask you to allow access. The certificate is embedded; the private key stays in Keychain.")
                    }
                }
                Hairline()
                    .padding(.vertical, Spacing.snug)
                Button("Validate a signed PDF…", systemImage: "checkmark.seal", action: chooseValidationFile)
                note("Checks the original file, including any changes after signing. Certificate trust is evaluated on this Mac without network access.")
                if let validatedFile {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(validatedFile).font(Typography.heading).lineLimit(2)
                            .padding(.bottom, Spacing.snug)
                        if reports.isEmpty { note("No certificate signatures found.") }
                        ForEach(reports) { report in
                            Hairline()
                            CertificateValidationRow(report: report)
                                .padding(.vertical, Spacing.snug)
                        }
                    }
                }
                DisclosureGroup("What this signature verifies") {
                    note("This creates a detached SHA-256 approval signature. It does not certify permitted edits or add a trusted timestamp. Validation reports byte integrity separately from certificate trust; it does not check revocation or long-term archival validity. Encrypted PDFs and adding another signature to an already signed PDF are not supported.")
                        .padding(.top, Spacing.tight)
                }
            }
        }
    }

    /// An explanation under a control: supporting size, secondary, wrapping.
    private func note(_ text: String) -> some View {
        Text(text).font(Typography.supporting).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func loadIdentities() {
        do {
            identities = try PDFSigningIdentity.available()
            selectedID = nil
            loadedIdentities = true
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func signCopy() {
        guard let selectedIdentity else { return }
        let reason = reason
        model.performOperation("Signing a PDF copy…") {
            guard let document = model.pdfDocument else { throw PDFCertificateError.invalidPDF }
            let data = try PDFCertificateSignature.signedData(document: document, identity: selectedIdentity.identity, reason: reason)
            try Task.checkCancellation()
            let base = (model.fileName as NSString).deletingPathExtension
            model.saveOutput(data: data, suggestedName: "\(base) — Signed.pdf", contentType: .pdf)
        }
    }

    private func chooseValidationFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the original signed PDF. Saving it through a PDF editor can change the signed bytes."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.performOperation("Validating certificate signatures…") {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size, size <= PDFCertificateSignature.maximumPDFBytes else { throw PDFCertificateError.tooLarge }
            // Validate the exact original bytes; PDFKit serialization invalidates signatures.
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let checked = try PDFCertificateSignature.validate(data: data)
            try Task.checkCancellation()
            reports = checked
            validatedFile = url.lastPathComponent
        }
    }
}
