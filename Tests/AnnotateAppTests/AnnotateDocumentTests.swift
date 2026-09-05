import AnnotateCore
import AppKit
import PDFKit
import Testing
@testable import AnnotateApp

@Suite("Native document lifecycle", .serialized)
@MainActor
struct AnnotateDocumentTests {
    @Test("Closing cancellation calls NSDocument's completion exactly once with false and the original context")
    func closeCancellationCallback() {
        let document = AnnotateDocument()
        let receiver = CloseReceiver()
        let context = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer { context.deallocate() }
        document.reportCloseCancelled(to: receiver,
            selector: #selector(CloseReceiver.didCheckClose(_:shouldClose:contextInfo:)), contextInfo: context)
        #expect(receiver.callCount == 1)
        #expect(receiver.document === document)
        #expect(receiver.shouldClose == false)
        #expect(receiver.context == context)
    }

    @Test("Missing optional close completion does not crash")
    func missingCloseCallback() {
        let document = AnnotateDocument()
        document.reportCloseCancelled(to: NSObject(), selector: nil, contextInfo: nil)
        document.reportCloseCancelled(to: NSObject(), selector: NSSelectorFromString("unimplementedCallback:"), contextInfo: nil)
    }

    @Test("NSDocument reads and writes an annotated PDF through its real document methods")
    func documentReadWrite() throws {
        _ = NSApplication.shared
        let original = SamplePDF.make()
        let selection = try #require(original.findString("attention", withOptions: .caseInsensitive).first)
        let marker = PDFMarker(categories: [.important, .note], color: MarkerColor.palette[0], icon: "star.fill",
            quote: selection.string ?? "", note: "Document lifecycle sentinel", question: "",
            regions: MarkerCodec.regions(for: selection, in: original))
        try MarkerCodec.apply(marker, to: original)
        let document = AnnotateDocument()
        let bytes = try #require(original.dataRepresentation())
        try document.read(from: bytes, ofType: "com.adobe.pdf")
        document.makeWindowControllers()
        defer { document.close() }
        #expect(document.model.pageCount == 4)
        #expect(document.windowControllers.count == 1)
        #expect(document.model.markers == [marker])
        let saved = try document.data(ofType: "com.adobe.pdf")
        let reopened = try #require(PDFDocument(data: saved))
        #expect(MarkerCodec.markers(in: reopened) == [marker])
    }

    @Test("Invalid input and an empty unsaved document fail without pretending to save")
    func invalidDocumentData() {
        let document = AnnotateDocument()
        #expect(throws: (any Error).self) { try document.read(from: Data("This is not a PDF".utf8), ofType: "com.adobe.pdf") }
        #expect(throws: (any Error).self) { try document.data(ofType: "com.adobe.pdf") }
        #expect(document.model.pdfDocument == nil)
    }
}

@MainActor
private final class CloseReceiver: NSObject {
    var callCount = 0
    var document: NSDocument?
    var shouldClose: Bool?
    var context: UnsafeMutableRawPointer?

    @objc func didCheckClose(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        callCount += 1
        self.document = document
        self.shouldClose = shouldClose
        context = contextInfo
    }
}
