import AnnotateCore
import AppKit
import PDFKit
import UniformTypeIdentifiers

extension ReaderModel {
    func movePage(_ page: Int, to destination: Int) {
        mutatePDF("Move Page") { try PDFPageOrganizer.move($0, page: page, to: destination) }
        goToPage(destination + 1)
    }

    func rotatePages(_ pages: IndexSet, clockwise: Bool) {
        mutatePDF("Rotate Pages") { try PDFPageOrganizer.rotate($0, pages: pages, clockwise: clockwise) }
    }

    func deletePages(_ pages: IndexSet) {
        mutatePDF("Delete Pages") { try PDFPageOrganizer.delete($0, pages: pages) }
    }

    func insertBlankPage() {
        let insertion = min(pageNumber, pageCount)
        let size = pdfDocument?.page(at: max(0, pageNumber - 1))?.bounds(for: .mediaBox).size ?? CGSize(width: 612, height: 792)
        mutatePDF("Insert Blank Page") { try PDFPageOrganizer.insertBlank(into: $0, at: insertion, size: size) }
        goToPage(insertion + 1)
    }

    func importPages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        panel.message = "Insert PDFs or images after the current page. Files are inserted in the selected order."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        let insertion = min(pageNumber, pageCount)
        mutatePDF("Insert Pages") { document in
            var index = insertion
            for url in urls {
                if let source = PDFDocument(url: url), source.pageCount > 0 {
                    let count = source.pageCount
                    try PDFPageOrganizer.insert(source, into: document, at: index)
                    index += count
                } else if let image = NSImage(contentsOf: url) {
                    try PDFPageOrganizer.insertImages([image], into: document, at: index)
                    index += 1
                } else { throw PDFPageOperationError.invalidImage }
            }
        }
    }

    func extractPages(_ pages: IndexSet) {
        guard let document = pdfDocument else { return }
        do {
            let output = try PDFPageOrganizer.extract(document, pages: pages)
            guard let data = output.dataRepresentation() else { throw AnnotateError.exportFailed }
            saveOutput(data: data, suggestedName: (fileName as NSString).deletingPathExtension + " — Extracted.pdf", contentType: .pdf)
        } catch { errorMessage = error.localizedDescription }
    }

    func splitPages(every count: Int) {
        guard let document = pdfDocument else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose a folder. Split PDFs are saved in a new subfolder."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        performOperation("Splitting PDF") {
            let parts = try PDFPageOrganizer.split(document, every: count)
            let name = (self.fileName as NSString).deletingPathExtension
            var destination = folder.appending(path: name + " — Split", directoryHint: .isDirectory)
            var suffix = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = folder.appending(path: "\(name) — Split \(suffix)", directoryHint: .isDirectory)
                suffix += 1
            }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            do {
                for (index, part) in parts.enumerated() {
                    guard let data = part.dataRepresentation() else { throw AnnotateError.exportFailed }
                    try data.write(to: destination.appending(path: "\(name) — Part \(index + 1).pdf"), options: .atomic)
                }
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            self.statusMessage = "Saved \(parts.count) PDFs"
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    func createFormField(name: String, kind: PDFFormKind, choices: [String], exportValue: String, multiline: Bool, region: PageRegion) {
        mutatePDF("Create Form Field") {
            try PDFFormEditor.create(in: $0, region: region, name: name, kind: kind, choices: choices, exportValue: exportValue, multiline: multiline)
        }
    }

    func fillFormField(_ field: PDFFormField, value: String) {
        mutatePDF("Fill Form Field") { try PDFFormEditor.fill(in: $0, field: field, value: value) }
    }

    func removeFormField(_ field: PDFFormField) {
        mutatePDF("Remove Form Field") { try PDFFormEditor.remove(in: $0, field: field) }
    }

    /// Fractions of the page as displayed after crop and rotation, measured from the top-left.
    func placementRegion(page index: Int, left: Double, top: Double, width: Double, height: Double) -> PageRegion? {
        guard let page = pdfDocument?.page(at: index), [left, top, width, height].allSatisfy(\.isFinite),
              left >= 0, top >= 0, width > 0, height > 0, left + width <= 1.00001, top + height <= 1.00001 else { return nil }
        let transform = page.transform(for: .cropBox)
        let crop = page.bounds(for: .cropBox).applying(transform)
        let displayed = CGRect(x: crop.minX + left * crop.width, y: crop.maxY - (top + height) * crop.height,
                               width: width * crop.width, height: height * crop.height)
        return PageRegion(pageIndex: index, bounds: displayed.applying(transform.inverted()))
    }
}
