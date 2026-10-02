import AnnotateCore
import AppKit
import PDFKit
import Testing
@testable import AnnotateApp

@Suite("Live typing swaps only the edited page", .serialized)
@MainActor
struct PageExchangeTests {
    // MARK: - PDFDocument.canExchangePage / exchangePage

    @Test("Only a page without form widgets, inside the document, can be exchanged")
    func canExchange() throws {
        let pdf = SamplePDF.make()
        #expect(pdf.canExchangePage(at: 0))
        #expect(!pdf.canExchangePage(at: -1))
        #expect(!pdf.canExchangePage(at: pdf.pageCount))
        try PDFFormEditor.create(in: pdf, region: PageRegion(pageIndex: 2, bounds: CGRect(x: 50, y: 80, width: 200, height: 24)),
                                 name: "Reviewer", kind: .text)
        #expect(!pdf.canExchangePage(at: 2))
        #expect(pdf.canExchangePage(at: 1))
        // Other interactive annotations do not live in the form and can move with a page.
        let link = PDFAnnotation(bounds: CGRect(x: 50, y: 50, width: 20, height: 20), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com/")
        pdf.page(at: 1)?.addAnnotation(link)
        #expect(pdf.canExchangePage(at: 1))
    }

    private struct Navigation {
        let pdf: PDFDocument
        let old: PDFPage
        let other: PDFPage
        let toOld: PDFOutline
        let actionToOld: PDFOutline
        let nestedToOld: PDFOutline
        let toOther: PDFOutline
        let linkActionToOld: PDFAnnotation
        let linkDestinationToOld: PDFAnnotation
        let linkToOther: PDFAnnotation
        let externalLink: PDFAnnotation
    }

    /// A four-page document whose outline and links lead to page 2 (index 1) and page 4.
    private func navigationDocument() throws -> Navigation {
        let pdf = SamplePDF.make()
        let old = try #require(pdf.page(at: 1)), other = try #require(pdf.page(at: 3))
        func destination(_ page: PDFPage, y: CGFloat) -> PDFDestination {
            let destination = PDFDestination(page: page, at: CGPoint(x: 40, y: y))
            destination.zoom = 1.5
            return destination
        }
        let root = PDFOutline()
        let toOld = PDFOutline(); toOld.label = "Build a reading trail"; toOld.destination = destination(old, y: 700)
        let actionToOld = PDFOutline(); actionToOld.label = "Through an action"
        actionToOld.action = PDFActionGoTo(destination: destination(old, y: 500))
        let nestedToOld = PDFOutline(); nestedToOld.label = "Nested"; nestedToOld.destination = destination(old, y: 300)
        toOld.insertChild(nestedToOld, at: 0)
        let toOther = PDFOutline(); toOther.label = "Share what matters"; toOther.destination = destination(other, y: 650)
        root.insertChild(toOld, at: 0); root.insertChild(actionToOld, at: 1); root.insertChild(toOther, at: 2)
        pdf.outlineRoot = root
        let first = try #require(pdf.page(at: 0))
        func link(_ y: CGFloat) -> PDFAnnotation {
            let link = PDFAnnotation(bounds: CGRect(x: 400, y: y, width: 80, height: 16), forType: .link, withProperties: nil)
            first.addAnnotation(link)
            return link
        }
        let linkActionToOld = link(100); linkActionToOld.action = PDFActionGoTo(destination: destination(old, y: 600))
        let linkDestinationToOld = link(130); linkDestinationToOld.destination = destination(old, y: 400)
        let linkToOther = link(160); linkToOther.action = PDFActionGoTo(destination: destination(other, y: 200))
        let externalLink = link(190); externalLink.url = URL(string: "https://example.com/")
        return Navigation(pdf: pdf, old: old, other: other, toOld: toOld, actionToOld: actionToOld, nestedToOld: nestedToOld,
                          toOther: toOther, linkActionToOld: linkActionToOld, linkDestinationToOld: linkDestinationToOld,
                          linkToOther: linkToOther, externalLink: externalLink)
    }

    private func reopen(_ pdf: PDFDocument) throws -> PDFDocument {
        let data = try #require(pdf.dataRepresentation())
        return try #require(PDFDocument(data: data))
    }

    /// PDFKit writes an outline or link targets added in memory only when the page
    /// structure also changed; otherwise it keeps the document's original navigation.
    /// Adding and removing a blank page forces the rewrite, as opening a real file with
    /// an outline would already have it.
    private func persistingNavigation(_ pdf: PDFDocument) -> PDFDocument {
        pdf.insert(PDFPage(), at: pdf.pageCount)
        pdf.removePage(at: pdf.pageCount - 1)
        return pdf
    }

    private func linkDestination(_ link: PDFAnnotation) -> PDFDestination? {
        (link.action as? PDFActionGoTo)?.destination ?? link.destination
    }

    @Test("Exchanging a page keeps count and order and retargets outline entries and links to it")
    func exchangeRetargets() throws {
        let nav = try navigationDocument()
        let pdf = nav.pdf
        let before = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string }
        let copy = try reopen(pdf)
        let replacement = try #require(copy.page(at: 1))
        pdf.exchangePage(at: 1, with: replacement)

        #expect(pdf.pageCount == 4)
        #expect(pdf.page(at: 1) === replacement)
        #expect(pdf.index(for: nav.old) == NSNotFound)
        #expect((0..<pdf.pageCount).map { pdf.page(at: $0)?.string } == before)
        #expect(nav.toOld.destination?.page === replacement)
        #expect(nav.toOld.destination?.point == CGPoint(x: 40, y: 700))
        #expect(nav.toOld.destination?.zoom == 1.5)
        #expect((nav.actionToOld.action as? PDFActionGoTo)?.destination.page === replacement)
        #expect((nav.actionToOld.action as? PDFActionGoTo)?.destination.point == CGPoint(x: 40, y: 500))
        #expect(nav.nestedToOld.destination?.page === replacement)
        #expect(nav.nestedToOld.destination?.point == CGPoint(x: 40, y: 300))
        #expect(linkDestination(nav.linkActionToOld)?.page === replacement)
        #expect(linkDestination(nav.linkActionToOld)?.point == CGPoint(x: 40, y: 600))
        #expect(linkDestination(nav.linkDestinationToOld)?.page === replacement)
        #expect(linkDestination(nav.linkDestinationToOld)?.point == CGPoint(x: 40, y: 400))
        // Destinations to other pages, and links that leave the document, are untouched.
        #expect(nav.toOther.destination?.page === nav.other)
        #expect(nav.toOther.destination?.point == CGPoint(x: 40, y: 650))
        #expect(linkDestination(nav.linkToOther)?.page === nav.other)
        #expect(nav.externalLink.url == URL(string: "https://example.com/"))

        // The retargeted navigation survives saving.
        let reopened = try reopen(pdf)
        let outline = try #require(reopened.outlineRoot)
        func index(of destination: PDFDestination?) -> Int? { destination?.page.map { reopened.index(for: $0) } }
        let toOld = try #require(outline.child(at: 0))
        #expect(index(of: toOld.destination ?? (toOld.action as? PDFActionGoTo)?.destination) == 1)
        let nested = try #require(toOld.child(at: 0))
        #expect(index(of: nested.destination ?? (nested.action as? PDFActionGoTo)?.destination) == 1)
        let action = try #require(outline.child(at: 1))
        #expect(index(of: action.destination ?? (action.action as? PDFActionGoTo)?.destination) == 1)
        let toOther = try #require(outline.child(at: 2))
        #expect(index(of: toOther.destination ?? (toOther.action as? PDFActionGoTo)?.destination) == 3)
        let links = try #require(reopened.page(at: 0)).annotations.filter { $0.type == "Link" }
        let internalTargets = links.compactMap { linkDestination($0) }.map { index(of: $0) }
        #expect(internalTargets.sorted { ($0 ?? -1) < ($1 ?? -1) } == [1, 1, 3])
    }

    @Test("Exchanging a page outside the document changes nothing")
    func exchangeOutOfRange() throws {
        let pdf = SamplePDF.make()
        let pages = (0..<pdf.pageCount).map { pdf.page(at: $0) }
        pdf.exchangePage(at: 4, with: PDFPage())
        pdf.exchangePage(at: -1, with: PDFPage())
        #expect(pdf.pageCount == 4)
        #expect(zip(pages, (0..<pdf.pageCount).map { pdf.page(at: $0) }).allSatisfy { $0 === $1 })
    }

    // MARK: - Live typing through the reader

    private func editingFixture(_ pdf: PDFDocument) -> (AnnotateDocument, SelectionPDFView, NSWindow) {
        _ = NSApplication.shared
        let owner = AnnotateDocument()
        owner.model.load(pdf, owner: owner)
        let view = SelectionPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.document = pdf; view.model = owner.model; owner.model.pdfView = view
        view.layoutDocumentView()
        owner.model.showTool(.edit)
        return (owner, view, window)
    }

    private func beginEditing(_ phrase: String, in owner: AnnotateDocument, view: SelectionPDFView) throws -> LiveTextEdit {
        let pdf = try #require(owner.model.pdfDocument)
        view.setCurrentSelection(try #require(pdf.findString(phrase, withOptions: []).first), animate: false)
        owner.model.beginLiveText(replacingSelection: true)
        return try #require(owner.model.liveEdit)
    }

    @Test("Typing on a plain page keeps the open document and changes only that page; save and reopen hold the new text once")
    func liveEditExchangesPage() throws {
        let pdf = SamplePDF.make()
        let (owner, view, window) = editingFixture(pdf)
        defer { owner.model.discardPendingLiveText(); window.close() }
        let before = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string }
        let session = try beginEditing("Keep categories useful", in: owner, view: view)
        #expect(session.pageIndex == 1)
        session.text = "Categories kept useful"
        #expect(!session.nativeUpdateFailed)
        let open = try #require(owner.model.pdfDocument)
        #expect(open === pdf, "A plain page is swapped inside the open document")
        #expect(view.document === pdf)
        #expect(open.pageCount == 4)
        for index in [0, 2, 3] { #expect(open.page(at: index)?.string == before[index], "page \(index + 1)") }
        #expect(open.findString("Categories kept useful", withOptions: []).count == 1)
        #expect(open.findString("Keep categories useful", withOptions: []).isEmpty)
        #expect(owner.model.pageNumber == 2)
        #expect(owner.model.toolSelection == PageRegion(pageIndex: 1, bounds: session.appliedBounds))
        #expect(owner.model.finishLiveText())
        let reopened = try #require(PDFDocument(data: try owner.data(ofType: "com.adobe.pdf")))
        #expect(reopened.pageCount == 4)
        #expect(reopened.findString("Categories kept useful", withOptions: []).count == 1)
        #expect(reopened.findString("Keep categories useful", withOptions: []).isEmpty)
        #expect(reopened.page(at: 1)?.string?.contains("Categories kept useful") == true)
        for index in [0, 2, 3] { #expect(reopened.page(at: index)?.string == before[index], "page \(index + 1)") }
    }

    @Test("Markers on other pages, and on the edited page, survive a page exchange")
    func markersSurviveExchange() throws {
        let pdf = SamplePDF.make()
        for (phrase, page) in [("attention", 0), ("Revisit marks", 1)] {
            let selection = try #require(pdf.findString(phrase, withOptions: []).first)
            let marker = PDFMarker(categories: [.important], color: MarkerColor.palette[0], icon: "star.fill",
                                   quote: selection.string ?? phrase, note: "On page \(page + 1)", question: "",
                                   regions: MarkerCodec.regions(for: selection, in: pdf))
            try MarkerCodec.apply(marker, to: pdf)
        }
        let (owner, view, window) = editingFixture(pdf)
        defer { owner.model.discardPendingLiveText(); window.close() }
        #expect(owner.model.markers.count == 2)
        let session = try beginEditing("Keep categories useful", in: owner, view: view)
        session.text = "Categories kept useful"
        #expect(owner.model.pdfDocument === pdf)
        #expect(Set(owner.model.markers.map(\.note)) == ["On page 1", "On page 2"])
        let reopened = try #require(PDFDocument(data: try owner.data(ofType: "com.adobe.pdf")))
        #expect(Set(MarkerCodec.markers(in: reopened).map(\.note)) == ["On page 1", "On page 2"])
    }

    @Test("Typing on a page with form fields replaces the whole document and keeps the fields")
    func widgetPageUsesWholeDocument() throws {
        let pdf = SamplePDF.make()
        try PDFFormEditor.create(in: pdf, region: PageRegion(pageIndex: 1, bounds: CGRect(x: 300, y: 60, width: 200, height: 24)),
                                 name: "Reviewer", kind: .text)
        let (owner, view, window) = editingFixture(pdf)
        defer { owner.model.discardPendingLiveText(); window.close() }
        #expect(!pdf.canExchangePage(at: 1))
        let session = try beginEditing("Keep categories useful", in: owner, view: view)
        session.text = "Categories kept useful"
        #expect(!session.nativeUpdateFailed)
        let open = try #require(owner.model.pdfDocument)
        #expect(open !== pdf, "Form pages take the whole-document path")
        #expect(view.document === open)
        #expect(open.findString("Categories kept useful", withOptions: []).count == 1)
        #expect(PDFFormEditor.fields(in: open).map(\.name) == ["Reviewer"])
        #expect(owner.model.finishLiveText())
        let reopened = try #require(PDFDocument(data: try owner.data(ofType: "com.adobe.pdf")))
        #expect(reopened.findString("Categories kept useful", withOptions: []).count == 1)
        #expect(reopened.findString("Keep categories useful", withOptions: []).isEmpty)
        #expect(PDFFormEditor.fields(in: reopened).map(\.name) == ["Reviewer"])
    }

    @Test("Outline entries and links to the edited page still lead to it after typing and saving")
    func liveEditKeepsNavigation() throws {
        let nav = try navigationDocument()
        // Also a link on the edited page itself, leading to another page.
        let edited = nav.old
        let outbound = PDFAnnotation(bounds: CGRect(x: 400, y: 60, width: 80, height: 16), forType: .link, withProperties: nil)
        outbound.action = PDFActionGoTo(destination: PDFDestination(page: nav.other, at: CGPoint(x: 40, y: 100)))
        edited.addAnnotation(outbound)
        let reloaded = try reopen(persistingNavigation(nav.pdf))
        let (owner, view, window) = editingFixture(reloaded)
        defer { owner.model.discardPendingLiveText(); window.close() }
        let session = try beginEditing("Keep categories useful", in: owner, view: view)
        // Two keystrokes: the second exchange replaces a page the first one put in.
        session.text = "Categories kept usable"
        session.text = "Categories kept useful"
        let open = try #require(owner.model.pdfDocument)
        #expect(open === reloaded)
        func index(of destination: PDFDestination?, in document: PDFDocument) -> Int? {
            destination?.page.map { document.index(for: $0) }
        }
        func outlineIndex(_ item: PDFOutline?, in document: PDFDocument) -> Int? {
            index(of: item?.destination ?? (item?.action as? PDFActionGoTo)?.destination, in: document)
        }
        // In the open document.
        #expect(outlineIndex(open.outlineRoot?.child(at: 0), in: open) == 1)
        #expect(outlineIndex(open.outlineRoot?.child(at: 1), in: open) == 1)
        #expect(outlineIndex(open.outlineRoot?.child(at: 2), in: open) == 3)
        let firstPageTargets = (open.page(at: 0)?.annotations ?? []).filter { $0.type == "Link" }
            .compactMap { linkDestination($0) }.map { index(of: $0, in: open) }
        #expect(firstPageTargets.sorted { ($0 ?? -1) < ($1 ?? -1) } == [1, 1, 3])
        let editedPageTargets = (open.page(at: 1)?.annotations ?? []).filter { $0.type == "Link" }
            .compactMap { linkDestination($0) }.map { index(of: $0, in: open) }
        #expect(editedPageTargets == [3], "A link on the edited page must lead into the open document")
        // After saving.
        #expect(owner.model.finishLiveText())
        let reopened = try #require(PDFDocument(data: try owner.data(ofType: "com.adobe.pdf")))
        #expect(outlineIndex(reopened.outlineRoot?.child(at: 0), in: reopened) == 1)
        #expect(outlineIndex(reopened.outlineRoot?.child(at: 1), in: reopened) == 1)
        #expect(outlineIndex(reopened.outlineRoot?.child(at: 2), in: reopened) == 3)
        let savedTargets = (reopened.page(at: 1)?.annotations ?? []).filter { $0.type == "Link" }
            .compactMap { linkDestination($0) }.map { index(of: $0, in: reopened) }
        #expect(savedTargets == [3])
    }

    @Test("Undo after typing on a plain page restores the original page; redo brings the edit back")
    func undoRestoresOriginal() async throws {
        let pdf = SamplePDF.make()
        let originalText = try #require(pdf.string)
        let (owner, view, window) = editingFixture(pdf)
        defer { owner.model.discardPendingLiveText(); window.close() }
        let undo = try #require(owner.undoManager)
        undo.groupsByEvent = false
        let session = try beginEditing("Keep categories useful", in: owner, view: view)
        undo.beginUndoGrouping()
        session.text = "Categories kept useful"
        undo.endUndoGrouping()
        #expect(owner.model.pdfDocument === pdf)
        try await Task.sleep(for: .milliseconds(80))
        #expect(owner.isDocumentEdited)
        #expect(undo.canUndo)
        undo.undo()
        try await Task.sleep(for: .milliseconds(80))
        #expect(owner.model.liveEdit == nil)
        let restored = try #require(owner.model.pdfDocument)
        #expect(restored.string == originalText)
        #expect(restored.findString("Categories kept useful", withOptions: []).isEmpty)
        #expect(restored.findString("Keep categories useful", withOptions: []).count == 1)
        #expect(!owner.isDocumentEdited)
        undo.redo()
        try await Task.sleep(for: .milliseconds(80))
        #expect(owner.model.pdfDocument?.findString("Categories kept useful", withOptions: []).count == 1)
        #expect(owner.model.pdfDocument?.findString("Keep categories useful", withOptions: []).isEmpty == true)
    }

    // MARK: - Non-functional

    @Test("Typing 50 characters into a live edit on a four-page document stays responsive")
    func typingPerformance() throws {
        let pdf = SamplePDF.make()
        let (owner, view, window) = editingFixture(pdf)
        defer { owner.model.discardPendingLiveText(); window.close() }
        // A whole paragraph, as a click in Edit opens it, so 50 characters fit its width.
        let page = try #require(pdf.page(at: 1))
        let line = try #require(pdf.findString("Revisit marks", withOptions: []).first).bounds(for: page)
        let paragraph = try #require(ParagraphText.selection(at: CGPoint(x: line.midX, y: line.midY), on: page))
        owner.model.suppressSelection = true
        view.setCurrentSelection(paragraph, animate: false)
        owner.model.suppressSelection = false
        owner.model.beginLiveText(replacingSelection: true, reflowingLines: true)
        let session = try #require(owner.model.liveEdit)
        let typed = "Categories are useful when each one means something"
        #expect(typed.count >= 50)
        let clock = ContinuousClock()
        var perKeystroke: [Duration] = []
        var text = ""
        for character in typed.prefix(50) {
            text.append(character)
            let start = clock.now
            session.text = text
            perKeystroke.append(clock.now - start)
        }
        let total = perKeystroke.reduce(.zero, +)
        let sorted = perKeystroke.sorted()
        print("Live typing on a 4-page PDF: 50 keystrokes in \(total); median \(sorted[sorted.count / 2]); max \(sorted.last ?? .zero)")
        #expect(owner.model.pdfDocument === pdf)
        #expect(pdf.findString(String(typed.prefix(50)), withOptions: []).count == 1)
        #expect(!session.nativeUpdateFailed)
        // Generous: a regression to seconds per keystroke fails; ordinary machine noise does not.
        #expect(total < .seconds(25))
        #expect(sorted[sorted.count / 2] < .milliseconds(500))
    }

    @Test("An outline larger than the budget sends live edits down the whole-document path")
    func outlineBudget() throws {
        let pdf = SamplePDF.make()
        let root = PDFOutline()
        var parent = root
        // A deep chain, as a crafted file might nest it.
        for level in 0..<40 {
            let item = PDFOutline()
            item.label = "Level \(level)"
            item.destination = PDFDestination(page: try #require(pdf.page(at: 0)), at: .zero)
            parent.insertChild(item, at: 0)
            parent = item
        }
        pdf.outlineRoot = root
        #expect(pdf.outlineItems()?.count == 41)
        #expect(pdf.outlineItems(limit: 20) == nil)
        #expect(pdf.canExchangePage(at: 0))
        // The walk visits each entry once and never recurses.
        #expect(Set(try #require(pdf.outlineItems()).map(ObjectIdentifier.init)).count == 41)
    }

    @Test("A go-to action on any annotation (not only links) follows the page it leads to")
    func buttonActionsRetarget() throws {
        let pdf = SamplePDF.make()
        let target = try #require(pdf.page(at: 1))
        let button = PDFAnnotation(bounds: CGRect(x: 40, y: 40, width: 60, height: 20), forType: .square, withProperties: nil)
        button.action = PDFActionGoTo(destination: PDFDestination(page: target, at: CGPoint(x: 0, y: 700)))
        let first = try #require(pdf.page(at: 0))
        first.addAnnotation(button)
        let bytes = try #require(pdf.dataRepresentation())
        let copy = try #require(PDFDocument(data: bytes))
        let replacement = try #require(copy.page(at: 1))
        pdf.exchangePage(at: 1, with: replacement)
        let destination = try #require((button.action as? PDFActionGoTo)?.destination)
        #expect(destination.page === pdf.page(at: 1))
    }

    @Test("An outline root with more children than the budget is refused without reading them all")
    func wideOutlineBudget() throws {
        let pdf = SamplePDF.make()
        let root = PDFOutline()
        for index in 0..<30 {
            let item = PDFOutline(); item.label = "Entry \(index)"
            root.insertChild(item, at: index)
        }
        pdf.outlineRoot = root
        #expect(pdf.outlineItems(limit: 10) == nil)
        #expect(pdf.outlineItems(limit: 31)?.count == 31)
    }

    /// outlineItems: by default at most 20,000 entries, the root included.
    @Test("By default an outline of exactly 20,000 entries is walked; one entry more keeps the whole-document path")
    func defaultOutlineBudget() throws {
        let pdf = SamplePDF.make()
        let root = PDFOutline()
        for index in 0..<19_999 {
            let item = PDFOutline(); item.label = "Entry \(index)"
            root.insertChild(item, at: index)
        }
        pdf.outlineRoot = root
        #expect(pdf.outlineItems()?.count == 20_000)
        #expect(pdf.canExchangePage(at: 0))
        let last = PDFOutline(); last.label = "One too many"
        root.insertChild(last, at: root.numberOfChildren)
        #expect(pdf.outlineItems() == nil)
        #expect(!pdf.canExchangePage(at: 0))
    }
}
