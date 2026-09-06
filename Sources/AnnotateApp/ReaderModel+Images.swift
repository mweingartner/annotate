import AnnotateCore
import AppKit
import PDFKit

extension ReaderModel {
    var hasPendingImageChanges: Bool { imageEdit?.hasChanges == true }
    var imageEditIsCurrent: Bool {
        guard let edit = imageEdit else { return false }
        return edit.source === pdfDocument && edit.sourceRevision == documentRevision
    }

    func imagesOnCurrentPage() throws -> [PDFNativeImage] {
        guard let document = pdfDocument else { return [] }
        return try PDFNativeImageEditor.images(in: document, pageIndex: pageNumber - 1)
    }

    func selectImage(_ image: PDFNativeImage, preview: NSImage? = nil) {
        guard !isProcessing, let document = pdfDocument,
              let page = document.page(at: image.pageIndex) else { return }
        if imageEdit?.image.id == image.id, imageEditIsCurrent {
            revealSelectedImage(); return
        }
        guard !hasPendingImageChanges else {
            errorMessage = "Apply or discard the pending image changes before selecting another image."
            return
        }
        guard !hasDraftChanges else {
            errorMessage = "Save or discard the pending marker before editing an image."
            return
        }
        guard finishLiveText() else { return }
        imageEdit = ImageEditSession(image: image, source: document, revision: documentRevision,
            pageBounds: page.bounds(for: .cropBox), preview: preview)
        activeTool = .edit
        selectingToolArea = false
        revealSelectedImage()
    }

    func revealSelectedImage() {
        guard let edit = imageEdit, imageEditIsCurrent,
              let page = pdfDocument?.page(at: edit.image.pageIndex) else { return }
        suppressSelection = true
        pdfView?.clearSelection()
        pdfView?.go(to: edit.image.bounds.insetBy(dx: -20, dy: -20), on: page)
        suppressSelection = false
        pageNumber = edit.image.pageIndex + 1
        previewSelectedImageBounds()
    }

    func previewSelectedImageBounds() {
        guard let edit = imageEdit, imageEditIsCurrent else { return }
        toolSelection = PageRegion(pageIndex: edit.image.pageIndex,
                                   bounds: edit.geometryIsValid ? edit.bounds : edit.image.bounds)
        pdfView?.updateAreaOutline()
    }

    func chooseImageReplacement() {
        guard imageEdit != nil, !isProcessing else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "The replacement fills the selected image’s frame. Apply commits the change."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            errorMessage = "The selected image could not be opened. Choose another image file."
            return
        }
        imageEdit?.stageReplacement(image, name: url.lastPathComponent)
    }

    @discardableResult
    func applyImageChanges() -> Bool {
        guard let edit = imageEdit, edit.hasChanges, prepareImageMutation() else { return false }
        guard edit.geometryIsValid else {
            errorMessage = "Keep the image within the page, at least 1 pt wide and high."
            return false
        }
        do {
            guard let source = pdfDocument else { return false }
            let result = try PDFNativeImageEditor.update(in: source, image: edit.image,
                bounds: edit.geometryChanged ? edit.bounds : nil, replacement: edit.replacement)
            replacePDF(result, actionName: edit.replacement == nil ? "Move or Resize Image" : "Replace Image")
            guard pdfDocument === result else { return false }
            imageEdit = nil
            errorMessage = nil
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    @discardableResult
    func removeSelectedImage() -> Bool {
        guard let edit = imageEdit, prepareImageMutation() else { return false }
        do {
            guard let source = pdfDocument else { return false }
            let result = try PDFNativeImageEditor.remove(in: source, image: edit.image)
            replacePDF(result, actionName: "Remove Image")
            guard pdfDocument === result else { return false }
            imageEdit = nil
            errorMessage = nil
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func discardImageChanges() {
        imageEdit = nil
        if liveEdit == nil { toolSelection = nil; pdfView?.updateAreaOutline() }
    }

    private func prepareImageMutation() -> Bool {
        guard !isProcessing, imageEdit != nil else { return false }
        guard imageEditIsCurrent else {
            errorMessage = "The PDF changed after this image was selected. Discard these pending image controls and select the image again."
            return false
        }
        guard !hasDraftChanges else {
            errorMessage = "Save or discard the pending marker before applying image changes."
            return false
        }
        guard finishLiveText() else { return false }
        guard pdfDocument?.allowsDocumentChanges == true else {
            errorMessage = "This PDF does not allow changes to its images."
            return false
        }
        return true
    }
}
