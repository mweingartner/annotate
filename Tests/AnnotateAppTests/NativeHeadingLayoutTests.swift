import AnnotateCore
import AppKit
import CoreText
import PDFKit
import SwiftUI
import Testing
@testable import AnnotateApp

@Suite("Native editor paper and exact text layout", .serialized)
@MainActor
struct NativeHeadingLayoutTests {
    @Test("Opening an untouched sample heading displays every character and fits PDF layout", arguments: [0, 90, 180, 270])
    func originalHeadingFits(rotation: Int) throws {
        _ = NSApplication.shared
        let owner = AnnotateDocument(), pdf = SamplePDF.make()
        let page = try #require(pdf.page(at: 0))
        page.rotation = rotation
        owner.model.load(pdf, owner: owner)
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 800))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        view.document = pdf; view.model = owner.model; owner.model.pdfView = view
        view.autoScales = false; view.scaleFactor = 1.25
        view.layoutDocumentView(); view.layoutSubtreeIfNeeded()
        let text = "A better way to return"
        let selection = try #require(pdf.findString(text, withOptions: []).first)
        view.setCurrentSelection(selection, animate: false)
        owner.model.beginLiveText(replacingSelection: true)
        let session = try #require(owner.model.liveEdit)
        #expect(!session.textOverflows)
        #expect(owner.model.pdfDocument === pdf)
        let field = try #require(view.liveTextView)
        #expect(field.textContainerInset == .zero)
        let layout = try #require(field.layoutManager), container = try #require(field.textContainer)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        #expect(used.height <= field.bounds.height + 0.1)
        let visibleGlyphs = layout.glyphRange(forBoundingRect: field.bounds, in: container)
        let visibleCharacters = layout.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        #expect(NSMaxRange(visibleCharacters) == session.attributedText.length)
        let framesetter = CTFramesetterCreateWithAttributedString(session.attributedText)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: session.appliedBounds, transform: nil), nil)
        #expect(CTFrameGetVisibleStringRange(frame).length == session.attributedText.length)
        let result = try PDFNativeTextEditor.replace(in: pdf, region: try #require(session.nativeOriginalRegion),
            originalText: text, replacement: session.attributedText,
            destination: PageRegion(pageIndex: 0, bounds: session.appliedBounds))
        #expect(result.findString(text, withOptions: []).count == 1)
    }

    @Test("The sidebar uses white paper and a visible caret in both system appearances", arguments: [ColorScheme.light, .dark])
    func sidebarPaper(scheme: ColorScheme) throws {
        _ = NSApplication.shared
        let session = LiveTextEdit(identifier: "paper", pageIndex: 0, text: "True PDF black text", font: .systemFont(ofSize: 14),
            color: .black, bounds: CGRect(x: 0, y: 0, width: 300, height: 50))
        let host = NSHostingView(rootView: SidebarRichTextEditor(session: session).environment(\.colorScheme, scheme))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = CGRect(x: 0, y: 0, width: 350, height: 180)
        host.layoutSubtreeIfNeeded()
        let field = try #require(descendants(host).compactMap { $0 as? NSTextView }.first)
        #expect(field.backgroundColor == .white)
        #expect(field.insertionPointColor == .black)
        #expect(field.attributedString().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .black)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
