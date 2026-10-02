import AnnotateCore
import AppKit
import CoreText
import PDFKit
import Testing
@testable import AnnotateApp

/// Live typing on a page that can be swapped in place asks the native editor for only that
/// page; every other page of its result is a placeholder. These tests hold the open
/// document, and the file saved from it, to everything the other pages had.
@Suite("Live typing builds only the edited page", .serialized)
@MainActor
struct PageOnlyLiveEditTests {
    // MARK: - Fixtures

    /// Object N is `objects[N - 1]`. A stream's entry opens its dictionary, which is closed
    /// here with the stream's length.
    private static func rawPDF(_ objects: [String], streams: [Int: Data] = [:]) -> Data {
        var output = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(output.count)
            output.append(Data("\(index + 1) 0 obj\n".utf8))
            if let data = streams[index + 1] {
                output.append(Data("\(object) /Length \(data.count) >>\nstream\n".utf8)); output.append(data); output.append(Data("\nendstream".utf8))
            } else { output.append(Data(object.utf8)) }
            output.append(Data("\nendobj\n".utf8))
        }
        let xref = output.count
        output.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { output.append(Data(String(format: "%010ld 00000 n \n", offset).utf8)) }
        output.append(Data("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return output
    }

    /// The edit target on each page of `book()`; pages 2 and 4 share one content stream.
    private static let words = ["FIRST", "TWIN", "ROTATED", "TWIN", "LAST"]

    /// Five pages: resources inherited from the Pages node, a content stream and image
    /// shared by pages 2 and 4, a rotated and cropped page 3, a smaller last page, a stored
    /// thumbnail, notes, links between pages, an outline, and two markers (pages 1 and 4).
    /// Saved and reopened once, so PDFKit's own normalisation of new annotations is done.
    private func book(kids: String = "3 0 R 4 0 R 5 0 R 6 0 R 7 0 R", count: Int = 5, markers: Bool = true) throws -> PDFDocument {
        let image = Data((0..<(16 * 12)).flatMap { pixel -> [UInt8] in pixel % 16 < 8 ? [255, 0, 0] : [0, 0, 255] })
        let data = Self.rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /Outlines 19 0 R >>",
            "<< /Type /Pages /Kids [\(kids)] /Count \(count) /MediaBox [0 0 400 500] /Resources << /Font << /F 8 0 R >> /XObject << /Im 9 0 R >> >> >>",
            "<< /Type /Page /Parent 2 0 R /Contents 10 0 R /Annots [15 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /Contents 11 0 R /Thumb 13 0 R >>",
            "<< /Type /Page /Parent 2 0 R /Rotate 90 /CropBox [20 30 380 470] /Resources << /Font << /G 8 0 R >> /XObject << /Pic 9 0 R >> >> /Contents 12 0 R /Annots [16 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /Contents 11 0 R /Annots [17 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Contents 14 0 R /Annots [18 0 R] >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Type /XObject /Subtype /Image /Width 16 /Height 12 /ColorSpace /DeviceRGB /BitsPerComponent 8",
            "<<", "<<", "<<",
            "<< /Width 4 /Height 4 /ColorSpace /DeviceRGB /BitsPerComponent 8",
            "<<",
            "<< /Type /Annot /Subtype /Text /Rect [300 450 324 474] /Contents (Note on the first page) >>",
            "<< /Type /Annot /Subtype /Square /Rect [60 60 160 120] /C [1 0 0] /Contents (Box on the rotated page) >>",
            "<< /Type /Annot /Subtype /Link /Rect [40 40 140 60] /Border [0 0 0] /Dest [3 0 R /XYZ 0 300 0] >>",
            "<< /Type /Annot /Subtype /Link /Rect [40 40 140 60] /Border [0 0 0] /Dest [5 0 R /XYZ 0 200 0] >>",
            "<< /Type /Outlines /First 20 0 R /Last 21 0 R /Count 2 >>",
            "<< /Title (To the last page) /Parent 19 0 R /Next 21 0 R /Dest [7 0 R /XYZ 0 300 0] >>",
            "<< /Title (To the twin page) /Parent 19 0 R /Prev 20 0 R /Dest [6 0 R /XYZ 0 300 0] >>"
        ], streams: [
            9: image,
            10: Data("BT /F 18 Tf 40 400 Td (FIRST page words) Tj ET q 100 0 0 80 40 200 cm /Im Do Q".utf8),
            11: Data("BT /F 18 Tf 40 400 Td (TWIN page words) Tj ET q 100 0 0 80 40 200 cm /Im Do Q".utf8),
            12: Data("BT /G 18 Tf 60 400 Td (ROTATED page words) Tj ET q 100 0 0 80 60 200 cm /Pic Do Q".utf8),
            13: Data(repeating: 128, count: 4 * 4 * 3),
            14: Data("BT /F 18 Tf 40 300 Td (LAST page words) Tj ET".utf8)
        ])
        let pdf = try #require(PDFDocument(data: data))
        if markers {
            for (phrase, page) in [("page words", 0), ("page words", 3)] {
                let target = try #require(pdf.page(at: page))
                let selection = try #require(pdf.findString(phrase, withOptions: []).first { $0.pages.contains(target) })
                let marker = PDFMarker(categories: [.important], color: MarkerColor.palette[0], icon: "star.fill",
                                       quote: phrase, note: "Marker on page \(page + 1)", question: "",
                                       regions: MarkerCodec.regions(for: selection, in: pdf))
                try MarkerCodec.apply(marker, to: pdf)
            }
        }
        return try reopen(pdf)
    }

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

    /// Opens a live edit on `word` where it appears on page `index`.
    private func beginEditing(_ word: String, page index: Int, owner: AnnotateDocument, view: SelectionPDFView) throws -> LiveTextEdit {
        let pdf = try #require(owner.model.pdfDocument)
        let page = try #require(pdf.page(at: index))
        view.setCurrentSelection(try #require(pdf.findString(word, withOptions: []).first { $0.pages.contains(page) }), animate: false)
        owner.model.beginLiveText(replacingSelection: true)
        let session = try #require(owner.model.liveEdit)
        #expect(session.pageIndex == index)
        return session
    }

    private func reopen(_ document: PDFDocument) throws -> PDFDocument {
        let data = try #require(document.dataRepresentation())
        return try #require(PDFDocument(data: data))
    }

    /// The document as PDFKit writes it after a change to its page structure, with no edit:
    /// what a saved page is compared with, since PDFKit's own rewrite can move a few
    /// anti-aliased pixels of unembedded text.
    private func rewritten(_ document: PDFDocument) throws -> PDFDocument {
        let copy = try reopen(document)
        copy.insert(PDFPage(), at: copy.pageCount)
        copy.removePage(at: copy.pageCount - 1)
        return try reopen(copy)
    }

    private func saved(_ owner: AnnotateDocument) throws -> PDFDocument {
        try #require(PDFDocument(data: try owner.data(ofType: "com.adobe.pdf")))
    }

    // MARK: - What a page is

    private struct Note: Equatable, CustomStringConvertible {
        let type: String?, bounds: CGRect, contents: String?, target: Int?, point: CGPoint?
        var description: String { "\(type ?? "?") \(bounds) \(contents ?? "") → \(target.map(String.init) ?? "-")" }
    }

    /// Everything a reader can see of a page, and where its links lead.
    private struct PageState: Equatable {
        let text: String?, rotation: Int, media: CGRect, crop: CGRect, notes: [Note], pixels: [UInt8]
    }

    private func state(_ document: PDFDocument, _ index: Int) throws -> PageState {
        let page = try #require(document.page(at: index))
        // Popups: PDFKit doesn't list a marker's popup after reopening, and the reader adds
        // it back on any edit (`MarkerCodec.refreshAppearance`), whichever path it takes.
        let notes = page.annotations.filter { $0.type != "Popup" }.map { annotation -> Note in
            // A link's own destination. Reading `action` on a link written with /Dest makes
            // PDFKit save an extra, unresolvable /A beside it, so it isn't read here.
            let destination = annotation.type == "Link" ? annotation.destination : nil
            return Note(type: annotation.type, bounds: annotation.bounds, contents: annotation.contents,
                        target: destination?.page.map { document.index(for: $0) }, point: destination?.point)
        }
        return PageState(text: page.string, rotation: page.rotation, media: page.bounds(for: .mediaBox),
                         crop: page.bounds(for: .cropBox), notes: notes, pixels: try contentPixels(page))
    }

    /// What the page's content draws (no annotations), over its whole media box.
    private func contentPixels(_ page: PDFPage) throws -> [UInt8] {
        let reference = try #require(page.pageRef)
        let media = page.bounds(for: .mediaBox)
        let width = Int(media.width), height = Int(media.height)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: -media.minX, y: -media.minY)
        context.drawPDFPage(reference)
        let image = try #require(context.makeImage())
        return Array(try #require(image.dataProvider?.data) as Data)
    }

    private func isBlank(_ pixels: [UInt8]) -> Bool { pixels.allSatisfy { $0 == 255 } }

    private func outlineTargets(_ document: PDFDocument) -> [Int?] {
        guard let root = document.outlineRoot else { return [] }
        return (0..<root.numberOfChildren).map { index in
            let item = root.child(at: index)
            return (item?.destination ?? (item?.action as? PDFActionGoTo)?.destination)?.page.map { document.index(for: $0) }
        }
    }

    private struct MarkerState: Equatable { let note: String, regions: [PageRegion] }
    private func markerStates(_ document: PDFDocument) -> [MarkerState] {
        MarkerCodec.markers(in: document).map { MarkerState(note: $0.note, regions: $0.regions) }.sorted { $0.note < $1.note }
    }

    /// No page of `document` is a placeholder: each one draws something.
    private func expectNoPlaceholders(_ document: PDFDocument, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index))
            #expect(!(page.string ?? "").isEmpty, "\(label): page \(index + 1) has no text", sourceLocation: sourceLocation)
            #expect(!isBlank(try contentPixels(page)), "\(label): page \(index + 1) draws nothing", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Typing on every kind of page

    @Test("Typing on the first page, a page sharing its content, a rotated and cropped page, or the last page leaves every other page whole, open and saved",
          arguments: [0, 1, 2, 4])
    func otherPagesStayWhole(index: Int) throws {
        let pdf = try book()
        let before = try (0..<5).map { try state(pdf, $0) }
        let control = try rewritten(pdf), savedBefore = try (0..<5).map { try state(control, $0) }
        let outline = outlineTargets(pdf), markers = markerStates(pdf)
        #expect(outline == [4, 3])
        #expect(markers.count == 2)
        let (owner, view, window) = editingFixture(pdf)
        defer { owner.model.discardPendingLiveText(); window.close() }
        let session = try beginEditing(Self.words[index], page: index, owner: owner, view: view)
        // Two keystrokes: the second exchange replaces a page the first one put in.
        session.text = "NE"
        session.text = "NEW"
        #expect(!session.nativeUpdateFailed, "\(session.nativeFailureMessage ?? "")")
        let open = try #require(owner.model.pdfDocument)
        #expect(open === pdf, "the page is swapped inside the open document")
        #expect(owner.model.errorMessage == nil)

        func check(_ document: PDFDocument, _ label: String, against before: [PageState]) throws {
            #expect(document.pageCount == 5, "\(label)")
            for other in 0..<5 where other != index {
                let now = try state(document, other)
                #expect(now.text == before[other].text, "\(label): page \(other + 1) text")
                #expect(now.pixels == before[other].pixels, "\(label): page \(other + 1) content, \(zip(now.pixels, before[other].pixels).filter { $0 != $1 }.count) bytes differ of \(now.pixels.count) vs \(before[other].pixels.count)")
                #expect(now.rotation == before[other].rotation && now.media == before[other].media && now.crop == before[other].crop,
                        "\(label): page \(other + 1) geometry")
                #expect(now.notes == before[other].notes, "\(label): page \(other + 1) annotations \(now.notes) vs \(before[other].notes)")
            }
            let edited = try state(document, index)
            #expect(edited.text?.contains("NEW") == true, "\(label)")
            #expect(edited.text?.contains(Self.words[index]) == false, "\(label)")
            #expect(edited.text?.contains("page words") == true, "\(label): the rest of the line stays")
            #expect(edited.rotation == before[index].rotation && edited.media == before[index].media && edited.crop == before[index].crop, "\(label)")
            #expect(edited.notes.map(\.type) == before[index].notes.map(\.type), "\(label): the edited page keeps its annotations")
            #expect(edited.notes.map(\.target) == before[index].notes.map(\.target), "\(label): its links lead where they did")
            #expect(outlineTargets(document) == outline, "\(label): outline")
            #expect(markerStates(document) == markers, "\(label): markers")
            try expectNoPlaceholders(document, label)
        }
        try check(open, "open", against: before)
        #expect(owner.model.markers.count == 2)
        #expect(owner.model.finishLiveText())
        try check(try saved(owner), "saved", against: savedBefore)
    }

    @Test("A page tree that lists the edited page twice: typing applies, the page keeps its content and resources, and no placeholder reaches the open or saved document",
          arguments: [0, 2])
    func duplicateKids(index: Int) throws {
        // Pages 1 and 3 are one dictionary; page 2 is the rotated page.
        let pdf = try book(kids: "3 0 R 5 0 R 3 0 R", count: 3, markers: false)
        try #require(pdf.pageCount == 3)
        let before = try (0..<3).map { try state(pdf, $0) }
        let (owner, view, window) = editingFixture(pdf)
        defer { owner.model.discardPendingLiveText(); window.close() }
        let session = try beginEditing("FIRST", page: index, owner: owner, view: view)
        session.text = "NEW"
        #expect(!session.nativeUpdateFailed, "\(session.nativeFailureMessage ?? "")")
        let open = try #require(owner.model.pdfDocument)
        #expect(open === pdf)
        #expect(open.page(at: index)?.string?.contains("NEW\npage words") == true, "\(open.page(at: index)?.string ?? "nil")")
        // The edited page still draws its image: its resources came through.
        #expect(try PDFNativeImageEditor.images(in: open, pageIndex: index).count == 1)
        for other in 0..<3 where other != index { #expect(try state(open, other) == before[other], "page \(other + 1)") }
        try expectNoPlaceholders(open, "open")
        #expect(owner.model.finishLiveText())
        let reopened = try saved(owner)
        #expect(reopened.pageCount == 3)
        #expect(reopened.page(at: index)?.string?.contains("NEW\npage words") == true)
        try expectNoPlaceholders(reopened, "saved")
        #expect(try PDFNativeImageEditor.images(in: reopened, pageIndex: index).count == 1)
    }

    // MARK: - Undo

    @Test("Undo after several keystrokes on a page sharing its content returns every page to the original; redo brings the edit back")
    func undoToOriginal() async throws {
        let pdf = try book()
        let before = try (0..<5).map { try state(pdf, $0) }
        let (owner, view, window) = editingFixture(pdf)
        defer { owner.model.discardPendingLiveText(); window.close() }
        let undo = try #require(owner.undoManager)
        undo.groupsByEvent = false
        let session = try beginEditing("TWIN", page: 1, owner: owner, view: view)
        undo.beginUndoGrouping()
        for text in ["N", "NE", "NEW"] { session.text = text }
        undo.endUndoGrouping()
        #expect(!session.nativeUpdateFailed)
        #expect(owner.model.pdfDocument === pdf)
        try await Task.sleep(for: .milliseconds(80))
        #expect(owner.isDocumentEdited)
        undo.undo()
        try await Task.sleep(for: .milliseconds(80))
        #expect(owner.model.liveEdit == nil)
        let restored = try #require(owner.model.pdfDocument)
        #expect(try (0..<5).map { try state(restored, $0) } == before)
        #expect(outlineTargets(restored) == [4, 3])
        #expect(markerStates(restored).count == 2)
        #expect(!owner.isDocumentEdited)
        undo.redo()
        try await Task.sleep(for: .milliseconds(80))
        let redone = try #require(owner.model.pdfDocument)
        #expect(redone.page(at: 1)?.string?.contains("NEW\npage words") == true)
        #expect(redone.page(at: 3)?.string == before[3].text, "the page sharing the content stream is unchanged")
        try expectNoPlaceholders(redone, "redone")
    }

    // MARK: - Reflow

    private let first = "The paragraph being edited runs over two lines at this width, so adding words gives it a third."
    private let second = "The next paragraph sits right below and must move with it, keeping the same gap as before."
    private let added = " These added words are long enough to need a whole extra line of their own, and then some more."

    /// Three pages; the middle one is laid out for reflow (two paragraphs, then a wide gap
    /// and a third). The first and last pages carry text, a note and links to the middle.
    private func reflowBook() throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        let font = try #require(NSFont(name: "Helvetica", size: 12))
        let style = NSMutableParagraphStyle(); style.lineSpacing = 3
        func frame(_ text: String, top: CGFloat) -> CGFloat {
            let attributed = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: style, .ligature: 0])
            let setter = CTFramesetterCreateWithAttributedString(attributed)
            let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: 360, height: 1000), nil)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(x: 72, y: top - size.height, width: 360, height: size.height), transform: nil), nil), context)
            return size.height
        }
        context.beginPDFPage(nil); _ = frame("Opening page text that never moves.", top: 720); context.endPDFPage()
        context.beginPDFPage(nil)
        var top: CGFloat = 720
        for (index, paragraph) in [first, second, "This paragraph follows a wide gap that absorbs the change."].enumerated() {
            top -= frame(paragraph, top: top) + (index == 1 ? 90 : 10)
        }
        context.endPDFPage()
        context.beginPDFPage(nil); _ = frame("Closing page text that never moves.", top: 720); context.endPDFPage()
        context.closePDF()
        let pdf = try #require(PDFDocument(data: data as Data))
        let middle = try #require(pdf.page(at: 1))
        for index in [0, 2] {
            let page = try #require(pdf.page(at: index))
            let link = PDFAnnotation(bounds: CGRect(x: 72, y: 600, width: 100, height: 16), forType: .link, withProperties: nil)
            link.destination = PDFDestination(page: middle, at: CGPoint(x: 0, y: 700))
            page.addAnnotation(link)
            let note = PDFAnnotation(bounds: CGRect(x: 72, y: 500, width: 24, height: 24), forType: .text, withProperties: nil)
            note.contents = "Note on page \(index + 1)"
            page.addAnnotation(note)
        }
        // PDFKit writes link targets added in memory only when the page structure also
        // changes; adding and removing a blank page makes it write them.
        pdf.insert(PDFPage(), at: pdf.pageCount)
        pdf.removePage(at: pdf.pageCount - 1)
        let saved = try reopen(pdf)
        for index in [0, 2] {
            let link = try #require(saved.page(at: index)?.annotations.first { $0.type == "Link" })
            try #require(link.destination?.page.map { saved.index(for: $0) } == 1, "the fixture's links lead to the middle page")
        }
        return saved
    }

    @Test("Reflow on a middle page moves its annotations with its text; the other pages, their links and notes stay whole, open and saved")
    func reflowMovesAnnotationsOnlyOnTheEditedPage() throws {
        let base = try reflowBook()
        // The box sits on the paragraph that moves; added after the first save, as a reader would.
        let middle = try #require(base.page(at: 1))
        let secondBefore = try #require(base.findString("The next paragraph", withOptions: []).first).bounds(for: middle)
        let square = PDFAnnotation(bounds: secondBefore.insetBy(dx: -2, dy: -2), forType: .square, withProperties: nil)
        square.contents = "Box on moved text"
        middle.addAnnotation(square)
        let pdf = try reopen(base)
        let before = try (0..<3).map { try state(pdf, $0) }
        let squareBefore = try #require(pdf.page(at: 1)?.annotations.first { $0.type == "Square" }).bounds
        let (owner, view, window) = editingFixture(pdf)
        defer { owner.model.discardPendingLiveText(); window.close() }
        let page = try #require(pdf.page(at: 1))
        let hit = try #require(pdf.findString("being edited", withOptions: []).first).bounds(for: page)
        let paragraph = try #require(ParagraphText.paragraph(at: CGPoint(x: hit.midX, y: hit.midY), on: page))
        owner.model.suppressSelection = true
        view.setCurrentSelection(paragraph.selection, animate: false)
        owner.model.suppressSelection = false
        owner.model.beginLiveText(replacingSelection: true, reflowingLines: paragraph.rewraps)
        let session = try #require(owner.model.liveEdit)
        #expect(session.pageIndex == 1)
        let block = session.appliedBounds
        session.text += added
        #expect(!session.nativeUpdateFailed, "\(session.nativeFailureMessage ?? "")")
        let grew = session.appliedBounds.height - block.height
        #expect(grew > 5, "the paragraph gained a line")
        let open = try #require(owner.model.pdfDocument)
        #expect(open === pdf)

        func check(_ document: PDFDocument, _ label: String) throws {
            for other in [0, 2] { #expect(try state(document, other) == before[other], "\(label): page \(other + 1)") }
            let edited = try #require(document.page(at: 1))
            let moved = try #require(edited.annotations.first { $0.type == "Square" })
            #expect(abs((squareBefore.minY - moved.bounds.minY) - grew) < 0.05, "\(label): \(squareBefore) → \(moved.bounds)")
            let secondAfter = try #require(document.findString("The next paragraph", withOptions: []).first).bounds(for: edited)
            #expect(abs((secondBefore.minY - secondAfter.minY) - grew) < 0.05, "\(label)")
            #expect(document.findString("whole extra line", withOptions: []).count == 1, "\(label)")
            // Links on the other pages still lead to the edited page.
            for other in [0, 2] {
                let link = try #require(document.page(at: other)?.annotations.first { $0.type == "Link" })
                #expect(link.destination?.page.map { document.index(for: $0) } == 1, "\(label): link on page \(other + 1)")
            }
            try expectNoPlaceholders(document, label)
        }
        try check(open, "open")
        #expect(owner.model.finishLiveText())
        try check(try saved(owner), "saved")
    }

    // MARK: - Scanned text

    @Test("Scan editing on a three-page scan whose first and last pages share one image leaves the others' pixels and OCR text whole, open and saved")
    func scannedTextOnAMultiPageScan() async throws {
        func scan(_ word: String) throws -> CGImage {
            let bitmap = try #require(CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 1600,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.setFillColor(NSColor.white.cgColor); bitmap.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
            bitmap.textPosition = CGPoint(x: 60, y: 270)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: [
                .font: try #require(NSFont(name: "Courier", size: 28)), .foregroundColor: NSColor.black])), bitmap)
            return try #require(bitmap.makeImage())
        }
        let target = try scan("TARGET"), other = try scan("ANOTHER")
        let data = NSMutableData(); var bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for image in [target, other, target] { context.beginPDFPage(nil); context.draw(image, in: bounds); context.endPDFPage() }
        context.closePDF()
        let recognized = try await PDFOCR.recognize(document: try #require(PDFDocument(data: data as Data)), options: PDFOCROptions(languages: ["en-US"]))
        let pdf = try #require(PDFDocument(data: recognized.data))
        try #require(pdf.pageCount == 3)
        #expect(pdf.findString("TARGET", withOptions: []).count == 2)
        let before = try (0..<3).map { try state(pdf, $0) }
        let (owner, view, window) = editingFixture(pdf)
        defer { owner.model.discardPendingLiveText(); window.close() }
        let session = try beginEditing("TARGET", page: 0, owner: owner, view: view)
        #expect(session.canEditScannedText)
        owner.model.enableScannedTextEditing()
        session.text = "EDITED"
        #expect(!session.nativeUpdateFailed, "\(session.nativeFailureMessage ?? "")")
        #expect(owner.model.pdfDocument === pdf)

        func check(_ document: PDFDocument, _ label: String) throws {
            for page in [1, 2] {
                let now = try state(document, page)
                #expect(now.text == before[page].text, "\(label): page \(page + 1) OCR text")
                #expect(now.pixels == before[page].pixels, "\(label): page \(page + 1) scan")
            }
            #expect(document.page(at: 0)?.string?.contains("TARGET") == false, "\(label)")
            #expect(document.page(at: 2)?.string?.contains("TARGET") == true, "\(label): the page sharing the scan keeps its word")
            #expect(document.findString("EDITED", withOptions: []).count == 1, "\(label)")
            #expect(try contentPixels(try #require(document.page(at: 0))) != before[0].pixels, "\(label): the scan itself changed")
        }
        try check(pdf, "open")
        #expect(owner.model.finishLiveText())
        try check(try saved(owner), "saved")
    }

    // MARK: - The whole-document path

    @Test("Typing on a page with a form field replaces the whole document, and every page is whole: no placeholder, open or saved")
    func formFieldsGetTheWholeDocument() throws {
        let pdf = try book()
        try PDFFormEditor.create(in: pdf, region: PageRegion(pageIndex: 1, bounds: CGRect(x: 200, y: 100, width: 150, height: 24)),
                                 name: "Reviewer", kind: .text)
        let base = try reopen(pdf)
        let before = try (0..<5).map { try state(base, $0) }
        let (owner, view, window) = editingFixture(base)
        defer { owner.model.discardPendingLiveText(); window.close() }
        #expect(!base.canExchangePage(at: 1))
        let session = try beginEditing("TWIN", page: 1, owner: owner, view: view)
        for text in ["N", "NEW"] { session.text = text }
        #expect(!session.nativeUpdateFailed, "\(session.nativeFailureMessage ?? "")")
        let open = try #require(owner.model.pdfDocument)
        #expect(open !== base, "form pages take the whole-document path")
        #expect(view.document === open)

        func check(_ document: PDFDocument, _ label: String) throws {
            try expectNoPlaceholders(document, label)
            for other in [0, 2, 3, 4] {
                let now = try state(document, other)
                #expect(now.text == before[other].text, "\(label): page \(other + 1)")
                #expect(now.pixels == before[other].pixels, "\(label): page \(other + 1)")
                #expect(now.rotation == before[other].rotation && now.crop == before[other].crop, "\(label): page \(other + 1)")
                #expect(now.notes.map(\.target) == before[other].notes.map(\.target), "\(label): page \(other + 1) links")
            }
            #expect(PDFFormEditor.fields(in: document).map(\.name) == ["Reviewer"], "\(label)")
            #expect(outlineTargets(document) == [4, 3], "\(label)")
            #expect(markerStates(document).count == 2, "\(label)")
        }
        try check(open, "open")
        #expect(owner.model.finishLiveText())
        try check(try saved(owner), "saved")
    }

    @Test("A form field on another page doesn't stop the edited page from being swapped, and the field is untouched")
    func fieldOnAnotherPage() throws {
        let pdf = try book()
        try PDFFormEditor.create(in: pdf, region: PageRegion(pageIndex: 3, bounds: CGRect(x: 200, y: 100, width: 150, height: 24)),
                                 name: "Reviewer", kind: .text)
        let base = try reopen(pdf)
        let fieldPage = try state(base, 3)
        let (owner, view, window) = editingFixture(base)
        defer { owner.model.discardPendingLiveText(); window.close() }
        let session = try beginEditing("TWIN", page: 1, owner: owner, view: view)
        session.text = "NEW"
        #expect(!session.nativeUpdateFailed)
        #expect(owner.model.pdfDocument === base)
        #expect(try state(base, 3) == fieldPage)
        #expect(owner.model.finishLiveText())
        let reopened = try saved(owner)
        #expect(PDFFormEditor.fields(in: reopened).map(\.name) == ["Reviewer"])
        #expect(PDFFormEditor.fields(in: reopened).first?.pageIndex == 3)
        try expectNoPlaceholders(reopened, "saved")
    }

    // MARK: - Images

    private func solid(_ color: CGColor) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try #require(context.makeImage())
    }

    @Test("Listing, previewing and replacing an image shared with other pages: no false stale selection, and the other pages keep the original",
          arguments: [0, 1, 2])
    func sharedImageWorkflow(index: Int) throws {
        _ = NSApplication.shared
        let pdf = try book()
        let owner = AnnotateDocument()
        owner.model.load(pdf, owner: owner)
        defer { owner.close() }
        let model = owner.model
        let others = try (0..<4).filter { $0 != index }.map { ($0, try PDFNativeImageEditor.images(in: pdf, pageIndex: $0)) }
        model.pageNumber = index + 1
        let image = try #require(try model.imagesOnCurrentPage().first)
        let preview = try PDFNativeImageEditor.preview(in: try #require(model.pdfDocument), image: image, maximumDimension: 160)
        #expect(preview.width == 160)
        model.selectImage(image)
        let session = try #require(model.imageEdit)
        session.stageReplacement(try solid(CGColor(red: 0, green: 1, blue: 0, alpha: 1)), name: "Green.png")
        #expect(model.applyImageChanges(), "\(model.errorMessage ?? "")")
        #expect(model.errorMessage == nil)
        let result = try #require(model.pdfDocument)
        #expect(try PDFNativeImageEditor.images(in: result, pageIndex: index).first != image)
        for (other, images) in others {
            #expect(try PDFNativeImageEditor.images(in: result, pageIndex: other) == images, "page \(other + 1)")
        }
        // Removing the image on a page that shares it, listed afresh, also applies.
        model.pageNumber = index == 3 ? 1 : 4
        let shared = try #require(try model.imagesOnCurrentPage().first)
        model.selectImage(shared)
        #expect(model.removeSelectedImage(), "\(model.errorMessage ?? "")")
        #expect(try model.imagesOnCurrentPage().isEmpty)
    }

    @Test("After typing swaps a page in, its images list, preview and replace without a stale selection")
    func imageAfterTyping() throws {
        let pdf = try book()
        let (owner, view, window) = editingFixture(pdf)
        defer { owner.model.discardPendingLiveText(); window.close() }
        let session = try beginEditing("TWIN", page: 1, owner: owner, view: view)
        session.text = "NEW"
        #expect(!session.nativeUpdateFailed)
        #expect(owner.model.finishLiveText())
        let model = owner.model
        model.pageNumber = 2
        let image = try #require(try model.imagesOnCurrentPage().first)
        _ = try PDFNativeImageEditor.preview(in: try #require(model.pdfDocument), image: image)
        model.selectImage(image)
        try #require(model.imageEdit).stageReplacement(try solid(CGColor(red: 0, green: 0, blue: 1, alpha: 1)), name: "Blue.png")
        #expect(model.applyImageChanges(), "\(model.errorMessage ?? "")")
        let reopened = try saved(owner)
        #expect(reopened.page(at: 1)?.string?.contains("NEW\npage words") == true)
        #expect(reopened.page(at: 3)?.string?.contains("TWIN page words") == true)
        #expect(try PDFNativeImageEditor.images(in: reopened, pageIndex: 3) == PDFNativeImageEditor.images(in: pdf, pageIndex: 3))
        try expectNoPlaceholders(reopened, "saved")
    }

    // MARK: - Non-functional

    /// A zlib (FlateDecode) stream of `data`: Foundation's zlib is raw DEFLATE, so this
    /// adds the two-byte header and the Adler-32 trailer.
    private static func flate(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var a: UInt32 = 1, b: UInt32 = 0
        for chunk in stride(from: 0, to: data.count, by: 5_552) {
            for byte in data[chunk..<min(chunk + 5_552, data.count)] { a += UInt32(byte); b += a }
            a %= 65_521; b %= 65_521
        }
        let adler = (b << 16) | a
        return Data([0x78, 0x9C]) + deflated + Data([UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)])
    }

    /// `pages` pages, each with its own text and its own 1,000-pixel square Flate image that
    /// decodes to 3 MB, like a scanned book: a whole-document rebuild decodes every one.
    private func heavyBook(pages: Int) throws -> Data {
        let side = 1_000
        // One gradient, compressed once; every page gets its own copy as its own object.
        var pixels = Data(count: side * side * 3)
        pixels.withUnsafeMutableBytes { buffer in
            for y in 0..<side { for x in 0..<side {
                let offset = (y * side + x) * 3
                buffer[offset] = UInt8(truncatingIfNeeded: x); buffer[offset + 1] = UInt8(truncatingIfNeeded: y); buffer[offset + 2] = UInt8(truncatingIfNeeded: x ^ y)
            } }
        }
        let compressed = try Self.flate(pixels)
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"]
        var streams: [Int: Data] = [:], kids: [String] = []
        for page in 0..<pages {
            let image = objects.count + 1, content = image + 1, pageID = image + 2
            objects.append("<< /Type /XObject /Subtype /Image /Width \(side) /Height \(side) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode")
            streams[image] = compressed
            objects.append("<<"); streams[content] = Data("BT /F 14 Tf 40 450 Td (Chapter \(page + 1) TARGET here) Tj ET q 300 0 0 300 40 100 cm /Im Do Q".utf8)
            objects.append("<< /Type /Page /Parent 2 0 R /Resources << /Font << /F 3 0 R >> /XObject << /Im \(image) 0 R >> >> /Contents \(content) 0 R >>")
            kids.append("\(pageID) 0 R")
        }
        objects[1] = "<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count \(pages) /MediaBox [0 0 400 500] >>"
        return Self.rawPDF(objects, streams: streams)
    }

    /// The median time of keystrokes 2 to 7 (the first also takes the undo checkpoint).
    private func medianKeystroke(_ pdf: PDFDocument, page: Int = 0) throws -> Duration {
        let (owner, view, window) = editingFixture(pdf)
        defer { owner.model.discardPendingLiveText(); window.close() }
        let session = try beginEditing("TARGET", page: page, owner: owner, view: view)
        let clock = ContinuousClock()
        var times: [Duration] = []
        for (index, text) in ["N", "NE", "NEW", "NEWE", "NEWER", "NEWE", "NEW"].enumerated() {
            let start = clock.now
            session.text = text
            if index > 0 { times.append(clock.now - start) }
            #expect(!session.nativeUpdateFailed, "\(session.nativeFailureMessage ?? "")")
        }
        #expect(owner.model.pdfDocument?.findString("NEW", withOptions: []).count == 1)
        return times.sorted()[times.count / 2]
    }

    @Test("A keystroke on a 24-page scanned book costs about what one on a 2-page book does, and far less than rebuilding the whole book (a page with a form field)")
    func keystrokeCostFollowsTheEditedPage() throws {
        let small = try medianKeystroke(try #require(PDFDocument(data: try heavyBook(pages: 2))))
        let large = try medianKeystroke(try #require(PDFDocument(data: try heavyBook(pages: 24))))
        // The same book with a form field on the edited page takes the whole-document path.
        let withField = try #require(PDFDocument(data: try heavyBook(pages: 24)))
        try PDFFormEditor.create(in: withField, region: PageRegion(pageIndex: 0, bounds: CGRect(x: 200, y: 20, width: 150, height: 24)),
                                 name: "Reviewer", kind: .text)
        let whole = try medianKeystroke(try reopen(withField))
        print("Median keystroke: 2-page book \(small), 24-page book \(large), 24-page book rebuilt whole \(whole)")
        // Generous margins: the page-only path is about flat in the book's length; the
        // whole path decodes and writes every page's image on every keystroke.
        #expect(large < small * 4 + .milliseconds(40), "24 pages \(large) vs 2 pages \(small)")
        #expect(large * 3 < whole, "page-only \(large) vs whole \(whole)")
    }
}
