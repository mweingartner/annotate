import Atrium
import SwiftUI

struct WelcomeView: View {
    @Bindable var model: ReaderModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: Spacing.room) {
                        WelcomeIntro(model: model)
                            .frame(maxWidth: 440, alignment: .leading)
                        WelcomePreview()
                    }
                    .frame(minWidth: 680)

                    VStack(alignment: .leading, spacing: Spacing.section) {
                        WelcomeIntro(model: model)
                        WelcomePreview()
                            .frame(maxWidth: .infinity)
                    }
                }

                Hairline()

                LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.inspector.min - Spacing.room), alignment: .top)], alignment: .leading, spacing: Spacing.margin) {
                    WelcomeFeature(symbol: "highlighter", title: "Make your mark", detail: "Select a passage. Add color, an icon, and your own perspective.", color: .orange)
                    WelcomeFeature(symbol: "arrow.turn.down.right", title: "Find your way back", detail: "Move through important passages, questions, notes, and revisit lists.", color: .teal)
                    WelcomeFeature(symbol: "square.and.arrow.up", title: "Share the thinking", detail: "Print or export a PDF with visible marks and a readable notes index.", color: .indigo)
                }

                Label("Local PDF tools. Choose local or cloud AI when you need it.", systemImage: "lock.shield")
                    .font(Typography.supporting)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(Spacing.room)
            .frame(maxWidth: 930)
            .frame(maxWidth: .infinity, minHeight: 590)
        }
        .background(.background)
    }
}
