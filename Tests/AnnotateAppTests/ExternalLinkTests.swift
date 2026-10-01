import AppKit
import PDFKit
import Testing
@testable import AnnotateApp

/// Links in a PDF are chosen by its author. Only web and mail links may open, and only
/// after the reader has seen the whole address and agreed.
@Suite("Links in a PDF", .serialized)
@MainActor
struct ExternalLinkTests {
    @Test("Web and mail links ask first", arguments: ["https://example.com/a?b=c", "http://example.com", "mailto:someone@example.com", "HTTPS://Example.com"])
    func openableAskFirst(address: String) throws {
        let url = try #require(URL(string: address))
        #expect(ExternalLink(url) == .confirm(url))
    }

    @Test("Everything else is refused, with a reason",
          arguments: ["file:///System/Applications/Calculator.app", "smb://server/share", "afp://server/share", "x-apple.systempreferences:com.apple.preference.security",
                      "applescript://com.apple.scripteditor?action=new", "vnc://host", "ftp://host/file", "javascript:alert(1)", "data:text/html,hi",
                      "ssh://host", "tel:123", "help:anchor=x", "https:///no-host", "relative/path"])
    func otherSchemesRefused(address: String) throws {
        let url = try #require(URL(string: address))
        guard case .refuse(let reason) = ExternalLink(url) else { Issue.record("\(address) was allowed"); return }
        #expect(!reason.isEmpty)
    }

    @Test("The address shown before opening has no invisible or direction-changing characters")
    func displayedAddressIsPlain() throws {
        // A right-to-left override would make "fdp.exe" read as "exe.pdf".
        let url = try #require(URL(string: "https://example.com/\u{202E}fdp.exe"))
        let shown = ExternalLink.displayed(url)
        #expect(!shown.unicodeScalars.contains { $0.properties.generalCategory == .format || $0.properties.generalCategory == .control })
        #expect(shown.hasPrefix("https://example.com/"))
    }

    // MARK: - The view

    private final class Record {
        var asked: [URL] = []
        var opened: [URL] = []
        var refused: [String] = []
    }

    private func view(agreeing: Bool) -> (SelectionPDFView, Record, NSWindow) {
        _ = NSApplication.shared
        let owner = AnnotateDocument()
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        owner.model.load(document, owner: owner)
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 900))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.document = document; view.model = owner.model; owner.model.pdfView = view
        let record = Record()
        view.confirmExternalLink = { url, _, decide in record.asked.append(url); decide(agreeing) }
        view.openExternalLink = { record.opened.append($0) }
        view.reportRefusedLink = { reason, _ in record.refused.append(reason) }
        // Keep the owner alive with the window for the test's duration.
        objc_setAssociatedObject(window, "owner", owner, .OBJC_ASSOCIATION_RETAIN)
        return (view, record, window)
    }

    @Test("The view handles its own links: PDFKit never hands an address to the system")
    func viewIsItsOwnDelegate() {
        let (view, _, window) = view(agreeing: false)
        defer { window.close() }
        #expect(view.delegate is LinkDelegate)
    }

    @Test("A web link opens only once the reader agrees")
    func webLinkNeedsAgreement() throws {
        let url = try #require(URL(string: "https://example.com/report"))
        let (declining, declined, window) = view(agreeing: false)
        declining.perform(PDFActionURL(url: url))
        #expect(declined.asked == [url] && declined.opened.isEmpty)
        window.close()
        let (agreeing, agreed, other) = view(agreeing: true)
        try #require(agreeing.delegate).pdfViewWillClick?(onLink: agreeing, with: url)
        #expect(agreed.asked == [url] && agreed.opened == [url])
        other.close()
    }

    @Test("A file link is refused without asking, by either route PDFKit uses")
    func fileLinkRefused() throws {
        let url = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let (view, record, window) = view(agreeing: true)
        defer { window.close() }
        view.perform(PDFActionURL(url: url))
        try #require(view.delegate).pdfViewWillClick?(onLink: view, with: url)
        #expect(record.asked.isEmpty && record.opened.isEmpty)
        #expect(record.refused.count == 2)
    }

    @Test("A link into another PDF file is refused")
    func remoteDocumentRefused() throws {
        let (view, record, window) = view(agreeing: true)
        defer { window.close() }
        view.perform(PDFActionRemoteGoTo(pageIndex: 0, at: .zero, fileURL: URL(fileURLWithPath: "/tmp/other.pdf")))
        #expect(record.opened.isEmpty && record.refused.count == 1)
    }

    @Test("Clicking a link on the page goes through the same check: a file link is refused, a web link asks")
    func clickingALink() throws {
        let (view, record, window) = view(agreeing: true)
        defer { window.close() }
        let page = try #require(view.document?.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        // A link covering the whole page: the first click anywhere would follow it.
        let link = PDFAnnotation(bounds: box, forType: .link, withProperties: nil)
        link.action = PDFActionURL(url: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        page.addAnnotation(link)
        view.layoutDocumentView()
        view.go(to: page)
        let centre = view.convert(view.convert(CGPoint(x: box.midX, y: box.midY), from: page), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: centre, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown))
        #expect(record.opened.isEmpty, "a file link must never open")
        #expect(record.refused.count == 1, "the click reached the link check")
        // A web link asks, and opens once the reader agrees.
        link.action = PDFActionURL(url: try #require(URL(string: "https://example.com")))
        view.mouseDown(with: try event(.leftMouseDown))
        #expect(record.asked.count == 1 && record.opened.count == 1)
        // While editing, a click edits text; the link neither asks nor opens.
        view.model?.showTool(.edit)
        view.follow(ExternalLink(try #require(URL(string: "https://example.com"))))
        #expect(record.asked.count == 1 && record.opened.count == 1)
    }

    @Test("The question names the site first, and warns when a user name could disguise it")
    func summaryNamesTheSite() throws {
        let plain = try #require(URL(string: "https://example.com/a"))
        #expect(ExternalLink.summary(plain).hasPrefix("Site: example.com"))
        #expect(ExternalLink.summary(plain).hasSuffix("https://example.com/a"))
        let disguised = try #require(URL(string: "https://www.bank.com&x=1@evil.example/login"))
        let summary = ExternalLink.summary(disguised)
        #expect(summary.hasPrefix("Site: evil.example"))
        #expect(summary.contains("user name"))
    }

    @Test("PDFKit's own route for links into other PDFs is answered by the same refusal")
    func remoteGoToDelegate() throws {
        let (view, record, window) = view(agreeing: true)
        defer { window.close() }
        let action = PDFActionRemoteGoTo(pageIndex: 0, at: .zero, fileURL: URL(fileURLWithPath: "/tmp/other.pdf"))
        try #require(view.delegate).pdfViewOpenPDF?(view, forRemoteGoToAction: action)
        #expect(record.refused.count == 1 && record.opened.isEmpty)
    }
}
