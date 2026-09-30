import AppKit
import Atrium
import SwiftUI

/// Replace, move, resize or remove the selected source image; changes stay pending until applied.
struct ImageEditControls: View {
    @Bindable var model: ReaderModel
    @Bindable var session: ImageEditSession

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.control) {
            HStack(spacing: Spacing.snug) {
                Text("Selected image · Page \(session.image.pageIndex + 1)").font(Typography.heading)
                Spacer(minLength: Spacing.snug)
                Button("Deselect image", systemImage: "xmark") { model.discardImageChanges() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.quiet)
                    .disabled(session.hasChanges)
            }
            if !model.imageEditIsCurrent {
                Label {
                    Text("The PDF has changed. Discard these controls and select the image again.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.Status.caution)
                }
                .font(Typography.supporting)
            }
            if let replacement = session.replacement {
                Image(nsImage: NSImage(cgImage: replacement, size: NSSize(width: replacement.width, height: replacement.height)))
                    .resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: Metrics.doubleRow * 3)
                    .background(.white, in: .rect(cornerRadius: Radius.field))
                Text(session.replacementName ?? "Replacement image").font(Typography.supporting).lineLimit(2)
            }
            Button("Choose replacement…", systemImage: "photo.on.rectangle", action: model.chooseImageReplacement)
                .disabled(!model.imageEditIsCurrent || model.isProcessing)
            note("The replacement fills the current frame. Changes stay pending until you apply them.")
            if session.image.canTransform {
                ImageGeometryControls(session: session)
            } else if let reason = session.image.unsupportedReason {
                note(reason)
            }
            // Side by side when the column allows, stacked when it doesn't.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.snug) { applyButtons }
                VStack(alignment: .leading, spacing: Spacing.snug) { applyButtons }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.snug) {
                    showOnPage
                    Spacer(minLength: Spacing.snug)
                    removeImage
                }
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    showOnPage
                    removeImage
                }
            }
            .buttonStyle(.quiet)
        }
        .onChange(of: session.bounds) { model.previewSelectedImageBounds() }
    }

    @ViewBuilder
    private var applyButtons: some View {
        Button("Apply image changes") { model.applyImageChanges() }
            .buttonStyle(.borderedProminent)
            .disabled(!session.hasChanges || !session.geometryIsValid || !model.imageEditIsCurrent || model.isProcessing)
        if session.hasChanges || !model.imageEditIsCurrent {
            Button("Discard changes") { model.discardImageChanges() }
        }
    }

    private var showOnPage: some View {
        Button("Show on page", systemImage: "scope", action: model.revealSelectedImage)
            .disabled(!model.imageEditIsCurrent)
    }

    private var removeImage: some View {
        Button("Remove image", systemImage: "trash", role: .destructive) { model.removeSelectedImage() }
            .disabled(!model.imageEditIsCurrent || model.isProcessing)
    }

    /// An explanation: supporting size, secondary, wrapping.
    private func note(_ text: String) -> some View {
        Text(text).font(Typography.supporting).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
