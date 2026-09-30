import AnnotateCore
import Atrium
import PDFKit
import SwiftUI

/// The Edit inspector. With no text open it explains how to start and holds the other
/// editing tools; while text is being edited it holds that text's full formatting.
struct EditPanel: View {
    @Bindable var model: ReaderModel
    @State private var ink = Color.black

    var body: some View {
        if let session = model.liveEdit {
            LiveTextControls(model: model, session: session)
                .id(session.identifier)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                PageSection("Text") {
                    PDFTextActions(model: model)
                        .disabled(model.hasPendingImageChanges)
                }
                PageSection("Images") {
                    ImageWorkspace(model: model)
                    Button("Insert Image…", systemImage: "photo.badge.plus", action: insertImage)
                        .disabled(model.pdfDocument?.allowsDocumentChanges != true)
                        .help("Place an image in the chosen area, or on the current page")
                        .padding(.top, Spacing.snug)
                }
                PageSection("Area") {
                    Text("Choose where a new text box or image goes.")
                        .font(Typography.supporting)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, Spacing.snug)
                    AreaSelectionControls(model: model)
                }
                PageSection("Markup") {
                    ColorPicker("Ink color", selection: $ink, supportsOpacity: false)
                        .padding(.bottom, Spacing.snug)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.inspector.min / 2), alignment: .leading)],
                              alignment: .leading, spacing: Spacing.snug) {
                        PDFMarkupButton(model: model, title: "Highlight", icon: "highlighter", type: .highlight, color: ink)
                        PDFMarkupButton(model: model, title: "Underline", icon: "underline", type: .underline, color: ink)
                        PDFMarkupButton(model: model, title: "Strikeout", icon: "strikethrough", type: .strikeOut, color: ink)
                        PDFMarkupButton(model: model, title: "Rectangle", icon: "rectangle", type: .square, color: ink)
                        PDFMarkupButton(model: model, title: "Ellipse", icon: "oval", type: .circle, color: ink)
                    }
                    .disabled(!model.canEdit)
                }
            }
        }
    }

    private func insertImage() {
        guard let region = model.toolSelection ?? model.defaultToolArea() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = NSImage(contentsOf: url) else {
            model.errorMessage = "The selected image could not be opened. Choose another image file."
            return
        }
        model.mutatePDF("Insert Image") { working in
            try PDFSignatureEditor.image(image, in: working, regions: [region])
        }
    }
}
