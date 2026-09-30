import AppKit
import CoreGraphics
import CoreText
import PDFKit
import Testing
@testable import AnnotateCore

/// The reflow planner decides which drawing below an edited paragraph moves, and stops
/// at the first gap that absorbs the change.
@Suite("Minimal reflow planning", .serialized)
@MainActor
struct NativeReflowPlanTests {
    /// A page of paragraphs set by CoreText, one line per text object, as macOS writes them.
    private func page(_ paragraphs: [String], gapAfter: [Int: CGFloat] = [:], rule: CGRect? = nil,
                      image: CGRect? = nil) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let font = try #require(NSFont(name: "Helvetica", size: 12))
        var top: CGFloat = 720
        for (index, paragraph) in paragraphs.enumerated() {
            let text = NSAttributedString(string: paragraph, attributes: [.font: font, .ligature: 0])
            let setter = CTFramesetterCreateWithAttributedString(text)
            let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: 400, height: 1000), nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(x: 72, y: top - size.height, width: 400, height: size.height), transform: nil), nil)
            CTFrameDraw(frame, context)
            top -= size.height + (gapAfter[index] ?? 6)
        }
        if let rule { context.setFillColor(NSColor.gray.cgColor); context.fill(rule) }
        if let image, let bitmap = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
           let picture = bitmap.makeImage() { context.draw(picture, in: image) }
        context.endPDFPage(); context.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }

    private func program(_ document: PDFDocument) throws -> PDFNativeTextProgram {
        let bytes = try #require(document.dataRepresentation())
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let source = try #require(CGPDFDocument(provider))
        let dictionary = try #require(source.page(at: 1)?.dictionary)
        var data = Data()
        if let stream = nativeStream(dictionary, "Contents") { data = try nativeDecodedStream(stream) }
        else if let contents = nativeArray(dictionary, "Contents") {
            for index in 0..<CGPDFArrayGetCount(contents) {
                var stream: CGPDFStreamRef?
                if CGPDFArrayGetStream(contents, index, &stream), let stream { data.append(try nativeDecodedStream(stream)); data.append(10) }
            }
        }
        return try PDFNativeTextProgram(data: data, resources: PDFNativeTextEditor.inheritedResources(dictionary))
    }

    /// The first paragraph's block on the page.
    private func block(_ document: PDFDocument, _ phrase: String) throws -> CGRect {
        let page = try #require(document.page(at: 0))
        let hit = try #require(document.findString(phrase, withOptions: []).first)
        return hit.bounds(for: page)
    }

    private let first = "The first paragraph is the one being edited. It runs over two lines at this width so there is something to grow."
    private let second = "The second paragraph sits right below it and must move down with it, keeping the same gap between them."
    private let third = "The third paragraph follows after a wide gap, which absorbs the change, so it stays exactly where it is."

    @Test("Growing a paragraph moves what follows it down to the first gap wide enough, and no further")
    func growsToFirstWideGap() throws {
        let document = try page([first, second, third], gapAfter: [1: 60])
        let program = try program(document)
        let units = try PDFNativeReflow.units(of: program)
        let paragraph = try block(document, "The first paragraph").union(try block(document, "something to grow."))
        let plan = try PDFNativeReflow.plan(PDFNativeReflowRequest(delta: 14, block: paragraph, minimumGap: 14), units: units,
                                            page: CGRect(x: 0, y: 0, width: 612, height: 792))
        #expect(plan.offset == -14)
        let movedTexts = plan.moving.compactMap { index -> Double? in units[index].bounds.maxY }
        let secondTop = try block(document, "The second paragraph").maxY
        let thirdTop = try block(document, "The third paragraph").maxY
        // The second paragraph's lines move; the third paragraph's don't.
        #expect(movedTexts.contains { abs($0 - secondTop) < 3 })
        #expect(!movedTexts.contains { abs($0 - thirdTop) < 3 })
        #expect(plan.region.minY > thirdTop)
    }

    @Test("With no gap wide enough before the page's end, nothing moves and the reason is given")
    func refusesAtPageEnd() throws {
        let long = Array(repeating: second, count: 12)
        let document = try page([first] + long)
        let program = try program(document)
        let units = try PDFNativeReflow.units(of: program)
        let paragraph = try block(document, "The first paragraph")
        // The text ends about 226 pt above the bottom margin; 260 more can't fit.
        #expect(throws: PDFNativeReflow.Refusal.edgeOfPage) {
            try PDFNativeReflow.plan(PDFNativeReflowRequest(delta: 260, block: paragraph, minimumGap: 14), units: units,
                                     page: CGRect(x: 0, y: 0, width: 612, height: 792))
        }
    }

    @Test("A shorter paragraph pulls what follows up by the same amount")
    func shrinks() throws {
        let document = try page([first, second, third], gapAfter: [1: 60])
        let units = try PDFNativeReflow.units(of: try program(document))
        let paragraph = try block(document, "The first paragraph")
        let plan = try PDFNativeReflow.plan(PDFNativeReflowRequest(delta: -14, block: paragraph, minimumGap: 14), units: units,
                                            page: CGRect(x: 0, y: 0, width: 612, height: 792))
        #expect(plan.offset == 14)
        #expect(!plan.moving.isEmpty)
    }

    /// Where artwork sits directly under the second paragraph, so it must move with it.
    private func underSecond() throws -> (rule: CGRect, picture: CGRect) {
        let bottom = try block(try page([first, second], gapAfter: [1: 200]), "keeping the same gap").minY
        return (CGRect(x: 72, y: bottom - 5, width: 400, height: 1), CGRect(x: 72, y: bottom - 50, width: 40, height: 40))
    }

    @Test("Paths and images below the paragraph move with the text around them")
    func movesArtwork() throws {
        let (rule, picture) = try underSecond()
        let document = try page([first, second], gapAfter: [1: 200], rule: rule, image: picture)
        let units = try PDFNativeReflow.units(of: try program(document))
        #expect(units.contains { if case .wrapped = $0.kind { abs($0.bounds.midY - rule.midY) < 1 } else { false } })
        #expect(units.contains { if case .wrapped = $0.kind { abs($0.bounds.midY - picture.midY) < 1 } else { false } })
        let paragraph = try block(document, "The first paragraph")
        let plan = try PDFNativeReflow.plan(PDFNativeReflowRequest(delta: 14, block: paragraph, minimumGap: 14), units: units,
                                            page: CGRect(x: 0, y: 0, width: 612, height: 792))
        let moved = plan.moving.map { units[$0].bounds }
        #expect(moved.contains { abs($0.midY - rule.midY) < 1 })
        #expect(moved.contains { abs($0.midY - picture.midY) < 1 })
    }

    @Test("Replacements offset text matrices and wrap artwork in a local translation")
    func replacementsTranslate() throws {
        let rule = try underSecond().rule
        let document = try page([first, second], gapAfter: [1: 200], rule: rule)
        let program = try program(document)
        let units = try PDFNativeReflow.units(of: program)
        let paragraph = try block(document, "The first paragraph")
        let plan = try PDFNativeReflow.plan(PDFNativeReflowRequest(delta: 14, block: paragraph, minimumGap: 14), units: units,
                                            page: CGRect(x: 0, y: 0, width: 612, height: 792))
        let replacements = try PDFNativeReflow.replacements(moving: plan.moving, units: units, offset: plan.offset,
                                                            operations: program.operations, source: Array(program.data))
        #expect(replacements.values.contains { $0.hasPrefix("BT") && $0.contains("Tm") })
        #expect(replacements.values.contains { $0.hasPrefix("q 1 0 0 1 0 -14 cm") })
        #expect(replacements.values.contains { $0.hasSuffix("\nQ") })
    }

    @Test("Nothing to do for a change under a hundredth of a point, or a non-finite one", arguments: [0.0, 0.004, .nan, .infinity])
    func noChange(delta: Double) throws {
        let document = try page([first, second])
        let units = try PDFNativeReflow.units(of: try program(document))
        let plan = try PDFNativeReflow.plan(PDFNativeReflowRequest(delta: delta, block: try block(document, "The first paragraph"), minimumGap: 14),
                                            units: units, page: CGRect(x: 0, y: 0, width: 612, height: 792))
        #expect(plan.moving.isEmpty && plan.offset == 0)
    }

    @Test("End to end: a taller replacement moves the next paragraph down by exactly the change and leaves the rest")
    func replaceWithReflow() throws {
        let document = try page([first, second, third], gapAfter: [1: 80])
        let pageBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let firstBlock = try block(document, "The first paragraph").union(try block(document, "something to grow."))
        let secondBefore = try block(document, "The second paragraph")
        let thirdBefore = try block(document, "The third paragraph")
        let original = try #require(document.page(at: 0)?.selection(for: firstBlock.insetBy(dx: -1, dy: -1))?.string)
        let font = try #require(NSFont(name: "Helvetica", size: 12))
        let longer = NSAttributedString(string: first + " It now has a whole extra sentence, long enough to need a third line here.",
                                        attributes: [.font: font, .ligature: 0])
        let destination = CGRect(x: firstBlock.minX, y: firstBlock.minY - 30, width: 400, height: firstBlock.height + 30)
        let (edited, moved) = try PDFNativeTextEditor.replace(in: document, region: PageRegion(pageIndex: 0, bounds: firstBlock),
            originalText: original, replacement: longer, destination: PageRegion(pageIndex: 0, bounds: destination),
            reflow: PDFNativeReflowRequest(delta: 30, block: firstBlock, minimumGap: 14))
        let result = try #require(moved)
        #expect(result.offset == -30)
        let bytes = try #require(edited.dataRepresentation())
        let saved = try #require(PDFDocument(data: bytes))
        let page = try #require(saved.page(at: 0))
        let secondAfter = try #require(saved.findString("The second paragraph", withOptions: []).first).bounds(for: page)
        let thirdAfter = try #require(saved.findString("The third paragraph", withOptions: []).first).bounds(for: page)
        #expect(abs(secondAfter.minY - (secondBefore.minY - 30)) < 0.05, "\(secondBefore) → \(secondAfter)")
        #expect(abs(secondAfter.minX - secondBefore.minX) < 0.05)
        #expect(abs(thirdAfter.minY - thirdBefore.minY) < 0.05, "the third paragraph must not move")
        #expect(saved.findString("whole extra sentence", withOptions: []).count == 1)
    }

    @Test("End to end: when the content below can't move, the edit is refused and nothing changes")
    func replaceRefused() throws {
        let long = Array(repeating: second, count: 12)
        let document = try page([first] + long)
        let firstBlock = try block(document, "The first paragraph").union(try block(document, "something to grow."))
        let original = try #require(document.page(at: 0)?.selection(for: firstBlock.insetBy(dx: -1, dy: -1))?.string)
        let font = try #require(NSFont(name: "Helvetica", size: 12))
        #expect(throws: PDFNativeReflowRefusal.self) {
            try PDFNativeTextEditor.replace(in: document, region: PageRegion(pageIndex: 0, bounds: firstBlock), originalText: original,
                replacement: NSAttributedString(string: first, attributes: [.font: font]),
                destination: PageRegion(pageIndex: 0, bounds: firstBlock), reflow: PDFNativeReflowRequest(delta: 300, block: firstBlock, minimumGap: 14))
        }
        #expect(document.findString("The first paragraph", withOptions: []).count == 1)
    }
}
