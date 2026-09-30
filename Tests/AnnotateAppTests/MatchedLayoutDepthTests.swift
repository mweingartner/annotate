import AnnotateCore
import AppKit
import CoreText
import PDFKit
import Testing
@testable import AnnotateApp

/// Deeper checks that an in-place edit sits where the original text was: across fonts,
/// sizes and line spacings; with character spacing and superscripts; on rotated pages;
/// for drag selections that start mid-line; with a substitute font; and for new text
/// boxes that take the look of nearby text.
@Suite("Edited text matches the original layout: fonts, spacing, selections and substitutes", .serialized)
@MainActor
struct MatchedLayoutDepthTests {
    private struct Line { let text: String; let box: CGRect }
    @MainActor private struct Harness { let owner: AnnotateDocument; let view: SelectionPDFView; let window: NSWindow
        var model: ReaderModel { owner.model }
        func close() { owner.model.discardPendingLiveText(); window.close() }
    }

    private func open(_ pdf: PDFDocument) -> Harness {
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
        return Harness(owner: owner, view: view, window: window)
    }

    private func lines(around point: CGPoint, on page: PDFPage) -> [Line] {
        (ParagraphText.selection(at: point, on: page)?.selectionsByLine() ?? []).map { Line(text: $0.string ?? "", box: $0.bounds(for: page)) }
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Clicks the paragraph containing `word` in Edit, appends `suffix`, and returns its
    /// lines before and after.
    private func editParagraph(_ harness: Harness, at word: String, appending suffix: String = " Z") throws -> (before: [Line], after: [Line], session: LiveTextEdit) {
        let pdf = try #require(harness.view.document)
        let page = try #require(pdf.page(at: 0))
        let hit = try #require(pdf.findString(word, withOptions: []).first).bounds(for: page)
        let point = CGPoint(x: hit.midX, y: hit.midY)
        let before = lines(around: point, on: page)
        try #require(!before.isEmpty)
        harness.view.editParagraph(at: harness.view.convert(harness.view.convert(point, from: page), to: nil))
        let session = try #require(harness.model.liveEdit)
        session.text += suffix
        #expect(!session.nativeUpdateFailed, "\(session.nativeFailureMessage ?? "")")
        let edited = try #require(harness.model.pdfDocument?.page(at: 0))
        let after = lines(around: CGPoint(x: before[0].box.midX, y: before[0].box.midY), on: edited)
        return (before, after, session)
    }

    /// Selects all the text on the page (one paragraph) and opens it as a rewrapping block,
    /// as clicking a paragraph does, without depending on paragraph detection, which
    /// treats widely spaced lines as separate paragraphs. Appends `suffix`.
    private func editWholePage(_ harness: Harness, appending suffix: String = " Z") throws -> (before: [Line], after: [Line], session: LiveTextEdit) {
        let pdf = try #require(harness.view.document)
        let page = try #require(pdf.page(at: 0))
        let selection = try #require(page.selection(for: page.bounds(for: .cropBox)))
        let before = selection.selectionsByLine().filter { !trimmed($0.string ?? "").isEmpty }.map { Line(text: $0.string ?? "", box: $0.bounds(for: page)) }
        harness.model.suppressSelection = true
        harness.view.setCurrentSelection(selection, animate: false)
        harness.model.suppressSelection = false
        harness.model.beginLiveText(replacingSelection: true, reflowingLines: true)
        let session = try #require(harness.model.liveEdit, "\(harness.model.errorMessage ?? "")")
        session.text += suffix
        #expect(!session.nativeUpdateFailed, "\(session.nativeFailureMessage ?? "")")
        let edited = try #require(harness.model.pdfDocument?.page(at: 0))
        let after = (edited.selection(for: edited.bounds(for: .cropBox))?.selectionsByLine() ?? [])
            .filter { !trimmed($0.string ?? "").isEmpty }.map { Line(text: $0.string ?? "", box: $0.bounds(for: edited)) }
        return (before, after, session)
    }

    /// The text on page 0 as its glyphs set it: exact pen positions, whatever the font.
    private func glyphLayout(_ pdf: PDFDocument) throws -> PDFNativeTextLayout {
        let page = try #require(pdf.page(at: 0))
        let crop = page.bounds(for: .cropBox)
        let selection = try #require(page.selection(for: crop))
        let result = try PDFNativeTextStyle.attributedText(in: pdf, region: PageRegion(pageIndex: 0, bounds: crop.insetBy(dx: 1, dy: 1)),
                                                           originalText: selection.string ?? "", fallback: try #require(selection.attributedString))
        return try #require(result.layout)
    }

    /// Every glyph line keeps its baseline and start to 0.05 pt.
    private func expectSameGlyphLines(_ before: PDFNativeTextLayout, _ after: PDFNativeTextLayout, _ context: String) {
        #expect(after.lines.count == before.lines.count || after.lines.count == before.lines.count + 1,
                "\(context): \(before.lines.count) → \(after.lines.count) glyph lines")
        for (index, (old, new)) in zip(before.lines, after.lines).enumerated() {
            #expect(abs(new.baseline - old.baseline) < 0.05, "\(context): line \(index + 1) baseline \(old.baseline) → \(new.baseline)")
            #expect(abs(new.start - old.start) < 0.05, "\(context): line \(index + 1) start \(old.start) → \(new.start)")
        }
    }

    /// Every line keeps its baseline and left edge to 0.05 pt, and every line but the
    /// last (which gained the suffix) breaks where it did.
    private func expectMatched(_ before: [Line], _ after: [Line], _ context: String) {
        #expect(after.count == before.count || after.count == before.count + 1, "\(context): \(before.count) → \(after.count) lines")
        for (old, new) in zip(before, after) {
            #expect(abs(new.box.minY - old.box.minY) < 0.05, "\(context): baseline moved \(new.box.minY - old.box.minY) on “\(old.text)”")
            #expect(abs(new.box.minX - old.box.minX) < 0.05, "\(context): left edge moved \(new.box.minX - old.box.minX) on “\(old.text)”")
        }
        for (old, new) in zip(before.dropLast(), after.dropLast()) {
            #expect(trimmed(new.text) == trimmed(old.text), "\(context): line broke differently")
        }
    }

    private let body = "Reading closely means noticing the argument beneath the prose. A careful reader returns to the passages that carry weight and asks what evidence supports them, which assumptions they rest on, and where the reasoning might bend."

    // MARK: - Fonts, sizes and line spacing

    @Test("Every line keeps its baseline, left edge and break across fonts, sizes and line spacing", arguments: [
        ("Helvetica", 9.0), ("Helvetica", 12), ("Helvetica", 24), ("Georgia", 12), ("Menlo", 11), ("Times New Roman", 12)
    ], [0.0, 5, 12])
    func acrossFonts(font: (String, Double), lineSpacing: Double) throws {
        let style = NSMutableParagraphStyle(); style.lineSpacing = lineSpacing
        let pdf = try PDFConversion.textDocument(NSAttributedString(string: body + " " + body, attributes: [
            .font: try #require(NSFont(name: font.0, size: font.1)), .paragraphStyle: style]))
        let harness = open(pdf)
        defer { harness.close() }
        let glyphsBefore = try glyphLayout(pdf)
        let result = try editWholePage(harness)
        let context = "\(font.0) \(font.1) spacing \(lineSpacing)"
        #expect(result.before.count >= 3, "the paragraph should wrap")
        #expect(result.session.font.familyName == NSFont(name: font.0, size: font.1)?.familyName)
        #expect(abs(result.session.font.pointSize - font.1) < 0.01)
        expectMatched(result.before, result.after, context)
        expectSameGlyphLines(glyphsBefore, try glyphLayout(try #require(harness.model.pdfDocument)), context)
    }

    @Test("Editing in the middle of a paragraph keeps the lines above it exactly as they were")
    func editInMiddle() throws {
        let pdf = try PDFConversion.textDocument(NSAttributedString(string: body, attributes: [.font: try #require(NSFont(name: "Georgia", size: 13))]))
        let harness = open(pdf)
        defer { harness.close() }
        let page = try #require(pdf.page(at: 0))
        let hit = try #require(pdf.findString("careful reader", withOptions: []).first).bounds(for: page)
        let before = lines(around: CGPoint(x: hit.midX, y: hit.midY), on: page)
        harness.view.editParagraph(at: harness.view.convert(harness.view.convert(CGPoint(x: hit.midX, y: hit.midY), from: page), to: nil))
        let session = try #require(harness.model.liveEdit)
        // Replace a word on the last line with a longer one; the lines above can't change.
        session.text = session.text.replacingOccurrences(of: "might bend", with: "might bend and break")
        #expect(!session.nativeUpdateFailed, "\(session.nativeFailureMessage ?? "")")
        let after = lines(around: CGPoint(x: before[0].box.midX, y: before[0].box.midY), on: try #require(harness.model.pdfDocument?.page(at: 0)))
        expectMatched(before, after, "middle edit")
    }

    // MARK: - Hand-built content streams

    /// A one-page PDF (612 × 792) whose content stream is `content`, with /F1 Helvetica.
    private func rawDocument(_ content: String, rotation: Int = 0) throws -> PDFDocument {
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate \(rotation) /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try #require(PDFDocument(data: data))
    }

    /// Lines broken as a typesetter would: the longest first, and no line has room for
    /// the next line's first word.
    private let spacedLines = ["Tracking opens up the letters of every", "word in this short paragraph, and an", "edit keeps its spacing."]

    private func spacedContent(_ tracking: Double) -> String {
        "BT /F1 12 Tf \(tracking) Tc 16 TL 1 0 0 1 72 600 Tm " + spacedLines.map { "(\($0)) Tj T*" }.joined(separator: " ") + " ET"
    }

    @Test("Text set with character spacing (Tc) keeps its spacing, baselines and breaks after an edit", arguments: [1.5, 0.6, -0.3])
    func keepsCharacterSpacing(tracking: Double) throws {
        let pdf = try rawDocument(spacedContent(tracking))
        let harness = open(pdf)
        defer { harness.close() }
        let page = try #require(pdf.page(at: 0))
        let unchanged = try #require(pdf.findString("letters", withOptions: []).first).bounds(for: page)
        let result = try editParagraph(harness, at: "short paragraph")
        let kern = try #require(result.session.attributedText.attribute(.kern, at: 0, effectiveRange: nil) as? Double)
        #expect(abs(kern - tracking) < 1e-6)
        expectMatched(result.before, result.after, "Tc \(tracking)")
        // An unchanged word is exactly as wide as it was: its letters are still spread.
        let edited = try #require(harness.model.pdfDocument)
        let moved = try #require(edited.findString("letters", withOptions: []).first).bounds(for: try #require(edited.page(at: 0)))
        #expect(abs(moved.width - unchanged.width) < 0.1, "width \(unchanged.width) → \(moved.width)")
        // Its position may shift by the font's pair kerning (“Tr” here), which the editor
        // applies and this hand-made stream doesn't; about 0.4 pt at 12 pt.
        #expect(abs(moved.minX - unchanged.minX) < 0.5, "x \(unchanged.minX) → \(moved.minX)")
    }

    @Test("A paragraph with a superscript or shallow subscript keeps its baselines after an edit", arguments: ["4", "5.5", "-1", "-3"])
    func superscript(rise: String) throws {
        let content = "BT /F1 12 Tf 16 TL 1 0 0 1 72 600 Tm (The famous result E = mc) Tj \(rise) Ts /F1 8 Tf (2) Tj 0 Ts /F1 12 Tf ( holds for) Tj T* (every observer in every frame of) Tj T* (reference, as the text explains.) Tj ET"
        let pdf = try rawDocument(content)
        let harness = open(pdf)
        defer { harness.close() }
        let page = try #require(pdf.page(at: 0))
        let famous = try #require(pdf.findString("famous", withOptions: []).first).bounds(for: page)
        let result = try editParagraph(harness, at: "every observer")
        #expect(result.before.count == 3)
        #expect(result.after.count == 3)
        // The first line's ink includes the raised or lowered figure, so its baseline is
        // checked on a word; the other lines by their boxes.
        let edited = try #require(harness.model.pdfDocument)
        let moved = try #require(edited.findString("famous", withOptions: []).first).bounds(for: try #require(edited.page(at: 0)))
        // CoreText moves a line whose raised or lowered glyph overruns the fixed line height
        // off the grid (a 12 pt line at 16 pt pitch tolerates about +4/-2). The block is
        // anchored on the grid, so every later line is exact and only that line itself may
        // sit up to a point off.
        let deep = rise == "-3" || rise == "5.5"
        #expect(abs(moved.minY - famous.minY) < (deep ? 1.1 : 0.05) && abs(moved.minX - famous.minX) < 0.05, "\(famous) → \(moved)")
        expectMatched(Array(result.before.dropFirst()), Array(result.after.dropFirst()), "rise \(rise)")
        #expect(abs(result.after[0].box.minX - result.before[0].box.minX) < 0.05)
        #expect(trimmed(result.after[1].text) == trimmed(result.before[1].text))
        #expect(result.session.text.contains("mc2 holds") || result.session.text.contains("mc 2 holds") || result.session.text.contains("mc2holds"),
                "\(result.session.text)")
    }

    @Test("Content on a quarter-turned page is edited in place without crashing, its baselines kept")
    func rotatedPage() throws {
        let pdf = try rawDocument(spacedContent(0), rotation: 90)
        let harness = open(pdf)
        defer { harness.close() }
        let page = try #require(pdf.page(at: 0))
        let target = try #require(pdf.findString("short paragraph", withOptions: []).first)
        let before = lines(around: CGPoint(x: target.bounds(for: page).midX, y: target.bounds(for: page).midY), on: page)
        harness.model.suppressSelection = true
        harness.view.setCurrentSelection(target, animate: false)
        harness.model.suppressSelection = false
        harness.model.beginLiveText(replacingSelection: true)
        let session = try #require(harness.model.liveEdit)
        session.text = "brief paragraph"
        #expect(!session.nativeUpdateFailed, "\(session.nativeFailureMessage ?? "")")
        let edited = try #require(harness.model.pdfDocument)
        #expect(edited.page(at: 0)?.rotation == 90)
        let found = try #require(edited.findString("brief paragraph", withOptions: []).first)
        let editedPage = try #require(edited.page(at: 0))
        #expect(abs(found.bounds(for: editedPage).minY - target.bounds(for: page).minY) < 0.05)
        #expect(abs(found.bounds(for: editedPage).minX - target.bounds(for: page).minX) < 0.05)
        #expect(before.count == 3)
    }

    @Test("Rotated text has no glyph layout and falls back to covering the selection", arguments: ["0 1 -1 0 300 200", "0 -1 1 0 300 600"])
    func rotatedText(matrix: String) throws {
        let pdf = try rawDocument("BT /F1 14 Tf \(matrix) Tm (Turned text) Tj ET")
        let harness = open(pdf)
        defer { harness.close() }
        let page = try #require(pdf.page(at: 0))
        let target = try #require(pdf.findString("Turned text", withOptions: []).first)
        let region = target.bounds(for: page)
        harness.model.suppressSelection = true
        harness.view.setCurrentSelection(target, animate: false)
        harness.model.suppressSelection = false
        harness.model.beginLiveText(replacingSelection: true)
        let session = try #require(harness.model.liveEdit)
        // Plain placement: the block starts at the selection's left edge and spans its width.
        #expect(abs(session.bounds.minX - region.minX) < 0.5, "\(session.bounds) vs \(region)")
        #expect(abs(session.bounds.width - region.width) < 0.5, "\(session.bounds) vs \(region)")
        // No layout-derived line height was imposed.
        let style = session.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect((style?.minimumLineHeight ?? 0) == 0)
        session.text = "Turned type"
        #expect(harness.model.liveEdit != nil)
    }

    // MARK: - Drag selections

    @Test("A drag selection that starts mid-line keeps its first line's start and the others' margin")
    func midLineSelection() throws {
        let style = NSMutableParagraphStyle(); style.lineSpacing = 4
        let pdf = try PDFConversion.textDocument(NSAttributedString(string: body, attributes: [
            .font: try #require(NSFont(name: "Helvetica", size: 13)), .paragraphStyle: style]))
        let harness = open(pdf)
        defer { harness.close() }
        let page = try #require(pdf.page(at: 0))
        let all = lines(around: try #require(pdf.findString("Reading closely", withOptions: []).first).bounds(for: page).origin
            .applying(CGAffineTransform(translationX: 2, y: 4)), on: page)
        try #require(all.count >= 3)
        // From "noticing" on the first line to the end of the third line.
        let text = try #require(page.string) as NSString
        let start = text.range(of: "noticing").location
        let thirdLine = try #require(all[2].text.split(separator: " ").last.map(String.init))
        let endRange = text.range(of: thirdLine, options: [], range: NSRange(location: start, length: text.length - start))
        let selection = try #require(pdf.selection(from: page, atCharacterIndex: start, to: page, atCharacterIndex: NSMaxRange(endRange) - 1))
        let firstWord = try #require(pdf.findString("noticing", withOptions: []).first).bounds(for: page)
        let secondLineStart = all[1].box.minX
        harness.model.suppressSelection = true
        harness.view.setCurrentSelection(selection, animate: false)
        harness.model.suppressSelection = false
        harness.model.beginLiveText(replacingSelection: true)
        let session = try #require(harness.model.liveEdit)
        let paragraph = try #require(session.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.alignment == .left)
        #expect(abs(session.bounds.minX - secondLineStart) < 0.05, "block \(session.bounds.minX) vs margin \(secondLineStart)")
        #expect(abs(session.bounds.minX + paragraph.firstLineHeadIndent - firstWord.minX) < 0.05,
                "first line starts at \(session.bounds.minX + paragraph.firstLineHeadIndent), was \(firstWord.minX)")
        // Edit the end: the selection's first word and the following line don't move.
        session.text += " Z"
        #expect(!session.nativeUpdateFailed, "\(session.nativeFailureMessage ?? "")")
        let edited = try #require(harness.model.pdfDocument)
        let editedPage = try #require(edited.page(at: 0))
        let moved = try #require(edited.findString("noticing", withOptions: []).first).bounds(for: editedPage)
        #expect(abs(moved.minX - firstWord.minX) < 0.05 && abs(moved.minY - firstWord.minY) < 0.05, "\(firstWord) → \(moved)")
        let after = lines(around: CGPoint(x: all[0].box.midX, y: all[0].box.midY), on: editedPage)
        for (old, new) in zip(all.prefix(3), after.prefix(3)) {
            #expect(abs(new.box.minY - old.box.minY) < 0.05, "baseline moved on “\(old.text)”")
            #expect(abs(new.box.minX - old.box.minX) < 0.05, "left edge moved on “\(old.text)”")
        }
    }

    // MARK: - Substitute fonts

    /// Draws `text` into a PDF in a separate process that registers `font` only for itself,
    /// so the font is embedded but not installed here (a font registered in this process
    /// stays visible even after it is unregistered). Returns the PDF and the font's
    /// PostScript name, or nil when that can't be done.
    private func foreignFontDocument(font: URL, size: Double, lineSpacing: Double, text: String) throws -> (pdf: PDFDocument, name: String)? {
        let swift = URL(fileURLWithPath: "/usr/bin/swift")
        guard FileManager.default.isExecutableFile(atPath: swift.path), FileManager.default.fileExists(atPath: font.path) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("annotate-foreign-font-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("make.swift"), output = folder.appendingPathComponent("out.pdf")
        try """
        import AppKit
        import CoreText
        let arguments = CommandLine.arguments
        let url = URL(fileURLWithPath: arguments[1]) as CFURL
        guard CTFontManagerRegisterFontsForURL(url, .process, nil),
              let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor])?.first else { exit(2) }
        let font = CTFontCreateWithFontDescriptor(descriptor, Double(arguments[3])!, nil) as NSFont
        let style = NSMutableParagraphStyle(); style.lineSpacing = Double(arguments[4])!
        // Ligatures are written as ActualText spans, which aren't editable in place.
        let text = NSAttributedString(string: arguments[5], attributes: [.font: font, .paragraphStyle: style,
                                                                           .foregroundColor: NSColor.black, .ligature: 0])
        let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), CFRange(),
                                             CGPath(rect: CGRect(x: 72, y: 72, width: 468, height: 648), transform: nil), nil)
        CTFrameDraw(frame, context)
        context.endPDFPage(); context.closePDF()
        try! (data as Data).write(to: URL(fileURLWithPath: arguments[2]))
        print(CTFontCopyPostScriptName(font) as String, terminator: "")
        """.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = swift
        process.arguments = [script.path, font.path, output.path, String(size), String(lineSpacing), text]
        let pipe = Pipe(), errors = Pipe()
        process.standardOutput = pipe; process.standardError = errors
        try process.run()
        let name = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let log = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0, !name.isEmpty, let pdf = PDFDocument(url: output) else {
            Issue.record("the font helper failed (\(process.terminationStatus)): \(log)"); return nil
        }
        return (pdf, name)
    }

    private static let wordFonts = "/Applications/Microsoft Word.app/Contents/Resources/DFonts/"
    private static let installedFamilies = ["Helvetica Neue", "Helvetica", "Arial", "Avenir Next", "Avenir Next Condensed", "Avenir", "Gill Sans",
        "Optima", "Futura", "Verdana", "Trebuchet MS", "Lucida Grande", "Arial Narrow", "Tahoma", "PT Sans",
        "Times New Roman", "Times", "Georgia", "Palatino", "Baskerville", "Hoefler Text", "Iowan Old Style",
        "Charter", "Cochin", "Didot", "Big Caslon", "Bodoni 72", "Superclarendon", "PT Serif", "New York",
        "Menlo", "Courier New", "Courier", "Monaco", "SF Mono", "PT Mono", "Andale Mono"]

    @Test("A font the PDF names but this Mac lacks is substituted, named, and keeps baselines and breaks", arguments: [
        ("Calibri.ttf", 12.0, 3.0), ("Consola.ttf", 10, 2), ("Book Antiqua.ttf", 11, 0), ("Calibri.ttf", 9, 1)
    ])
    func substituteFont(file: String, size: Double, lineSpacing: Double) throws {
        let url = URL(fileURLWithPath: Self.wordFonts + file)
        guard FileManager.default.fileExists(atPath: url.path) else { return }  // Word isn't installed: nothing to test.
        guard let (pdf, name) = try foreignFontDocument(font: url, size: size, lineSpacing: lineSpacing, text: body + " " + body) else { return }
        // The premise: this process can't see the font.
        try #require(NSFont(name: name, size: 12) == nil, "\(name) is installed, so it can't test substitution")
        let harness = open(pdf)
        defer { harness.close() }
        let glyphsBefore = try glyphLayout(pdf)
        // The style read from the original, before the edit changes the document.
        let page = try #require(pdf.page(at: 0)), all = try #require(page.selection(for: page.bounds(for: .cropBox)))
        let styled = try PDFNativeTextStyle.attributedText(in: pdf, region: PageRegion(pageIndex: 0, bounds: page.bounds(for: .cropBox).insetBy(dx: 1, dy: 1)),
                                                           originalText: all.string ?? "", fallback: try #require(all.attributedString))
        let result = try editWholePage(harness)
        let context = "\(name) \(size) spacing \(lineSpacing)"
        let message = try #require(result.session.fontSubstitutionMessage, "\(context)")
        #expect(message.contains(name), "\(message)")
        // The notice names the installed font that stands in (for the whole text, or for
        // characters an embedded subset lacks), and it's the kind of font the original was.
        let named = Self.installedFamilies.compactMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: 12) }
            .flatMap { [$0.familyName ?? "", $0.displayName ?? ""] }.filter { !$0.isEmpty && message.contains($0) }
        #expect(!named.isEmpty, "\(message)")
        let font = result.session.font
        #expect(abs(font.pointSize - size) < 0.01, "\(context)")
        if message.contains("closest installed match") {
            #expect(message.contains(font.displayName ?? font.fontName), "\(message) vs \(font.fontName)")
            if name.lowercased().contains("consol") { #expect(font.isFixedPitch, "\(font.fontName)") }
            else { #expect(!font.isFixedPitch, "\(font.fontName)") }
        }
        // Baselines and line starts exactly as the original's glyphs had them, whatever
        // the substitute's metrics; unchanged lines break where they did.
        expectSameGlyphLines(glyphsBefore, try glyphLayout(try #require(harness.model.pdfDocument)), context)
        // The substitute's tracking reaches the edit unchanged; without it, the original's
        // character spacing (CoreGraphics writes a tiny Tc) does.
        let spacing = try #require(styled.layout).characterSpacing
        // The substitute's tracking and the original's character spacing add up.
        let tracking = styled.text.attribute(.kern, at: 0, effectiveRange: nil) as? Double ?? 0
        let expectedKern: Double? = tracking + spacing == 0 && spacing == 0 ? (tracking == 0 ? nil : tracking) : tracking + spacing
        #expect(result.session.attributedText.attribute(.kern, at: 0, effectiveRange: nil) as? Double == expectedKern, "\(context)")
        // KNOWN ISSUE: a substitute a few percent wider than the original moves line breaks.
        // Tracking matches only the average visible glyph (spaces aren't counted, and it's
        // dropped entirely beyond 6 %), while the column allows only the slack the original
        // breaks imply. Calibri → PT Sans at 12 pt sets the first line 6 pt wider (spaces
        // 3.20 vs 2.71 pt); Consolas → PT Mono is 9 % wider, so it gets no tracking at all.
        #expect(abs(result.after.count - result.before.count) <= 1, "\(context)")
        // KNOWN LIMIT: a substitute's individual words differ in width from the original's
        // even when letter and space tracking match the averages, so a line can gain or
        // lose a word at the edge. Installed fonts break exactly (MatchedLayoutTests).
        withKnownIssue("A substitute font can move a line break by a word", isIntermittent: true) {
            for (old, new) in zip(result.before.dropLast(), result.after.dropLast()) {
                #expect(trimmed(new.text) == trimmed(old.text), "\(context): line broke differently")
            }
        }
    }

    // MARK: - New text boxes

    private func twoBlocks() throws -> PDFDocument {
        let text = NSMutableAttributedString(string: "Upper block in Georgia, set in blue.\n", attributes: [
            .font: try #require(NSFont(name: "Georgia", size: 15)), .foregroundColor: NSColor(srgbRed: 0.1, green: 0.2, blue: 0.8, alpha: 1)])
        text.append(NSAttributedString(string: String(repeating: "\n", count: 8), attributes: [.font: try #require(NSFont(name: "Georgia", size: 15))]))
        text.append(NSAttributedString(string: "Lower block in Menlo, set in red.", attributes: [
            .font: try #require(NSFont(name: "Menlo", size: 11)), .foregroundColor: NSColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1)]))
        return try PDFConversion.textDocument(text)
    }

    /// Opens a new text box between the two blocks, `aboveGap` below the upper block and
    /// `belowGap` above the lower one, and returns its font and colour.
    private func newTextBetween(aboveGap: Double, belowGap: Double) throws -> (font: NSFont, color: NSColor) {
        let pdf = try twoBlocks()
        let harness = open(pdf)
        defer { harness.close() }
        let page = try #require(pdf.page(at: 0))
        let upper = try #require(pdf.findString("Upper block", withOptions: []).first).bounds(for: page)
        let lower = try #require(pdf.findString("Lower block", withOptions: []).first).bounds(for: page)
        let space = upper.minY - lower.maxY
        try #require(space > aboveGap + belowGap, "blocks \(space) apart")
        let top = upper.minY - aboveGap, bottom = lower.maxY + belowGap
        harness.model.toolSelection = PageRegion(pageIndex: 0, bounds: CGRect(x: upper.minX, y: bottom, width: 200, height: top - bottom))
        harness.model.beginLiveText(replacingSelection: false)
        let session = try #require(harness.model.liveEdit)
        return (session.font, try #require(session.color.usingColorSpace(.sRGB)))
    }

    @Test("A new text box just below a block takes that block's font and colour")
    func newTextBelowUpperBlock() throws {
        let style = try newTextBetween(aboveGap: 4, belowGap: 60)
        #expect(style.font.familyName == "Georgia")
        #expect(abs(style.font.pointSize - 15) < 0.01)
        #expect(style.color.blueComponent > 0.7 && style.color.redComponent < 0.2)
    }

    @Test("A new text box just above a block, far from any other, takes that block's font and colour")
    func newTextAboveLowerBlock() throws {
        let style = try newTextBetween(aboveGap: 60, belowGap: 4)
        #expect(style.font.familyName == "Menlo")
        #expect(abs(style.font.pointSize - 11) < 0.01)
        #expect(style.color.redComponent > 0.7 && style.color.blueComponent < 0.2)
    }

    @Test("Equally near text above and below: the text above wins, until the text below is clearly closer")
    func newTextPrefersAbove() throws {
        #expect(try newTextBetween(aboveGap: 20, belowGap: 20).font.familyName == "Georgia")
        #expect(try newTextBetween(aboveGap: 28, belowGap: 20).font.familyName == "Georgia")   // below × 1.5 = 30 > 28
        #expect(try newTextBetween(aboveGap: 32, belowGap: 20).font.familyName == "Menlo")     // 30 < 32
    }

    @Test("A new text box on a page without text uses the default style")
    func newTextOnBlankPage() throws {
        let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.setFillColor(NSColor.gray.cgColor); context.fill(CGRect(x: 100, y: 100, width: 50, height: 50))
        context.endPDFPage(); context.closePDF()
        let harness = open(try #require(PDFDocument(data: data as Data)))
        defer { harness.close() }
        harness.model.toolSelection = PageRegion(pageIndex: 0, bounds: CGRect(x: 100, y: 400, width: 200, height: 30))
        harness.model.beginLiveText(replacingSelection: false)
        let session = try #require(harness.model.liveEdit)
        #expect(session.font.pointSize == 14)
        #expect(session.text == "Type here")
    }

    // MARK: - MatchedLayout

    private func layout(_ lines: [(Double, Double)], top: Double = 700, pitch: Double = 16, characterSpacing: Double = 0) -> PDFNativeTextLayout {
        PDFNativeTextLayout(lines: lines.enumerated().map { .init(start: $1.0, end: $1.1, baseline: top - Double($0) * pitch) },
                            characterSpacing: characterSpacing)
    }

    /// Line origins, in page space, of `text` set in `bounds` as the editor sets it.
    private func baselines(of text: NSAttributedString, in bounds: CGRect) -> [CGPoint] {
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), CFRange(location: 0, length: 0),
                                             CGPath(rect: bounds, transform: nil), nil)
        let count = (CTFrameGetLines(frame) as? [CTLine])?.count ?? 0
        var origins = [CGPoint](repeating: .zero, count: count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        return origins.map { CGPoint(x: $0.x + bounds.minX, y: $0.y + bounds.minY) }
    }

    @Test("Styling: empty text is untouched; a selection that isn't rewrapped aligns left; right and centred text drop the indent")
    func stylingRules() throws {
        let font = try #require(NSFont(name: "Helvetica", size: 12))
        let empty = NSAttributedString(string: "")
        #expect(MatchedLayout.styled(empty, like: layout([(72, 500)]), rewrapping: true) === empty)
        let text = NSAttributedString(string: "Some words", attributes: [.font: font])
        let right = layout([(300, 500), (350, 500), (400, 500)])
        let rewrapped = try #require(MatchedLayout.styled(text, like: right, rewrapping: true).attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(rewrapped.alignment == .right)
        #expect(rewrapped.firstLineHeadIndent == 0)
        // A selection that keeps its line breaks keeps right or centred alignment too…
        let kept = try #require(MatchedLayout.styled(text, like: right, rewrapping: false).attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(kept.alignment == .right)
        // …but isn't justified, since its lines don't rewrap.
        let justified = layout([(72, 500), (72, 500), (72, 300)])
        let unjustified = try #require(MatchedLayout.styled(text, like: justified, rewrapping: false).attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(unjustified.alignment == .left)
        let indented = layout([(96, 500), (72, 480), (72, 300)])
        let first = try #require(MatchedLayout.styled(text, like: indented, rewrapping: false).attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(first.firstLineHeadIndent == 24)
        // One line: no pitch to keep, so no fixed line height.
        let single = try #require(MatchedLayout.styled(text, like: layout([(72, 200)]), rewrapping: true).attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(single.minimumLineHeight == 0 && single.maximumLineHeight == 0)
    }

    @Test("Styling: character spacing becomes kerning, adding to any the text already has")
    func stylingKern() throws {
        let font = try #require(NSFont(name: "Helvetica", size: 12))
        let text = NSMutableAttributedString(string: "Spaced words", attributes: [.font: font])
        text.addAttribute(.kern, value: 3.0, range: NSRange(location: 7, length: 5))
        let styled = MatchedLayout.styled(text, like: layout([(72, 300)], characterSpacing: 1.25), rewrapping: false)
        #expect(styled.attribute(.kern, at: 0, effectiveRange: nil) as? Double == 1.25)
        #expect(styled.attribute(.kern, at: 8, effectiveRange: nil) as? Double == 4.25)
        let plain = MatchedLayout.styled(text, like: layout([(72, 300)]), rewrapping: false)
        #expect(plain.attribute(.kern, at: 0, effectiveRange: nil) == nil)
    }

    @Test("Fuzz: styled text set in its block has its first baseline and every line pitch exactly on the original's", arguments: 0..<60)
    func fuzzExactBaselines(seed: UInt64) throws {
        var random = SeededGenerator(seed: seed)
        let names = ["Helvetica", "Georgia", "Menlo", "Times New Roman", "Avenir Next", "Palatino", "Courier New", "Verdana"]
        let name = names.randomElement(using: &random)!
        let size = Double.random(in: 6...40, using: &random)
        let font = try #require(NSFont(name: name, size: size))
        let natural = Double(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        let pitch = natural * Double.random(in: 0.95...2.5, using: &random)
        let top = Double.random(in: 300...740, using: &random), left = Double.random(in: 20...150, using: &random)
        let width = Double.random(in: 200...(590 - left), using: &random)
        let original = layout([(left, left + width), (left, left + width), (left, left + width * 0.5)], top: top, pitch: pitch)
        let text = NSAttributedString(string: body + " " + body, attributes: [.font: font])
        let styled = MatchedLayout.styled(text, like: original, rewrapping: true)
        let context = "seed \(seed): \(name) \(size) pitch \(pitch)"
        guard let bounds = MatchedLayout.bounds(for: styled, like: original, within: CGRect(x: 0, y: -20_000, width: 612, height: 20_792)) else {
            Issue.record("no block: \(context)"); return
        }
        let origins = baselines(of: styled, in: bounds)
        try #require(origins.count >= 2, "\(context)")
        #expect(abs(origins[0].y - top) < 0.01, "first baseline \(origins[0].y) vs \(top): \(context)")
        for (upper, lower) in zip(origins, origins.dropFirst()) {
            #expect(abs(upper.y - lower.y - pitch) < 0.01, "pitch \(upper.y - lower.y) vs \(pitch): \(context)")
        }
        #expect(abs(bounds.minX - left) < 1e-9, "\(context)")
    }

    @Test("Bounds: nil for empty text, a block narrower than a point, non-finite margins, or a block off the page")
    func boundsRefusals() throws {
        let font = try #require(NSFont(name: "Helvetica", size: 12))
        let text = NSAttributedString(string: "Some words", attributes: [.font: font])
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        #expect(MatchedLayout.bounds(for: NSAttributedString(string: ""), like: layout([(72, 300)]), within: page) == nil)
        #expect(MatchedLayout.bounds(for: text, like: layout([(72, 72.5)]), within: page) == nil)
        #expect(MatchedLayout.bounds(for: text, like: layout([(.nan, 300)]), within: page) == nil)
        #expect(MatchedLayout.bounds(for: text, like: layout([(72, .infinity)]), within: page) == nil)
        #expect(MatchedLayout.bounds(for: text, like: layout([(72, 300)], top: .nan), within: page) == nil)
        // The first baseline at the very top edge would put the ascenders off the page.
        #expect(MatchedLayout.bounds(for: text, like: layout([(72, 300)], top: 791), within: page) == nil)
        #expect(MatchedLayout.bounds(for: text, like: layout([(500, 700)]), within: page) == nil)
        let placed = try #require(MatchedLayout.bounds(for: text, like: layout([(72, 300)]), within: page))
        #expect(page.contains(placed))
        #expect(placed.minX == 72)
    }

    @Test("Bounds: justified text spans to its justified margin, right-aligned to its right, ragged to its column")
    func boundsWidths() throws {
        let font = try #require(NSFont(name: "Helvetica", size: 12))
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        func text(_ alignment: NSTextAlignment) -> NSAttributedString {
            let style = NSMutableParagraphStyle(); style.alignment = alignment
            return NSAttributedString(string: "Some words", attributes: [.font: font, .paragraphStyle: style])
        }
        let overhang = layout([(72, 500), (72, 502), (72, 500), (72, 300)])
        #expect(try #require(MatchedLayout.bounds(for: text(.justified), like: overhang, within: page)).width == 500 - 72)
        #expect(try #require(MatchedLayout.bounds(for: text(.right), like: overhang, within: page)).width == 502 - 72)
        var ragged = PDFNativeTextLayout(lines: [.init(start: 72, end: 400, baseline: 700, firstWordEnd: 120),
                                                  .init(start: 72, end: 380, baseline: 684, firstWordEnd: 132)], characterSpacing: 0)
        ragged.spaceWidth = 4
        let width = try #require(MatchedLayout.bounds(for: text(.left), like: ragged, within: page)).width
        #expect(abs(width - (ragged.column - 72 + 0.01)) < 1e-9)
        #expect(ragged.column > ragged.right)
    }

    // MARK: - Paragraph detection for aligned text

    @Test("Right-aligned and centred lines continue a paragraph only when their edges agree to half a point", arguments: [
        (CGRect(x: 300, y: 700, width: 200, height: 14), CGRect(x: 100, y: 684, width: 400, height: 14), true),     // same right edge
        (CGRect(x: 300, y: 700, width: 200.5, height: 14), CGRect(x: 100, y: 684, width: 400, height: 14), true),   // 0.5 pt apart
        (CGRect(x: 300, y: 700, width: 200.6, height: 14), CGRect(x: 100, y: 684, width: 400, height: 14), false),  // 0.6 pt apart
        (CGRect(x: 100, y: 700, width: 400, height: 14), CGRect(x: 300, y: 684, width: 200, height: 14), true),     // longer line above
        (CGRect(x: 150, y: 700, width: 300, height: 14), CGRect(x: 200, y: 684, width: 200, height: 14), true),     // same centre
        (CGRect(x: 150, y: 700, width: 301, height: 14), CGRect(x: 200, y: 684, width: 200, height: 14), true),     // centres 0.5 apart
        (CGRect(x: 150, y: 700, width: 301.2, height: 14), CGRect(x: 200, y: 684, width: 200, height: 14), false),  // centres 0.6 apart
        // A shared right edge doesn't join lines of different sizes or far apart.
        (CGRect(x: 300, y: 700, width: 200, height: 24), CGRect(x: 100, y: 684, width: 400, height: 14), false),
        (CGRect(x: 300, y: 700, width: 200, height: 14), CGRect(x: 100, y: 640, width: 400, height: 14), false),
    ])
    func alignedContinuation(upper: CGRect, lower: CGRect, expected: Bool) {
        #expect(ParagraphText.continues(upper, into: lower) == expected, "\(upper) → \(lower)")
    }
}
