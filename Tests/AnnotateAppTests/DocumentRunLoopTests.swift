import AnnotateCore
import AppKit
import PDFKit
import Testing
@testable import AnnotateApp

@Suite("Document change counting with the AppKit run loop", .serialized)
@MainActor
struct DocumentRunLoopTests {
    @Test("A registered document with a window remains dirty after edit and clean after complete undo")
    func realDocumentLifecycle() async throws {
        _ = NSApplication.shared
        let owner = AnnotateDocument()
        owner.model.load(SamplePDF.make(), owner: owner)
        owner.fileType = "com.adobe.pdf"
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 800), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        owner.addWindowController(NSWindowController(window: window))
        NSDocumentController.shared.addDocument(owner)
        defer { NSDocumentController.shared.removeDocument(owner); owner.close() }
        let undo = try #require(owner.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        owner.model.mutatePDF("Rotate") { $0.page(at: 0)?.rotation = 90 }
        undo.endUndoGrouping()
        try await Task.sleep(for: .milliseconds(60))
        #expect(owner.isDocumentEdited)
        undo.undo()
        try await Task.sleep(for: .milliseconds(60))
        #expect(!owner.isDocumentEdited)
        undo.redo()
        try await Task.sleep(for: .milliseconds(60))
        #expect(owner.isDocumentEdited)
    }

    @Test("Measure default NSDocument undo-group counting without manual updates", arguments: [false, true])
    func defaultDocumentTracking(annotate: Bool) async throws {
        _ = NSApplication.shared
        let owner: NSDocument = annotate ? AnnotateDocument() : NSDocument()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 800), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        owner.addWindowController(NSWindowController(window: window))
        NSDocumentController.shared.addDocument(owner)
        defer { NSDocumentController.shared.removeDocument(owner); owner.close() }
        let undo = try #require(owner.undoManager)
        let target = Counter(undo: undo)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        target.change(to: 1)
        undo.endUndoGrouping()
        try await Task.sleep(for: .milliseconds(60))
        #expect(owner.isDocumentEdited)
        undo.undo()
        try await Task.sleep(for: .milliseconds(60))
        #expect(!owner.isDocumentEdited)
        #expect(target.value == 0)
    }

    @MainActor private final class Counter {
        let undo: UndoManager
        var value = 0
        init(undo: UndoManager) { self.undo = undo }
        func change(to value: Int) {
            let previous = self.value
            undo.registerUndo(withTarget: self) { target in target.change(to: previous) }
            self.value = value
        }
    }
}
