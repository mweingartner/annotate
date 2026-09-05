import SwiftUI

struct SearchResultRow: View {
    let hit: SearchHit
    let jump: () -> Void

    var body: some View {
        Button(action: jump) {
            VStack(alignment: .leading, spacing: ReaderStyle.compactSpacing) {
                Label("Page \(hit.pageIndex + 1)", systemImage: "doc.text")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(hit.snippet)
                    .font(.body)
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(.background, in: .rect(cornerRadius: ReaderStyle.radius))
            .overlay {
                RoundedRectangle(cornerRadius: ReaderStyle.radius)
                    .stroke(.primary.opacity(0.08), lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Jump to this search result on page \(hit.pageIndex + 1)")
    }
}
