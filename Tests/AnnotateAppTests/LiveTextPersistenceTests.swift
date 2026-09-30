import AnnotateCore
import AppKit
import PDFKit
import Testing
@testable import AnnotateApp

@Suite("Live text persistence", .serialized)
@MainActor
struct LiveTextPersistenceTests {
    @Test("Invalid numeric geometry retains later typing and the last valid PDF rectangle", arguments: ["width", "outside", "negative", "nonfinite"])
    func invalidGeometryPreservesText(kind: String) throws {
        _ = NSApplication.shared
        let owner = AnnotateDocument(), model: ReaderModel
        model = owner.model
        model.load(SamplePDF.make(), owner: owner)
        model.toolSelection = insertionArea
        model.beginLiveText(replacingSelection: false)
        let session = try #require(model.liveEdit)
        let valid = session.bounds
        switch kind {
        case "width": session.width = 0
        case "outside": session.x = 100_000
        case "negative": session.height = -40
        default: session.y = .infinity
        }
        #expect(!session.geometryIsValid)
        #expect(session.bounds != valid)
        #expect(session.appliedBounds == valid)
        #expect(model.errorMessage?.contains("last valid") == true)
        session.text = "Text after invalid geometry 916"
        session.fontSize = 18
        #expect(!session.nativeUpdateFailed)
        let pdf = try #require(model.pdfDocument)
        let selection = try nativeSelection(in: pdf, text: session.text, fontSize: 18)
        let page = try #require(pdf.page(at: session.pageIndex))
        #expect(valid.insetBy(dx: -0.5, dy: -0.5).contains(selection.bounds(for: page)))
        #expect(page.annotations.isEmpty)
        #expect(model.finishLiveText())
        let saved = try owner.data(ofType: "com.adobe.pdf")
        let reopened = try #require(PDFDocument(data: saved))
        let restored = try nativeSelection(in: reopened, text: "Text after invalid geometry 916", fontSize: 18)
        let reopenedPage = try #require(reopened.page(at: session.pageIndex))
        let beforeBounds = selection.bounds(for: page), afterBounds = restored.bounds(for: reopenedPage)
        #expect(abs(beforeBounds.minX - afterBounds.minX) < 0.001)
        #expect(abs(beforeBounds.minY - afterBounds.minY) < 0.001)
        #expect(abs(beforeBounds.width - afterBounds.width) < 0.001)
        #expect(abs(beforeBounds.height - afterBounds.height) < 0.001)
        #expect(reopenedPage.annotations.isEmpty)
    }

    @Test("Valid geometry resumes without clamping the partial numeric input")
    func resumesValidGeometry() throws {
        _ = NSApplication.shared
        let owner = AnnotateDocument()
        owner.model.load(SamplePDF.make(), owner: owner)
        owner.model.toolSelection = insertionArea
        owner.model.beginLiveText(replacingSelection: false)
        let session = try #require(owner.model.liveEdit)
        let width = session.width
        session.width = 0
        session.text = "Retain this edit"
        #expect(session.width == 0)
        session.width = width - 10
        #expect(session.geometryIsValid)
        #expect(session.appliedBounds == session.bounds)
        #expect(owner.model.errorMessage == nil)
        let pdf = try #require(owner.model.pdfDocument)
        let selected = try nativeSelection(in: pdf, text: session.text, fontSize: session.font.pointSize)
        let page = try #require(pdf.page(at: session.pageIndex))
        #expect(session.appliedBounds.insetBy(dx: -0.5, dy: -0.5).contains(selected.bounds(for: page)))
        #expect(abs(session.appliedBounds.width - (width - 10)) < 0.001)
        #expect(page.annotations.isEmpty)
    }

    @Test("Live typing coalesces until a save establishes another undo checkpoint")
    func savedUndoCheckpoint() async throws {
        _ = NSApplication.shared
        let owner = AnnotateDocument(), model: ReaderModel
        model = owner.model
        model.load(SamplePDF.make(), owner: owner)
        model.toolSelection = insertionArea
        let originalText = try #require(model.pdfDocument?.string)
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 900))
        view.document = model.pdfDocument; view.model = model; model.pdfView = view
        let undo = try #require(owner.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        model.beginLiveText(replacingSelection: false)
        undo.endUndoGrouping()
        let session = try #require(model.liveEdit)
        session.text = "Saved text"
        session.fontSize = 19
        try await Task.sleep(for: .milliseconds(80))
        undo.undo()
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.pdfDocument?.page(at: 0)?.annotations.isEmpty == true)
        #expect(model.pdfDocument?.string == originalText)
        #expect(!owner.isDocumentEdited)
        undo.redo()
        try await Task.sleep(for: .milliseconds(80))
        let restoredPDF = try #require(model.pdfDocument)
        let selected = try nativeSelection(in: restoredPDF, text: "Saved text", fontSize: 19)
        view.setCurrentSelection(selected, animate: false)
        undo.beginUndoGrouping()
        model.beginLiveText(replacingSelection: true)
        undo.endUndoGrouping()
        let resumed = try #require(model.liveEdit)
        #expect(resumed.isExistingContent)
        #expect(resumed.text == "Saved text")
        // Expanding the destination keeps the later, larger phrase meaningful while
        // the removal region continues to refer to the original source glyphs.
        undo.beginUndoGrouping()
        resumed.bounds = insertionArea.bounds
        undo.endUndoGrouping()
        try await Task.sleep(for: .milliseconds(80))
        let location = FileManager.default.temporaryDirectory.appending(path: "live-checkpoint-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: location) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            owner.save(to: location, ofType: "com.adobe.pdf", for: .saveAsOperation) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        let saved = try Data(contentsOf: location)
        #expect(!owner.isDocumentEdited)
        #expect(resumed.needsUndoCheckpoint)
        undo.beginUndoGrouping()
        resumed.text = "Text after save"
        undo.endUndoGrouping()
        resumed.fontSize = 23
        try await Task.sleep(for: .milliseconds(80))
        #expect(owner.isDocumentEdited)
        undo.undo()
        try await Task.sleep(for: .milliseconds(80))
        #expect(!owner.isDocumentEdited)
        let savedPDF = try #require(PDFDocument(data: saved))
        let expected = try nativeSelection(in: savedPDF, text: "Saved text", fontSize: 19)
        let undonePDF = try #require(model.pdfDocument)
        let restored = try nativeSelection(in: undonePDF, text: "Saved text", fontSize: 19)
        #expect(restored.string == expected.string)
        #expect(undonePDF.string == savedPDF.string)
        #expect(undonePDF.page(at: 0)?.annotations.isEmpty == true)
        undo.redo()
        try await Task.sleep(for: .milliseconds(80))
        #expect(owner.isDocumentEdited)
        _ = try nativeSelection(in: #require(model.pdfDocument), text: "Text after save", fontSize: 23)
        #expect(model.pdfDocument?.findString("Saved text", withOptions: []).isEmpty == true)
        #expect(model.pdfDocument?.page(at: 0)?.annotations.isEmpty == true)
    }

    @Test("A native update that cannot fit preserves the PDF and prevents Save until corrected")
    func failedUpdateBlocksSave() async throws {
        _ = NSApplication.shared
        let owner = AnnotateDocument(), model: ReaderModel
        model = owner.model
        model.load(SamplePDF.make(), owner: owner)
        model.toolSelection = insertionArea
        model.beginLiveText(replacingSelection: false)
        let session = try #require(model.liveEdit)
        session.text = "Initial native text"
        let url = FileManager.default.temporaryDirectory.appending(path: "native-failure-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try await save(owner, to: url, operation: .saveAsOperation)
        let onDisk = try Data(contentsOf: url)
        let before = try #require(model.pdfDocument)
        let beforePages = (0..<before.pageCount).map { before.page(at: $0)?.string }
        let beforeAnnotations = (0..<before.pageCount).map { before.page(at: $0)?.annotations.count }
        let beforeBounds = (0..<before.pageCount).map { before.page(at: $0)?.bounds(for: .cropBox) }
        let beforeRevision = model.documentRevision
        let pending = String(repeating: "This line cannot fit in the text block.\n", count: 80)
        session.text = pending
        #expect(session.nativeUpdateFailed)
        #expect(session.text == pending)
        #expect(model.pdfDocument === before)
        // PDFKit may regenerate serialization IDs on every dataRepresentation call.
        // Compare the live content and geometry here; the actual saved file below
        // must remain byte-for-byte unchanged when NSDocument rejects this edit.
        #expect((0..<before.pageCount).map { model.pdfDocument?.page(at: $0)?.string } == beforePages)
        #expect((0..<before.pageCount).map { model.pdfDocument?.page(at: $0)?.annotations.count } == beforeAnnotations)
        #expect((0..<before.pageCount).map { model.pdfDocument?.page(at: $0)?.bounds(for: .cropBox) } == beforeBounds)
        #expect(model.documentRevision == beforeRevision)
        // Text that only needs more room is shown on the block (an overflow mark) and in
        // the inspector, not in the banner; the session keeps the reason.
        #expect(session.nativeFailureMessage != nil)
        #expect(model.errorMessage?.contains("pending text remains") != true)
        #expect(!model.finishLiveText())
        #expect(model.liveEdit === session)
        #expect(throws: (any Error).self) { try owner.data(ofType: "com.adobe.pdf") }
        do {
            try await save(owner, to: url, operation: .saveOperation)
            Issue.record("Save unexpectedly accepted a failed pending edit")
        } catch { #expect((error as NSError).domain == "Annotate") }
        #expect(try Data(contentsOf: url) == onDisk)
        model.mutatePDF("Rotate while failed") { $0.page(at: 0)?.rotation = 90 }
        #expect(model.pdfDocument === before)
        #expect(model.pdfDocument?.page(at: 0)?.rotation == 0)
        session.text = "Recovered native text"
        #expect(!session.nativeUpdateFailed)
        #expect(model.finishLiveText())
        try await save(owner, to: url, operation: .saveOperation)
        let reopened = try #require(PDFDocument(url: url))
        #expect(reopened.findString("Recovered native text", withOptions: []).count == 1)
        #expect(reopened.findString("Initial native text", withOptions: []).isEmpty)
        #expect(reopened.page(at: 0)?.annotations.isEmpty == true)
    }

    private var insertionArea: PageRegion {
        PageRegion(pageIndex: 0, bounds: CGRect(x: 60, y: 80, width: 450, height: 80))
    }

    private func nativeSelection(in document: PDFDocument, text: String, fontSize: Double) throws -> PDFSelection {
        let selection = try #require(document.findString(text, withOptions: []).first)
        let attributed = try #require(selection.attributedString)
        let font = try #require(attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(abs(font.pointSize - fontSize) < 0.01)
        return selection
    }

    private func save(_ document: AnnotateDocument, to url: URL, operation: NSDocument.SaveOperationType) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(to: url, ofType: "com.adobe.pdf", for: operation) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
