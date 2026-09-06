import AnnotateCore
import PDFKit
import SwiftUI

struct EditPanel: View {
    @Bindable var model: ReaderModel
    @State private var ink = Color.black
    @State private var showPlacement = false
    @State private var showMarkup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let session = model.liveEdit {
                LiveTextControls(model: model, session: session)
                    .id(session.identifier)
            } else {
                Text("Edit PDF").font(.title2.bold())
                PDFTextActions(model: model)
                    .disabled(model.hasPendingImageChanges)
                Divider()
                ImageWorkspace(model: model)
                Divider()
                DisclosureGroup("Choose an area", isExpanded: $showPlacement) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Place a new text box, image, or shape in the area you choose.")
                            .font(.caption).foregroundStyle(.secondary)
                        AreaSelectionControls(model: model)
                    }.padding(.top, 8)
                }
                Button("Insert image…", systemImage: "photo.badge.plus", action: insertImage)
                    .disabled(model.pdfDocument?.allowsDocumentChanges != true)
                Divider()
                DisclosureGroup("Markup & shapes", isExpanded: $showMarkup) {
                    VStack(alignment: .leading, spacing: 12) {
                        ColorPicker("Ink color", selection: $ink, supportsOpacity: false)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                            PDFMarkupButton(model: model, title: "Highlight", icon: "highlighter", type: .highlight, color: ink)
                            PDFMarkupButton(model: model, title: "Underline", icon: "underline", type: .underline, color: ink)
                            PDFMarkupButton(model: model, title: "Strikeout", icon: "strikethrough", type: .strikeOut, color: ink)
                            PDFMarkupButton(model: model, title: "Rectangle", icon: "rectangle", type: .square, color: ink)
                            PDFMarkupButton(model: model, title: "Ellipse", icon: "oval", type: .circle, color: ink)
                        }
                    }
                    .padding(.top, 10)
                    .disabled(!model.canEdit)
                }
            }
        }
        .buttonStyle(.bordered)
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
