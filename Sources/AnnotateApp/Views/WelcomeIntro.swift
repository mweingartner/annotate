import Atrium
import SwiftUI

struct WelcomeIntro: View {
    @Bindable var model: ReaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: Spacing.room * 1.5, height: Spacing.room * 1.5)
                .accessibilityHidden(true)

            Text("Read. Edit.\nMake it yours.")
                .font(Typography.display)
                .fixedSize(horizontal: false, vertical: true)

            Text("Edit text right on the page, mark what matters, and find your way back. Pages, forms, signatures, conversion, OCR and your choice of assistant are here when you need them.")
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Spacing.control) {
                Button("Open a PDF…", systemImage: "folder", action: model.openDocument)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .controlSize(.large)
                Button("Explore a sample", action: model.openSample)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            .padding(.top, Spacing.snug)
            HStack {
                Button("New Blank PDF", systemImage: "doc.badge.plus", action: model.newBlankPDF)
                Button("Create or Convert Files…", systemImage: "arrow.triangle.2.circlepath") { model.activeTool = .convert }
            }
            .buttonStyle(.borderless)

            Text("Select text to start. Every mark leads right back.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
