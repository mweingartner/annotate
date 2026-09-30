import AnnotateCore
import Atrium
import SwiftUI
import UniformTypeIdentifiers

/// The Sign inspector: make a visible signature, place it, then optionally sign a copy
/// with a certificate.
struct SignaturesPanel: View {
    @Bindable var model: ReaderModel
    @State private var method = SignatureMethod.type
    @State private var name = ""
    @State private var strokes: [[CGPoint]] = []
    @State private var image: NSImage?
    @State private var left = 10.0
    @State private var top = 80.0
    @State private var width = 35.0
    @State private var height = 8.0
    @State private var range = ""
    @State private var currentOnly = true
    @State private var useSelection = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageSection("Electronic signature") {
                VStack(alignment: .leading, spacing: Spacing.control) {
                    Picker("Signature method", selection: $method) {
                        ForEach(SignatureMethod.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    switch method {
                    case .type:
                        TextField("Type your name", text: $name)
                            .accessibilityLabel("Typed signature")
                        Text(name.isEmpty ? "Your signature" : name)
                            .font(.custom("SnellRoundhand", size: 30, relativeTo: .title))
                            .frame(maxWidth: .infinity, minHeight: Metrics.doubleRow * 2)
                            .padding(Spacing.snug)
                            .background(.background, in: .rect(cornerRadius: Radius.field))
                            .overlay { RoundedRectangle(cornerRadius: Radius.field).strokeBorder(Palette.hairline) }
                    case .draw:
                        SignatureDrawingPad(strokes: $strokes)
                        Button("Clear drawing", systemImage: "eraser") { strokes = [] }
                    case .image:
                        Button("Choose signature image…", systemImage: "photo", action: chooseImage)
                        if let image {
                            Image(nsImage: image).resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: SignatureDrawingPad.height)
                                .accessibilityLabel("Uploaded signature preview")
                        }
                    }
                }
            }
            PageSection("Placement") {
                VStack(alignment: .leading, spacing: Spacing.control) {
                    Toggle("Current page only", isOn: $currentOnly)
                    if !currentOnly { TextField("Pages: all, 1, 3–5", text: $range) }
                    Toggle("Use selected PDF area when available", isOn: $useSelection)
                    Button(model.selectingToolArea ? "Cancel area selection" : "Draw an area on the PDF", systemImage: "selection.pin.in.out") { model.selectingToolArea.toggle() }
                    SignaturePlacementFields(left: $left, top: $top, width: $width, height: $height)
                    Text("Drag an area on the PDF, or enter position and size above before placing.")
                        .font(Typography.supporting).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Place signature", systemImage: "signature", action: place).buttonStyle(.borderedProminent)
                    Text("A visible signature is placed on the page. To protect the finished document with a certificate, sign a copy below.")
                        .font(Typography.supporting).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            CertificateSignaturePanel(model: model)
        }
        .disabled(model.isProcessing)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let loaded = NSImage(contentsOf: url) else { model.errorMessage = PDFSignatureError.invalidImage.localizedDescription; return }
        image = loaded
    }

    private func place() {
        do {
            let pages = try currentOnly ? IndexSet(integer: model.pageNumber - 1) : PDFPageRange.parse(range, pageCount: model.pageCount)
            let regions: [PageRegion]
            if useSelection, currentOnly, let selected = model.toolSelection { regions = [selected] }
            else {
                regions = try pages.map { index in
                    guard let region = model.placementRegion(page: index, left: left / 100, top: top / 100, width: width / 100, height: height / 100) else {
                        throw PDFFormError.invalidBounds
                    }
                    return region
                }
            }
            model.mutatePDF("Place Electronic Signature") { document in
                switch method {
                case .type: try PDFSignatureEditor.typed(name, in: document, regions: regions)
                case .draw: try PDFSignatureEditor.drawn(strokes, in: document, regions: regions)
                case .image:
                    guard let image else { throw PDFSignatureError.invalidImage }
                    try PDFSignatureEditor.image(image, in: document, regions: regions)
                }
            }
        } catch { model.errorMessage = error.localizedDescription }
    }
}
