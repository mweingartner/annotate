import AnnotateCore
import AppKit
import SwiftUI

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
            HStack(spacing: 10) {
                Group {
                    if let preview { Image(nsImage: preview).resizable().scaledToFit() }
                    else { Image(systemName: "photo").foregroundStyle(.gray) }
                }
                .frame(width: 64, height: 48)
                .background(.white, in: RoundedRectangle(cornerRadius: 4))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Image \(number)").font(.callout.weight(.medium))
                    Text("\(pixelWidth) × \(pixelHeight) pixels")
                        .font(.caption).foregroundStyle(.secondary)
                    if !image.canTransform {
                        Text("Replace or remove in place").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
            }
            .padding(8)
            .contentShape(.rect)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
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
