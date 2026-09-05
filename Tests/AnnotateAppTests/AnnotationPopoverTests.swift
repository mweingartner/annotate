import AnnotateCore
import AppKit
import PDFKit
import SwiftUI
import Testing
@testable import AnnotateApp

@Suite("Annotation details layout", .serialized)
@MainActor
struct AnnotationPopoverTests {
    @Test("Removing a marker by delete or undo dismisses its captured details", arguments: ["delete", "undo"])
    func stalePopoverCloses(operation: String) throws {
        _ = NSApplication.shared
        let document = AnnotateDocument()
        let pdf = SamplePDF.make()
        document.model.load(pdf, owner: document)
        let model = document.model
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.closeAnnotationPopover(); window.close() }
        view.document = pdf
        view.model = model
        model.pdfView = view
        view.layoutDocumentView()
        let selection = try #require(pdf.findString("attention", withOptions: .caseInsensitive).first)
        let undo = try #require(document.undoManager)
        undo.groupsByEvent = false
        model.captureSelection(selection)
        model.draft?.note = "This is the saved version."
        undo.beginUndoGrouping()
        model.saveDraft()
        undo.endUndoGrouping()
        let marker = try #require(model.markers.first)
        view.showAnnotation(MarkerHit(marker: marker, anchor: CGRect(x: 100, y: 100, width: 20, height: 20)))
        #expect(view.annotationPopover != nil)
        if operation == "delete" {
            undo.beginUndoGrouping()
            model.delete(marker)
            undo.endUndoGrouping()
        } else { undo.undo() }
        #expect(model.markers.isEmpty)
        #expect(view.annotationPopover == nil)
    }

    @Test("Long notes remain scrollable without displacing the actions", arguments: [ColorScheme.light, .dark])
    func longNoteLayout(scheme: ColorScheme) throws {
        _ = NSApplication.shared
        let marker = makeMarker(note: (1...80).map { "Paragraph \($0): Read the original evidence and compare the result." }.joined(separator: "\n\n"))
        let host = NSHostingView(rootView: AnnotationPopoverView(marker: marker, canEdit: true,
            hasPendingDraft: false, edit: {}, close: {}).environment(\.colorScheme, scheme))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.setFrameSize(NSSize(width: 370, height: 600))
        let size = host.fittingSize
        host.setFrameSize(size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        #expect(abs(size.width - 370) < 1)
        #expect(size.height > 380 && size.height < 600)
        let scroll = try #require(descendants(of: host).compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        #expect(scroll.frame.height <= 381)
        #expect(document.bounds.height > scroll.contentView.bounds.height * 4)
        let end = CGPoint(x: 0, y: max(0, document.bounds.maxY - scroll.contentView.bounds.height))
        scroll.contentView.scroll(to: end)
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(abs(scroll.documentVisibleRect.maxY - document.bounds.maxY) < 2)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func makeMarker(note: String) -> PDFMarker {
        PDFMarker(categories: [.important, .note, .question], color: MarkerColor.palette[0],
                  icon: "star.fill", quote: "A selected passage that deserves a closer look.",
                  note: note, question: "What should I verify next?",
                  regions: [.init(pageIndex: 0, bounds: CGRect(x: 60, y: 200, width: 180, height: 20))])
    }
}
