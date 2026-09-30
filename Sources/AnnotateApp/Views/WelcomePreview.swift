import Atrium
import SwiftUI

struct WelcomePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("FIELD NOTES")
                    .tracking(1.8)
                Spacer()
                Text("014")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.tertiary)

            Text("The art of\npaying attention")
                .font(.title2)
                .fontDesign(.serif)

            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.1)).frame(height: 4)
                RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.1)).frame(width: 165, height: 4)
                Text("Some ideas deserve\na second look.")
                    .font(.body)
                    .fontDesign(.serif)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
                    .background(.yellow.opacity(0.35), in: .rect(cornerRadius: 3))
                RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.1)).frame(height: 4)
                RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.1)).frame(width: 143, height: 4)
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(Palette.accentText)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Worth coming back to")
                        .font(.callout.bold())
                    Text("What could I see differently?")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Palette.accentText.opacity(0.07), in: .rect(cornerRadius: 10))
        }
        .padding(26)
        .frame(width: 270)
        .background(.background, in: .rect(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).stroke(.primary.opacity(0.08), lineWidth: 1) }
        .shadow(color: .black.opacity(0.08), radius: 22, x: 0, y: 9)
        .rotationEffect(.degrees(2))
        .padding(10)
        .accessibilityHidden(true)
    }
}
