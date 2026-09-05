import SwiftUI

struct WelcomeIntro: View {
    @Bindable var model: ReaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            Image(systemName: "text.book.closed.fill")
                .font(.largeTitle)
                .foregroundStyle(ReaderStyle.accent)
                .frame(width: 66, height: 66)
                .glassEffect(.regular.tint(ReaderStyle.accent.opacity(0.1)), in: .rect(cornerRadius: 18))
                .accessibilityHidden(true)

            Text("A SPACE FOR CLOSE READING")
                .font(.caption)
                .tracking(1.7)
                .foregroundStyle(.secondary)

            Text("Find your place.\nKeep your thinking.")
                .font(.largeTitle)
                .fontDesign(.serif)
                .bold()
                .fixedSize(horizontal: false, vertical: true)

            Text("A home for the passages that matter, the questions they raise, and the ideas you want to return to.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Open a PDF…", systemImage: "folder", action: model.openDocument)
                    .buttonStyle(.borderedProminent)
                    .tint(ReaderStyle.actionFill)
                    .foregroundStyle(.white)
                    .controlSize(.large)
                Button("Explore a sample", action: model.openSample)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            .padding(.top, 5)

            Text("Select text to start. Every mark leads right back.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
