import AnnotateCore
import AppKit
import Atrium
import SwiftUI

/// One source image on the page: a preview, its pixel size, and a check when selected.
struct ImageSelectionRow: View {
    @Bindable var model: ReaderModel
    let image: PDFNativeImage
    let number: Int
    @State private var preview: NSImage?

    private var isSelected: Bool { model.imageEdit?.image.id == image.id && model.imageEditIsCurrent }
    private var pixelWidth: String { Double(image.pixelSize.width).formatted(.number.precision(.fractionLength(0))) }
    private var pixelHeight: String { Double(image.pixelSize.height).formatted(.number.precision(.fractionLength(0))) }

    var body: some View {
        Button {
            model.selectImage(image, preview: preview)
        } label: {
            HStack(spacing: Spacing.snug) {
                Group {
                    if let preview { Image(nsImage: preview).resizable().scaledToFit() }
                    else { Image(systemName: "photo").foregroundStyle(.gray) }
                }
                .frame(width: Metrics.control * 2, height: Metrics.doubleRow)
                // The preview is page content, so it sits on paper in either appearance.
                .background(.white, in: .rect(cornerRadius: Radius.badge))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text("Image \(number)").font(Typography.body)
                    Text("\(pixelWidth) × \(pixelHeight) pixels")
                        .font(Typography.meta).foregroundStyle(.secondary)
                    if !image.canTransform {
                        Text("Replace or remove in place").font(Typography.meta).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
            }
            .padding(.vertical, Spacing.tight)
            .contentShape(.rect)
        }
        .buttonStyle(.quiet)
        // Selection is the one persistent fill; hover and press washes come from the style.
        .background(isSelected ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: Radius.field))
        .disabled(model.isProcessing)
        .accessibilityLabel("Image \(number), \(pixelWidth) by \(pixelHeight) pixels")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help("Select and locate this image. The thumbnail previews its page area, including any overlapping content.")
        // A document revision can arrive before the parent's image list refresh.
        // The descriptor includes the source fingerprint, so task identity follows
        // the actual image data while the list keeps stable selection identifiers.
        .task(id: image) {
            guard let document = model.pdfDocument,
                  let bitmap = try? PDFNativeImageEditor.preview(in: document, image: image, maximumDimension: 160) else {
                preview = nil; return
            }
            preview = NSImage(cgImage: bitmap, size: NSSize(width: bitmap.width, height: bitmap.height))
        }
    }
}
