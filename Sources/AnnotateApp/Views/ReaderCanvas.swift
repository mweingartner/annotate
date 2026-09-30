import Atrium
import SwiftUI

/// The PDF itself, edge to edge beneath the toolbar, with the few floating controls a
/// reader needs: messages at the top, the page indicator at the bottom.
struct ReaderCanvas: View {
    @Bindable var model: ReaderModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PDFReaderView(model: model)
            .accessibilityLabel("PDF document")
            .overlay(alignment: .top) {
                if let message = model.errorMessage {
                    ReaderErrorBanner(message: message) { model.errorMessage = nil }
                        .frame(maxWidth: Metrics.readableWidth)
                        .padding(Spacing.group)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        .onAppear { AccessibilityNotification.Announcement(message).post() }
                }
            }
            .overlay(alignment: .bottom) {
                PageIndicator(model: model)
                    .padding(.bottom, Spacing.group)
            }
            .atriumAnimation(Motion.settle, value: model.errorMessage)
    }
}
