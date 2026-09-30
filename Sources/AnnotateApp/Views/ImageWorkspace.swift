import AnnotateCore
import Atrium
import SwiftUI

/// The source images on the current page, and the controls for the one being edited.
struct ImageWorkspace: View {
    @Bindable var model: ReaderModel
    @State private var images: [PDFNativeImage] = []
    @State private var listError: String?
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup("Images on page \(model.pageNumber)", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: Spacing.control) {
                if let listError {
                    Label(listError, systemImage: "exclamationmark.triangle")
                        .font(Typography.supporting).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if images.isEmpty {
                    note("No source images found on this page. Vector drawings and text are separate PDF content.")
                } else {
                    note("Choose an image to locate it on the page and edit its source content.")
                    LazyVStack(spacing: 0) {
                        ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                            if index > 0 { Hairline() }
                            ImageSelectionRow(model: model, image: image, number: index + 1)
                                .padding(.vertical, Spacing.hair)
                        }
                    }
                }
                if let edit = model.imageEdit {
                    Hairline()
                    ImageEditControls(model: model, session: edit)
                        .id("\(edit.image.id):\(edit.sourceRevision)")
                }
            }.padding(.top, Spacing.snug)
        }
        .onAppear(perform: refresh)
        .onChange(of: model.pageNumber) { refresh() }
        .onChange(of: model.documentRevision) { refresh() }
    }

    /// An explanation: supporting size, secondary, wrapping.
    private func note(_ text: String) -> some View {
        Text(text).font(Typography.supporting).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func refresh() {
        do { images = try model.imagesOnCurrentPage(); listError = nil }
        catch { images = []; listError = error.localizedDescription }
    }
}
