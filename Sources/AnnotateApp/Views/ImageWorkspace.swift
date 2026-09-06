import AnnotateCore
import SwiftUI

struct ImageWorkspace: View {
    @Bindable var model: ReaderModel
    @State private var images: [PDFNativeImage] = []
    @State private var listError: String?
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup("Images on page \(model.pageNumber)", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if let listError {
                    Label(listError, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                } else if images.isEmpty {
                    Text("No source images found on this page. Vector drawings and text are separate PDF content.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Choose an image to locate it on the page and edit its source content.")
                        .font(.caption).foregroundStyle(.secondary)
                    LazyVStack(spacing: 6) {
                        ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                            ImageSelectionRow(model: model, image: image, number: index + 1)
                        }
                    }
                }
                if let edit = model.imageEdit {
                    Divider()
                    ImageEditControls(model: model, session: edit)
                        .id("\(edit.image.id):\(edit.sourceRevision)")
                }
            }.padding(.top, 10)
        }
        .onAppear(perform: refresh)
        .onChange(of: model.pageNumber) { refresh() }
        .onChange(of: model.documentRevision) { refresh() }
    }

    private func refresh() {
        do { images = try model.imagesOnCurrentPage(); listError = nil }
        catch { images = []; listError = error.localizedDescription }
    }
}
