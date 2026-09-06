import AnnotateCore
import AppKit
import PDFKit
import Testing
@testable import AnnotateApp

@Suite("Workspace editing regressions", .serialized)
@MainActor
struct WorkspaceReviewTests {
    @Test("Live editor follows the native PDF text coordinate basis at every rotation and zoom", arguments: [0, 90, 180, 270], [0.7, 1.4])
    func liveEditorGeometry(rotation: Int, scale: Double) throws {
        _ = NSApplication.shared
        let pdf = SamplePDF.make()
        let page = try #require(pdf.page(at: 0))
        page.setBounds(CGRect(x: 30, y: 50, width: 500, height: 650), for: .cropBox)
        page.rotation = rotation
        let owner = AnnotateDocument()
        owner.model.load(pdf, owner: owner)
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 1200, height: 1200))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(view)
        view.displayMode = .singlePage
        view.displayBox = .cropBox
        view.document = pdf
        view.autoScales = false
        view.scaleFactor = scale
        view.model = owner.model
        owner.model.pdfView = view
        view.layoutDocumentView()
        view.layoutSubtreeIfNeeded()
        let bounds = CGRect(x: 80, y: 220, width: 190, height: 60)
        owner.model.liveEdit = LiveTextEdit(identifier: "geometry", pageIndex: 0, text: "Coordinate sentinel", font: .systemFont(ofSize: 14), color: .black, bounds: bounds)
        view.refreshLiveEditor()
        let field = try #require(view.liveTextView)
        let host = try #require(view.documentView)
        for (local, pagePoint) in [
            (CGPoint.zero, CGPoint(x: bounds.minX, y: bounds.maxY)),
            (CGPoint(x: field.bounds.maxX, y: 0), CGPoint(x: bounds.maxX, y: bounds.maxY)),
            (CGPoint(x: 0, y: field.bounds.maxY), CGPoint(x: bounds.minX, y: bounds.minY))
        ] {
            let actual = field.convert(local, to: host)
            let expected = host.convert(view.convert(pagePoint, from: page), from: view)
            #expect(abs(actual.x - expected.x) < 0.5)
            #expect(abs(actual.y - expected.y) < 0.5)
        }
    }

    @Test("A blocked mutation cannot create a live editor detached from the PDF")
    func busyDoesNotStartEditor() throws {
        _ = NSApplication.shared
        let owner = AnnotateDocument()
        let pdf = SamplePDF.make()
        owner.model.load(pdf, owner: owner)
        let region = PageRegion(pageIndex: 0, bounds: CGRect(x: 80, y: 200, width: 180, height: 50))
        let annotation = try PDFContentEditor.addText("Original text", in: region, document: pdf, font: .systemFont(ofSize: 14), color: .black)
        let originalID = annotation.value(forAnnotationKey: PDFContentEditor.editIDKey) as? String
        owner.model.isProcessing = true
        owner.model.editTextAnnotation(annotation, page: try #require(pdf.page(at: 0)))
        #expect(owner.model.liveEdit == nil)
        #expect(annotation.value(forAnnotationKey: PDFContentEditor.editIDKey) as? String == originalID)
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 900))
        view.document = pdf; view.model = owner.model; owner.model.pdfView = view
        let selection = try #require(pdf.findString("A place for your attention", withOptions: []).first)
        view.setCurrentSelection(selection, animate: false)
        owner.model.beginLiveText(replacingSelection: true)
        #expect(owner.model.liveEdit == nil)
        #expect(owner.model.pdfDocument === pdf)
        #expect(pdf.findString("A place for your attention", withOptions: []).count == 1)
    }

    @Test("Read-only PDFs cannot acquire editable text through a serialized mutation")
    func readOnlyCannotEdit() throws {
        _ = NSApplication.shared
        let source = SamplePDF.make()
        let location = FileManager.default.temporaryDirectory.appending(path: "workspace-permissions-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: location) }
        #expect(source.write(to: location, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "reader", .accessPermissionsOption: 0]))
        let pdf = try #require(PDFDocument(url: location))
        #expect(pdf.unlock(withPassword: "reader"))
        let owner = AnnotateDocument()
        owner.model.load(pdf, owner: owner)
        owner.model.beginLiveText(replacingSelection: false)
        #expect(owner.model.liveEdit == nil)
        #expect(owner.model.pdfDocument === pdf)
        #expect(pdf.page(at: 0)?.annotations.isEmpty == true)
    }

    @Test("Live text controls detect visual overflow while retaining the complete input")
    func detectsOverflow() {
        let session = LiveTextEdit(identifier: "overflow", pageIndex: 0, text: "One line", font: .systemFont(ofSize: 12), color: .black,
                                   bounds: CGRect(x: 20, y: 20, width: 200, height: 50))
        #expect(!session.textOverflows)
        session.text = (0..<20).map { "Line \($0)" }.joined(separator: "\n")
        #expect(session.textOverflows)
        #expect(session.text.contains("Line 19"))
        session.height = 500
        #expect(!session.textOverflows)
    }
}
