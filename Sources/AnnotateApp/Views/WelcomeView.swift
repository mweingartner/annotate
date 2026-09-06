import SwiftUI

struct WelcomeView: View {
    @Bindable var model: ReaderModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 38) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 48) {
                        WelcomeIntro(model: model)
                            .frame(maxWidth: 440, alignment: .leading)
                        WelcomePreview()
                    }
                    .frame(minWidth: 680)

                    VStack(alignment: .leading, spacing: 30) {
                        WelcomeIntro(model: model)
                        WelcomePreview()
                            .frame(maxWidth: .infinity)
                    }
                }

                Divider()

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .top)], alignment: .leading, spacing: 24) {
                    WelcomeFeature(symbol: "highlighter", title: "Make your mark", detail: "Select a passage. Add color, an icon, and your own perspective.", color: .orange)
                    WelcomeFeature(symbol: "arrow.turn.down.right", title: "Find your way back", detail: "Move through important passages, questions, notes, and revisit lists.", color: .teal)
                    WelcomeFeature(symbol: "square.and.arrow.up", title: "Share the thinking", detail: "Print or export a PDF with visible marks and a readable notes index.", color: .indigo)
                }

                Label("Local PDF tools. Choose local or cloud AI when you need it.", systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(42)
            .frame(maxWidth: 930)
            .frame(maxWidth: .infinity, minHeight: 590)
        }
        .background {
            LinearGradient(colors: [ReaderStyle.accent.opacity(0.04), .clear, Color.orange.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
