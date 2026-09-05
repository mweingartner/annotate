import SwiftUI

struct ReaderErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: ReaderStyle.compactSpacing) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss message", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
        }
        .font(.callout)
        .padding(ReaderStyle.panelPadding)
        .background(.orange.opacity(0.08))
        .accessibilityElement(children: .contain)
    }
}
