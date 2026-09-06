import AnnotateCore
import AppKit
import PDFKit
import Testing
@testable import AnnotateApp

@Suite("Native PDF form tracking", .serialized)
@MainActor
struct NativeFormTrackingTests {
    @Test("Native widget value changes mark the document, invalidate derived content, save, undo and redo")
    func textValueRoundTrip() async throws {
        let (owner, view) = try fixture()
        let model = owner.model
        let document = try #require(model.pdfDocument)
        let widget = try annotation("FullName", in: document)
        let undo = try #require(owner.undoManager)
        undo.groupsByEvent = false
        #expect(!owner.isDocumentEdited)
        let revision = model.documentRevision
        undo.beginUndoGrouping()
        widget.widgetStringValue = "Native canvas text 824"
        undo.endUndoGrouping()
        try await Task.sleep(for: .milliseconds(60))
        #expect(owner.isDocumentEdited)
        #expect(model.documentRevision > revision)
        #expect(undo.canUndo)
        let saved = try #require(PDFDocument(data: owner.data(ofType: "com.adobe.pdf")))
        #expect(try annotation("FullName", in: saved).widgetStringValue == "Native canvas text 824")
        undo.undo()
        #expect(widget.widgetStringValue == "")
        #expect(model.pdfDocument === document)
        try await Task.sleep(for: .milliseconds(60))
        #expect(!owner.isDocumentEdited)
        undo.redo()
        #expect(widget.widgetStringValue == "Native canvas text 824")
        withExtendedLifetime(view) {}
    }

    @Test("Native checkbox and choice changes have value undo", arguments: [PDFFormKind.checkbox, .choice, .list])
    func buttonAndChoice(kind: PDFFormKind) async throws {
        let (owner, view) = try fixture()
        let document = try #require(owner.model.pdfDocument)
        let widget = try annotation(kind == .checkbox ? "Agreed" : "Category", in: document)
        let undo = try #require(owner.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        if kind == .checkbox { widget.buttonWidgetState = .onState }
        else { widget.widgetStringValue = "Second" }
        undo.endUndoGrouping()
        try await Task.sleep(for: .milliseconds(60))
        #expect(owner.isDocumentEdited)
        #expect(owner.model.documentRevision > 0)
        undo.undo()
        if kind == .checkbox { #expect(widget.buttonWidgetState == .offState) }
        else { #expect(widget.widgetStringValue == "First") }
        undo.redo()
        if kind == .checkbox { #expect(widget.buttonWidgetState == .onState) }
        else { #expect(widget.widgetStringValue == "Second") }
        withExtendedLifetime(view) {}
    }

    @Test("A scoped native field-editor notification saves its visible buffer before focus changes")
    func activeEditorBuffer() async throws {
        let (owner, view) = try fixture()
        let widget = try annotation("FullName", in: #require(owner.model.pdfDocument))
        NotificationCenter.default.post(name: .PDFViewAnnotationHit, object: view, userInfo: ["PDFAnnotationHit": widget])
        let editor = NSTextView(frame: view.convert(widget.bounds, from: try #require(widget.page)))
        view.addSubview(editor)
        let undo = try #require(owner.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.string = "Still focused buffer"
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: editor)
        undo.endUndoGrouping()
        #expect(widget.widgetStringValue == "Still focused buffer")
        try await Task.sleep(for: .milliseconds(60))
        #expect(owner.isDocumentEdited)
        let saved = try #require(PDFDocument(data: owner.data(ofType: "com.adobe.pdf")))
        #expect(try annotation("FullName", in: saved).widgetStringValue == "Still focused buffer")
        undo.undo()
        #expect(widget.widgetStringValue == "")
        #expect(editor.string == "")
        NotificationCenter.default.post(name: NSText.didEndEditingNotification, object: editor)
        #expect(widget.widgetStringValue == "")
    }

    @Test("A keyboard-focused editor updates its own field despite a stale annotation click")
    func tabbedEditorOwnership() throws {
        let (owner, view) = try fixture()
        let document = try #require(owner.model.pdfDocument)
        let original = try annotation("FullName", in: document)
        try PDFFormEditor.create(in: document, region: PageRegion(pageIndex: 0, bounds: CGRect(x: 70, y: 200, width: 200, height: 30)), name: "SecondName", kind: .text)
        let target = try annotation("SecondName", in: document)
        NotificationCenter.default.post(name: .PDFViewAnnotationHit, object: view, userInfo: ["PDFAnnotationHit": original])
        let editor = NSTextView(frame: view.convert(target.bounds, from: try #require(target.page)))
        view.addSubview(editor)
        editor.string = "Keyboard focused field"
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: editor)
        #expect(target.widgetStringValue == "Keyboard focused field")
        #expect(original.widgetStringValue == "")
    }

    @Test("Selecting PDF text and editing another view never changes form state or marks the PDF dirty")
    func unrelatedEvents() throws {
        let (owner, view) = try fixture()
        let document = try #require(owner.model.pdfDocument)
        let widget = try annotation("FullName", in: document)
        NotificationCenter.default.post(name: .PDFViewAnnotationHit, object: view, userInfo: ["PDFAnnotationHit": widget])
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: view)
        let unrelated = NSTextView()
        unrelated.string = "Another window's text"
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: unrelated)
        view.annotationsChanged(on: try #require(document.page(at: 0)))
        #expect(widget.widgetStringValue == "")
        #expect(!owner.isDocumentEdited)
        #expect(owner.model.documentRevision == 0)
        #expect(owner.undoManager?.canUndo == false)
    }

    @Test("Replacing a PDF detaches its old widget observers without creating an extra form edit")
    func replacementIsolation() throws {
        let (owner, view) = try fixture()
        let old = try annotation("FullName", in: #require(owner.model.pdfDocument))
        let replacement = SamplePDF.make()
        let undo = try #require(owner.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        owner.model.replacePDF(replacement, actionName: "Replace document")
        undo.endUndoGrouping()
        let revision = owner.model.documentRevision
        old.widgetStringValue = "Stale document edit"
        #expect(owner.model.documentRevision == revision)
        #expect(owner.model.pdfDocument === replacement)
        withExtendedLifetime(view) {}
    }

    @Test("Loaded and replaced radio widgets retain on-state names, native selection and undo")
    func radioOptionRefresh() throws {
        _ = NSApplication.shared
        let source = SamplePDF.make()
        for (index, option) in ["Alpha", "Beta"].enumerated() {
            try PDFFormEditor.create(in: source,
                region: PageRegion(pageIndex: 0, bounds: CGRect(x: 80 + index * 40, y: 180, width: 24, height: 24)),
                name: "RadioChoice", kind: .radio, exportValue: option)
        }
        let originalData = try #require(source.dataRepresentation())
        let reopened = try #require(PDFDocument(data: originalData))
        let owner = AnnotateDocument()
        owner.model.load(reopened, owner: owner)
        var fields = PDFFormEditor.fields(in: reopened).filter { $0.name == "RadioChoice" }
        #expect(fields.map(\.exportValue) == ["Alpha", "Beta"])
        for field in fields {
            #expect(reopened.page(at: field.pageIndex)?.annotations[field.annotationIndex].buttonWidgetStateString == field.exportValue)
        }
        let view = SelectionPDFView()
        view.document = reopened
        view.model = owner.model
        owner.model.pdfView = view
        let undo = try #require(owner.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let first = try #require(reopened.page(at: 0)?.annotations[fields[0].annotationIndex])
        first.buttonWidgetState = .onState
        undo.endUndoGrouping()
        #expect(PDFFormEditor.fields(in: reopened).first { $0.exportValue == "Alpha" }?.checked == true)
        undo.undo()
        #expect(PDFFormEditor.fields(in: reopened).allSatisfy { !$0.checked })
        undo.redo()
        #expect(PDFFormEditor.fields(in: reopened).first { $0.exportValue == "Alpha" }?.checked == true)
        let replacementData = try #require(reopened.dataRepresentation())
        let replacement = try #require(PDFDocument(data: replacementData))
        undo.beginUndoGrouping()
        owner.model.replacePDF(replacement, actionName: "Replace radios")
        undo.endUndoGrouping()
        fields = PDFFormEditor.fields(in: replacement).filter { $0.name == "RadioChoice" }
        for field in fields {
            #expect(replacement.page(at: field.pageIndex)?.annotations[field.annotationIndex].buttonWidgetStateString == field.exportValue)
        }
    }

    private func fixture() throws -> (AnnotateDocument, SelectionPDFView) {
        _ = NSApplication.shared
        let document = SamplePDF.make()
        try PDFFormEditor.create(in: document, region: PageRegion(pageIndex: 0, bounds: CGRect(x: 70, y: 80, width: 200, height: 30)), name: "FullName", kind: .text)
        try PDFFormEditor.create(in: document, region: PageRegion(pageIndex: 0, bounds: CGRect(x: 300, y: 80, width: 20, height: 20)), name: "Agreed", kind: .checkbox)
        try PDFFormEditor.create(in: document, region: PageRegion(pageIndex: 0, bounds: CGRect(x: 70, y: 120, width: 200, height: 30)), name: "Category", kind: .choice, choices: ["First", "Second"])
        let owner = AnnotateDocument()
        owner.model.load(document, owner: owner)
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        view.document = document
        view.model = owner.model
        owner.model.pdfView = view
        return (owner, view)
    }

    private func annotation(_ name: String, in document: PDFDocument) throws -> PDFAnnotation {
        try #require((0..<document.pageCount).flatMap { document.page(at: $0)?.annotations ?? [] }.first { $0.fieldName == name })
    }
}
