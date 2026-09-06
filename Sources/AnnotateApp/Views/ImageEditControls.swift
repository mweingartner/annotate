import AppKit
import SwiftUI

struct ImageEditControls: View {
    @Bindable var model: ReaderModel
    @Bindable var session: ImageEditSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Selected image · Page \(session.image.pageIndex + 1)").font(.headline)
                Spacer()
                Button("Deselect image", systemImage: "xmark") { model.discardImageChanges() }
                    .labelStyle(.iconOnly)
                    .disabled(session.hasChanges)
            }
            if !model.imageEditIsCurrent {
                Label("The PDF has changed. Discard these controls and select the image again.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let replacement = session.replacement {
                Image(nsImage: NSImage(cgImage: replacement, size: NSSize(width: replacement.width, height: replacement.height)))
                    .resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 110)
                    .background(.white, in: RoundedRectangle(cornerRadius: 6))
                Text(session.replacementName ?? "Replacement image").font(.caption).lineLimit(2)
            }
            Button("Choose replacement…", systemImage: "photo.on.rectangle", action: model.chooseImageReplacement)
                .disabled(!model.imageEditIsCurrent || model.isProcessing)
            Text("The replacement fills the current frame. Changes stay pending until you apply them.")
                .font(.caption).foregroundStyle(.secondary)
            if session.image.canTransform {
                ImageGeometryControls(session: session)
            } else if let reason = session.image.unsupportedReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Apply image changes") { model.applyImageChanges() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.hasChanges || !session.geometryIsValid || !model.imageEditIsCurrent || model.isProcessing)
                if session.hasChanges || !model.imageEditIsCurrent {
                    Button("Discard changes") { model.discardImageChanges() }
                }
            }
            HStack {
                Button("Show on page", systemImage: "scope", action: model.revealSelectedImage)
                    .disabled(!model.imageEditIsCurrent)
                Spacer()
                Button("Remove image", systemImage: "trash", role: .destructive) { model.removeSelectedImage() }
                    .disabled(!model.imageEditIsCurrent || model.isProcessing)
            }.controlSize(.small)
        }
        .onChange(of: session.bounds) { model.previewSelectedImageBounds() }
    }
}
