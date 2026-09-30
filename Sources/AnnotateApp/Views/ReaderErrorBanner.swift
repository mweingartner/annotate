import Atrium
import SwiftUI

/// A problem the person should read before carrying on. It floats over the page in
/// glass, says what happened in words beside a symbol, and stays until dismissed.
struct ReaderErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.snug) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.Status.caution)
                .accessibilityHidden(true)
            Text(message)
                .font(Typography.supporting)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.quiet)
                .help("Dismiss this message")
        }
        .padding(.vertical, Spacing.tight)
        .atriumFloatingGlass()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Problem: \(message)")
    }
}
