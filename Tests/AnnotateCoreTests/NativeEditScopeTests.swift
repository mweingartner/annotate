import AppKit
import PDFKit
import Testing
@testable import AnnotateCore

/// `PDFNativeEditScope.editedPage`: the result's other pages are placeholders that keep
/// their place, size and annotations but not their content.
@Suite("Native edits that need only the edited page")
@MainActor
struct NativeEditScopeTests {
    private func replace(_ document: PDFDocument, scope: PDFNativeEditScope) throws -> PDFDocument {
        let selection = try #require(document.findString("attention", withOptions: []).first)
        let page = try #require(document.page(at: 0))
        let region = PageRegion(pageIndex: 0, bounds: selection.bounds(for: page).insetBy(dx: 0, dy: -4))
        return try PDFNativeTextEditor.replace(in: document, region: region, originalText: "attention",
            replacement: NSAttributedString(string: "FOCUS", attributes: [.font: NSFont.systemFont(ofSize: 11)]), scope: scope)
    }

    @Test("Other pages keep their place, size and annotations, and drop their content; the edited page is the same either way")
    func placeholders() throws {
        let document = SamplePDF.make()
        try #require(document.pageCount >= 3)
        // A link on another page that leads to a third: it must survive as a link to that place.
        let linkPage = try #require(document.page(at: 1))
        let link = PDFAnnotation(bounds: CGRect(x: 72, y: 72, width: 100, height: 20), forType: .link, withProperties: nil)
        link.destination = PDFDestination(page: try #require(document.page(at: 2)), at: CGPoint(x: 0, y: 500))
        linkPage.addAnnotation(link)
        let bytes = try #require(document.dataRepresentation())
        let source = try #require(PDFDocument(data: bytes))

        let pageOnly = try replace(source, scope: .editedPage)
        let whole = try replace(source, scope: .wholeDocument)
        #expect(pageOnly.pageCount == source.pageCount)
        #expect(pageOnly.page(at: 0)?.string == whole.page(at: 0)?.string)
        #expect(pageOnly.findString("FOCUS", withOptions: []).count == 1)
        for index in 1..<source.pageCount {
            let original = try #require(source.page(at: index)), placeholder = try #require(pageOnly.page(at: index))
            #expect(placeholder.bounds(for: .mediaBox) == original.bounds(for: .mediaBox), "page \(index + 1)")
            #expect(placeholder.bounds(for: .cropBox) == original.bounds(for: .cropBox), "page \(index + 1)")
            #expect(placeholder.rotation == original.rotation, "page \(index + 1)")
            #expect((placeholder.string ?? "").isEmpty, "page \(index + 1) has no content")
            #expect(placeholder.annotations.count == original.annotations.count, "page \(index + 1)")
        }
        // The link keeps the same destination as in a whole-document edit.
        let wholeLink = try #require(whole.page(at: 1)?.annotations.first { $0.type == "Link" })
        let kept = try #require(pageOnly.page(at: 1)?.annotations.first { $0.type == "Link" })
        #expect(kept.destination?.point == wholeLink.destination?.point)
        #expect(kept.destination?.page.map(pageOnly.index(for:)) == wholeLink.destination?.page.map(whole.index(for:)))
    }

    @Test("A page-only edit's output doesn't grow with the other pages' images")
    func costFollowsEditedPage() throws {
        let document = SamplePDF.make()
        let first = try #require(document.page(at: 0)?.copy() as? PDFPage)
        let heavy = PDFDocument()
        heavy.insert(first, at: 0)
        // Eight pages, each a 1,200-pixel square image of noise that compresses poorly.
        var generator = SystemRandomNumberGenerator()
        for index in 1...8 {
            let side = 1_200
            var pixels = [UInt8](repeating: 0, count: side * side * 4)
            for offset in stride(from: 0, to: pixels.count, by: 8) { let value = UInt64.random(in: 0...UInt64.max, using: &generator); withUnsafeBytes(of: value) { pixels.replaceSubrange(offset..<offset + 8, with: $0) } }
            let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
            let image = try #require(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let page = try #require(PDFPage(image: NSImage(cgImage: image, size: NSSize(width: 612, height: 612))))
            heavy.insert(page, at: index)
        }
        let heavyBytes = try #require(heavy.dataRepresentation())
        let source = try #require(PDFDocument(data: heavyBytes))
        let pageOnly = try #require(try replace(source, scope: .editedPage).dataRepresentation())
        let whole = try #require(try replace(source, scope: .wholeDocument).dataRepresentation())
        #expect(whole.count > 8 * 1_000_000, "\(whole.count)")
        #expect(pageOnly.count * 20 < whole.count, "page-only \(pageOnly.count) bytes, whole \(whole.count)")
    }

    @Test("Without a scope, edits still carry every page")
    func defaultIsWholeDocument() throws {
        let source = SamplePDF.make()
        let result = try replace(source, scope: .wholeDocument)
        for index in 1..<source.pageCount {
            #expect(result.page(at: index)?.string == source.page(at: index)?.string, "page \(index + 1)")
        }
    }

    // MARK: - A hand-written book

    /// The edit target on each page of `book()`; pages 2 and 4 share one content stream.
    private static let bookWords = ["FIRST", "TWIN", "ROTATED", "TWIN", "LAST"]

    /// Five pages that exercise what a placeholder must keep and what the edited page must
    /// still find: resources inherited from the Pages node (pages 1, 2, 4, 5), a content
    /// stream and image shared by pages 2 and 4, a rotated and cropped page 3 with its own
    /// resources naming the same font and image, a smaller last page, a stored thumbnail,
    /// notes, links between pages and an outline.
    private func book(kids: String = "3 0 R 4 0 R 5 0 R 6 0 R 7 0 R", count: Int = 5) throws -> PDFDocument {
        let image = Data((0..<(16 * 12)).flatMap { pixel -> [UInt8] in pixel % 16 < 8 ? [255, 0, 0] : [0, 0, 255] })
        let streams: [Int: Data] = [
            9: image,
            10: Data("BT /F 18 Tf 40 400 Td (FIRST page words) Tj ET q 100 0 0 80 40 200 cm /Im Do Q".utf8),
            11: Data("BT /F 18 Tf 40 400 Td (TWIN page words) Tj ET q 100 0 0 80 40 200 cm /Im Do Q".utf8),
            12: Data("BT /G 18 Tf 60 400 Td (ROTATED page words) Tj ET q 100 0 0 80 60 200 cm /Pic Do Q".utf8),
            13: Data(repeating: 128, count: 4 * 4 * 3),
            14: Data("BT /F 18 Tf 40 300 Td (LAST page words) Tj ET".utf8)
        ]
        return try #require(PDFDocument(data: Self.rawPDF([
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
        ], streams: streams)))
    }

    /// Object N is `objects[N - 1]`. A stream's entry opens its dictionary, which is closed
    /// here with the stream's length.
    static func rawPDF(_ objects: [String], streams: [Int: Data] = [:]) -> Data {
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

    /// Replaces `word` where it appears on page `index` (not on another page sharing it).
    private func edit(_ document: PDFDocument, word: String, page index: Int, scope: PDFNativeEditScope,
                      replacement: String = "NEW") throws -> PDFDocument {
        let page = try #require(document.page(at: index))
        let selection = try #require(document.findString(word, withOptions: []).first { $0.pages.contains(page) })
        let region = PageRegion(pageIndex: index, bounds: selection.bounds(for: page).insetBy(dx: -1, dy: -3))
        return try PDFNativeTextEditor.replace(in: document, region: region, originalText: word,
            replacement: NSAttributedString(string: replacement, attributes: [.font: try #require(NSFont(name: "Helvetica", size: 12))]), scope: scope)
    }

    /// What the page's content draws (no annotations), over its whole media box.
    private func contentPixels(_ page: PDFPage?) throws -> [UInt8] {
        let page = try #require(page), reference = try #require(page.pageRef)
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

    private func largestDifference(_ first: [UInt8], _ second: [UInt8]) -> Int {
        guard first.count == second.count else { return 255 }
        return zip(first, second).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }

    private func cgDocument(_ data: Data) throws -> CGPDFDocument {
        let provider = try #require(CGDataProvider(data: data as CFData))
        return try #require(CGPDFDocument(provider))
    }

    private struct AnnotationSummary: Equatable { let type: String?, bounds: CGRect, contents: String? }
    private func summary(_ page: PDFPage?) -> [AnnotationSummary] {
        (page?.annotations ?? []).map { AnnotationSummary(type: $0.type, bounds: $0.bounds, contents: $0.contents) }
    }

    @Test("Any page can be the edited one (first, last, rotated and cropped, inherited resources, a shared content stream); it matches a whole-document edit and the others are placeholders",
          arguments: 0..<5)
    func everyPage(index: Int) throws {
        let source = try book()
        let before = (0..<source.pageCount).map { source.page(at: $0)?.string }
        let pageOnly = try edit(source, word: Self.bookWords[index], page: index, scope: .editedPage)
        let whole = try edit(source, word: Self.bookWords[index], page: index, scope: .wholeDocument)
        #expect(pageOnly.pageCount == 5 && whole.pageCount == 5)
        // The edited page is the same either way: text, geometry, annotations and what it draws.
        let edited = try #require(pageOnly.page(at: index)), reference = try #require(whole.page(at: index))
        #expect(edited.string == reference.string)
        #expect(edited.string?.contains("NEW") == true)
        #expect(edited.string?.contains(Self.bookWords[index]) == false)
        #expect(edited.rotation == source.page(at: index)?.rotation)
        #expect(edited.bounds(for: .cropBox) == source.page(at: index)?.bounds(for: .cropBox))
        #expect(edited.bounds(for: .mediaBox) == source.page(at: index)?.bounds(for: .mediaBox))
        #expect(summary(edited) == summary(reference))
        #expect(largestDifference(try contentPixels(edited), try contentPixels(reference)) <= 1)
        // The edited page still draws its image, found through inherited or its own resources.
        #expect(try PDFNativeImageEditor.images(in: pageOnly, pageIndex: index).count == (index == 4 ? 0 : 1))
        let blank = [UInt8](repeating: 255, count: try contentPixels(edited).count)
        #expect(try contentPixels(edited) != blank)
        for other in 0..<5 where other != index {
            let original = try #require(source.page(at: other))
            let placeholder = try #require(pageOnly.page(at: other)), kept = try #require(whole.page(at: other))
            #expect(placeholder.bounds(for: .mediaBox) == original.bounds(for: .mediaBox), "page \(other + 1)")
            #expect(placeholder.bounds(for: .cropBox) == original.bounds(for: .cropBox), "page \(other + 1)")
            #expect(placeholder.rotation == original.rotation, "page \(other + 1)")
            #expect(summary(placeholder) == summary(original), "page \(other + 1)")
            #expect((placeholder.string ?? "").isEmpty, "page \(other + 1) carries no text")
            #expect(try contentPixels(placeholder) == [UInt8](repeating: 255, count: try contentPixels(original).count), "page \(other + 1) draws nothing")
            // A whole-document edit leaves the other pages exactly as they were, including
            // the page that shares the edited page's content stream.
            #expect(kept.string == original.string, "page \(other + 1)")
            #expect(largestDifference(try contentPixels(kept), try contentPixels(original)) == 0, "page \(other + 1)")
        }
        // Links on placeholders still lead to the same pages.
        for (page, target) in [(3, 0), (4, 2)] where page != index {
            let link = try #require(pageOnly.page(at: page)?.annotations.first { $0.type == "Link" })
            #expect(link.destination?.page.map(pageOnly.index(for:)) == target)
        }
        let outline = try #require(pageOnly.outlineRoot)
        #expect(outline.numberOfChildren == 2)
        #expect(outline.child(at: 0)?.destination?.page.map(pageOnly.index(for:)) == 4)
        #expect(outline.child(at: 1)?.destination?.page.map(pageOnly.index(for:)) == 3)
        // The source is never changed.
        #expect((0..<source.pageCount).map { source.page(at: $0)?.string } == before)
    }

    @Test("Without a scope argument an edit carries every page")
    func omittedScopeIsWholeDocument() throws {
        let source = try book()
        let page = try #require(source.page(at: 0))
        let selection = try #require(source.findString("FIRST", withOptions: []).first)
        let region = PageRegion(pageIndex: 0, bounds: selection.bounds(for: page).insetBy(dx: -1, dy: -3))
        let replacement = NSAttributedString(string: "EDITED", attributes: [.font: try #require(NSFont(name: "Helvetica", size: 14))])
        let results = [
            try PDFNativeTextEditor.replace(in: source, region: region, originalText: "FIRST", replacement: replacement),
            try PDFNativeTextEditor.replace(in: source, region: region, originalText: "FIRST", replacement: replacement,
                                            destination: region, reflow: nil).document
        ]
        for result in results {
            for index in 1..<5 {
                #expect(result.page(at: index)?.string == source.page(at: index)?.string, "page \(index + 1)")
                #expect(largestDifference(try contentPixels(result.page(at: index)), try contentPixels(source.page(at: index))) == 0)
            }
        }
    }

    @Test("A page tree that lists the edited page twice keeps that page whole, wherever it is listed", arguments: [0, 2])
    func duplicateKids(index: Int) throws {
        // Pages 1 and 3 are one dictionary; page 2 is the rotated page.
        let source = try book(kids: "3 0 R 5 0 R 3 0 R", count: 3)
        try #require(source.pageCount == 3)
        #expect(source.page(at: 0)?.string == source.page(at: 2)?.string)
        // The graph alone: keeping page 3 keeps the dictionary it shares with page 1.
        let data = try #require(source.dataRepresentation())
        let cg = try cgDocument(data)
        let graph = try PDFNativeObjectGraph(document: cg, keepingContentOf: index + 1)
        let copied = try #require(PDFDocument(data: try graph.write()))
        #expect(copied.page(at: 0)?.string == source.page(at: 0)?.string)
        #expect(copied.page(at: 2)?.string == source.page(at: 2)?.string)
        #expect((copied.page(at: 1)?.string ?? "").isEmpty)
        // An edit there applies, and the edited page keeps its content and resources.
        let result = try edit(source, word: "FIRST", page: index, scope: .editedPage)
        let edited = try #require(result.page(at: index))
        #expect(edited.string?.contains("NEW") == true)
        #expect(edited.string?.contains("page words") == true, "the rest of the line stays")
        #expect(try PDFNativeImageEditor.images(in: result, pageIndex: index).count == 1, "its image is still found")
        let resultData = try #require(result.dataRepresentation())
        let resultCG = try cgDocument(resultData)
        let dictionary = try #require(resultCG.page(at: index + 1)?.dictionary)
        let resources = try #require(PDFNativeTextEditor.inheritedResources(dictionary))
        #expect(CGPDFDictionaryGetCount(resources) > 0)
        #expect(nativeStream(dictionary, "Contents") != nil || nativeArray(dictionary, "Contents") != nil)
    }

    @Test("A page number outside the document makes every page a placeholder, and the result still opens", arguments: [0, 6, -3])
    func keepingNoPage(number: Int) throws {
        let source = try book()
        let data = try #require(source.dataRepresentation())
        let cg = try cgDocument(data)
        let copied = try #require(PDFDocument(data: try PDFNativeObjectGraph(document: cg, keepingContentOf: number).write()))
        #expect(copied.pageCount == 5)
        for index in 0..<5 {
            #expect((copied.page(at: index)?.string ?? "").isEmpty)
            #expect(copied.page(at: index)?.rotation == source.page(at: index)?.rotation)
            #expect(summary(copied.page(at: index)) == summary(source.page(at: index)))
        }
    }

    @Test("Scan editing with the edited-page scope matches the whole-document result on a two-page scan that shares its image")
    func scannedEditedPage() async throws {
        // One scanned bitmap drawn on two pages, so both pages show the same image.
        let bitmap = try #require(CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 1600,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(NSColor.white.cgColor); bitmap.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        for (text, y) in [("TARGET", 270), ("NEIGHBOR", 195)] {
            bitmap.textPosition = CGPoint(x: 60, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: try #require(NSFont(name: "Courier", size: 28)), .foregroundColor: NSColor.black])), bitmap)
        }
        let image = try #require(bitmap.makeImage())
        let bytes = NSMutableData(), consumer = try #require(CGDataConsumer(data: bytes as CFMutableData))
        var media = CGRect(x: 0, y: 0, width: 400, height: 400)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        for _ in 0..<2 { context.beginPDFPage(nil); context.draw(image, in: media); context.endPDFPage() }
        context.closePDF()
        let ocr = try await PDFOCR.recognize(document: try #require(PDFDocument(data: bytes as Data)), options: PDFOCROptions(languages: ["en-US"]))
        let source = try #require(PDFDocument(data: ocr.data))
        try #require(source.pageCount == 2)
        let sharedImage = try imageObjects(source, page: 0), otherImage = try imageObjects(source, page: 1)
        #expect(sharedImage.count == 1 && sharedImage == otherImage, "both pages draw one image object")
        let page = try #require(source.page(at: 0))
        let selection = try #require(source.findString("TARGET", withOptions: []).first { $0.pages.contains(page) })
        let region = PageRegion(pageIndex: 0, bounds: selection.bounds(for: page))
        let replacement = NSAttributedString(string: "EDITED", attributes: [.font: try #require(NSFont(name: "Courier-Bold", size: 18)), .foregroundColor: NSColor.systemGreen])
        let pageOnly = try PDFNativeTextEditor.replaceScanned(in: source, region: region, originalText: "TARGET", replacement: replacement, scope: .editedPage)
        let whole = try PDFNativeTextEditor.replaceScanned(in: source, region: region, originalText: "TARGET", replacement: replacement, scope: .wholeDocument)
        #expect(pageOnly.page(at: 0)?.string == whole.page(at: 0)?.string)
        #expect(pageOnly.page(at: 0)?.string?.contains("TARGET") == false)
        #expect(largestDifference(try contentPixels(pageOnly.page(at: 0)), try contentPixels(whole.page(at: 0))) <= 1)
        #expect((pageOnly.page(at: 1)?.string ?? "").isEmpty)
        // The other page keeps the original pixels in the whole result: the patch is not
        // written into the image the two pages shared.
        #expect(whole.page(at: 1)?.string?.contains("TARGET") == true)
        #expect(largestDifference(try contentPixels(whole.page(at: 1)), try contentPixels(source.page(at: 1))) <= 1)
    }

    /// The identities of the image streams a page's resources name, in name order.
    private func imageObjects(_ document: PDFDocument, page index: Int) throws -> [UInt] {
        let cg = try cgDocument(try #require(document.dataRepresentation()))
        let dictionary = try #require(cg.page(at: index + 1)?.dictionary)
        let resources = try #require(PDFNativeTextEditor.inheritedResources(dictionary))
        let objects = try #require(nativeDictionary(resources, "XObject"))
        var found: [(String, UInt)] = []
        CGPDFDictionaryApplyBlock(objects, { key, object, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &stream), let stream { found.append((String(cString: key), UInt(bitPattern: stream.rawValue))) }
            return true
        }, nil)
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    // MARK: - Property: placeholders over generated page trees

    /// SplitMix64: every generated page tree replays from its seed.
    private struct TreeRandom: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 ^ 0xD1B5_4A32_D192_ED03 }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A page tree of nested Pages nodes with inheritable size, crop, rotation and
    /// resources at random levels; leaves that sometimes share content; random notes.
    private func generatedTree(seed: UInt64) throws -> Data {
        var random = TreeRandom(seed: seed)
        var objects: [String] = ["<< /Type /Catalog /Pages 2 0 R >>", ""]
        var streams: [Int: Data] = [:]
        func add(_ object: String, stream: Data? = nil) -> Int {
            objects.append(object)
            if let stream { streams[objects.count] = stream }
            return objects.count
        }
        let font = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        var leaves = 0, lastContent: Int?
        func inheritable() -> String {
            var entries = ""
            if Bool.random(using: &random) { entries += " /Rotate \([0, 90, 180, 270].randomElement(using: &random)!)" }
            if Bool.random(using: &random) { entries += " /CropBox [\(Int.random(in: 0...20, using: &random)) 10 300 400]" }
            if Bool.random(using: &random) { entries += " /Resources << /Font << /F \(font) 0 R >> >>" }
            if Int.random(in: 0..<4, using: &random) == 0 { entries += " /MediaBox [0 0 \(Int.random(in: 320...420, using: &random)) 450]" }
            return entries
        }
        func node(parent: Int, id: Int, depth: Int) -> Int {
            var kids: [Int] = [], count = 0
            for _ in 0..<Int.random(in: 1...3, using: &random) {
                if depth < 3, Int.random(in: 0..<3, using: &random) == 0 {
                    let child = add("")
                    let (childID, childCount) = (child, node(parent: id, id: child, depth: depth + 1))
                    kids.append(childID); count += childCount
                } else {
                    leaves += 1
                    let content: Int
                    if let lastContent, Int.random(in: 0..<4, using: &random) == 0 { content = lastContent }
                    else { content = add("<<", stream: Data("BT /F 14 Tf 30 300 Td (Leaf \(leaves) text) Tj ET".utf8)) }
                    lastContent = content
                    let notes = (0..<Int.random(in: 0...2, using: &random)).map { note in
                        add("<< /Type /Annot /Subtype /Text /Rect [\(40 + note * 30) 40 \(64 + note * 30) 64] /Contents (Leaf \(leaves) note \(note)) >>")
                    }
                    let annots = notes.isEmpty ? "" : " /Annots [" + notes.map { "\($0) 0 R" }.joined(separator: " ") + "]"
                    // Every leaf finds /F: from itself or, failing that, from the root.
                    kids.append(add("<< /Type /Page /Parent \(id) 0 R /Contents \(content) 0 R\(inheritable())\(annots) >>"))
                    count += 1
                }
            }
            objects[id - 1] = "<< /Type /Pages\(id == 2 ? " /MediaBox [0 0 400 500] /Resources << /Font << /F \(font) 0 R >> >>" : inheritable()) /Kids ["
                + kids.map { "\($0) 0 R" }.joined(separator: " ") + "] /Count \(count)" + (id == 2 ? "" : " /Parent \(parent) 0 R") + " >>"
            return count
        }
        _ = node(parent: 0, id: 2, depth: 0)
        return Self.rawPDF(objects, streams: streams)
    }

    @Test("Generated page trees: keeping one page keeps its content and every page's place, size, rotation and notes; the rest draw nothing; output is deterministic",
          arguments: 1...24)
    func generatedTrees(seed: UInt64) throws {
        let data = try generatedTree(seed: seed)
        let source = try #require(PDFDocument(data: data), "seed \(seed)")
        let cg = try cgDocument(data)
        let count = source.pageCount
        try #require(count >= 1 && count == cg.numberOfPages, "seed \(seed)")
        let whole = try PDFNativeObjectGraph(document: cg).write()
        for keep in 1...count {
            let output = try PDFNativeObjectGraph(document: cg, keepingContentOf: keep).write()
            #expect(try PDFNativeObjectGraph(document: cg, keepingContentOf: keep).write() == output, "seed \(seed), page \(keep): deterministic")
            // A placeholder can outgrow its page only by the empty resources it gains.
            #expect(output.count <= whole.count + 24 * count, "seed \(seed), page \(keep): \(output.count) vs \(whole.count)")
            let copied = try #require(PDFDocument(data: output), "seed \(seed), page \(keep)")
            #expect(copied.pageCount == count, "seed \(seed), page \(keep)")
            for index in 0..<count {
                let original = try #require(source.page(at: index)), copy = try #require(copied.page(at: index))
                let label = "seed \(seed), keeping \(keep), page \(index + 1)"
                #expect(copy.rotation == original.rotation, "\(label)")
                #expect(copy.bounds(for: .mediaBox) == original.bounds(for: .mediaBox), "\(label)")
                #expect(copy.bounds(for: .cropBox) == original.bounds(for: .cropBox), "\(label)")
                #expect(copy.annotations.map(\.contents) == original.annotations.map(\.contents), "\(label)")
                if index + 1 == keep {
                    #expect(copy.string == original.string, "\(label)")
                    #expect(largestDifference(try contentPixels(copy), try contentPixels(original)) == 0, "\(label)")
                } else {
                    #expect((copy.string ?? "").isEmpty, "\(label)")
                }
            }
        }
    }

    // MARK: - Images: listing and preview use placeholders, writing doesn't

    @Test("On pages sharing one image, listing and preview agree with update and remove on every page; the other pages keep the image",
          arguments: 0..<4)
    func sharedImages(index: Int) throws {
        let source = try book()
        let images = try PDFNativeImageEditor.images(in: source, pageIndex: index)
        let image = try #require(images.first)
        #expect(images.count == 1)
        let preview = try PDFNativeImageEditor.preview(in: source, image: image, maximumDimension: 100)
        #expect(preview.width == 100)
        let green = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        green.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1)); green.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let updated = try PDFNativeImageEditor.update(in: source, image: image, replacement: green.makeImage()!)
        let removed = try PDFNativeImageEditor.remove(in: source, image: image)
        #expect(try PDFNativeImageEditor.images(in: removed, pageIndex: index).isEmpty)
        #expect(try PDFNativeImageEditor.images(in: updated, pageIndex: index).first != image)
        // Every other page that drew the image still draws it, untouched.
        for other in 0..<4 where other != index {
            let original = try PDFNativeImageEditor.images(in: source, pageIndex: other)
            #expect(try PDFNativeImageEditor.images(in: updated, pageIndex: other) == original, "page \(other + 1)")
            #expect(try PDFNativeImageEditor.images(in: removed, pageIndex: other) == original, "page \(other + 1)")
            #expect(largestDifference(try contentPixels(updated.page(at: other)), try contentPixels(source.page(at: other))) == 0)
        }
        // A changed image is caught: the old listing no longer applies to the result.
        #expect(throws: PDFNativeImageError.staleSelection) { try PDFNativeImageEditor.remove(in: updated, image: image) }
    }

    @Test("An image's listing doesn't depend on what other pages draw")
    func listingIgnoresOtherPages() throws {
        let source = try book()
        let listed = try (0..<4).map { try PDFNativeImageEditor.images(in: source, pageIndex: $0) }
        // Text edits on the last page change only that page's content.
        let changed = try edit(source, word: "LAST", page: 4, scope: .wholeDocument)
        for index in 0..<4 {
            let relisted = try PDFNativeImageEditor.images(in: changed, pageIndex: index)
            #expect(relisted == listed[index], "page \(index + 1)")
            // And the earlier listing can still be applied to the changed document.
            _ = try PDFNativeImageEditor.remove(in: changed, image: try #require(listed[index].first))
        }
    }

    @Test("An image whose resources lead to a page object can still be edited after it is listed")
    func imageReachingAPage() throws {
        // Not a standard key, but nothing stops a file from linking an image to a page.
        let content = "q 100 0 0 80 40 200 cm /Im Do Q"
        let source = try #require(PDFDocument(data: Self.rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 /MediaBox [0 0 400 400] >>",
            "<< /Type /Page /Parent 2 0 R /Resources << /XObject << /Im 5 0 R >> >> /Contents 4 0 R >>",
            "<<",
            "<< /Type /XObject /Subtype /Image /Width 16 /Height 12 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Owner 3 0 R",
            "<< /Type /Page /Parent 2 0 R /Resources << /XObject << /Im 5 0 R >> >> /Contents 4 0 R >>"
        ], streams: [4: Data(content.utf8), 5: Data(repeating: 200, count: 16 * 12 * 3)])))
        let image = try #require(try PDFNativeImageEditor.images(in: source, pageIndex: 0).first)
        // Pages are identified, not hashed, in the fingerprint, so listing (other pages as
        // placeholders) and editing (every page whole) agree.
        let result = try PDFNativeImageEditor.remove(in: source, image: image)
        #expect(try PDFNativeImageEditor.images(in: result, pageIndex: 0).isEmpty)
    }

    @Test("A dictionary that only claims to be a page is still fingerprinted: changing it makes the selection stale")
    func pageTypedDictionaryIsHashed() throws {
        let content = "q 100 0 0 80 40 200 cm /Im Do Q"
        func book(_ value: Int) throws -> PDFDocument {
            try #require(PDFDocument(data: Self.rawPDF([
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 400 400] >>",
                "<< /Type /Page /Parent 2 0 R /Resources << /XObject << /Im 5 0 R >> >> /Contents 4 0 R >>",
                "<<",
                "<< /Type /XObject /Subtype /Image /Width 16 /Height 12 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Extra 6 0 R",
                "<< /Type /Page /Detail \(value) >>"
            ], streams: [4: Data(content.utf8), 5: Data(repeating: 200, count: 16 * 12 * 3)])))
        }
        let listed = try #require(try PDFNativeImageEditor.images(in: try book(1), pageIndex: 0).first)
        #expect(throws: PDFNativeImageError.staleSelection) { _ = try PDFNativeImageEditor.remove(in: try book(2), image: listed) }
        _ = try PDFNativeImageEditor.remove(in: try book(1), image: listed)
    }

    // MARK: - Non-functional: cost follows the edited page

    /// `pages` pages, each with its own text and its own image of `imageBytes` seeded noise.
    private func heavyBook(pages: Int, imageBytes: Int = 64 * 64 * 3 * 4) -> Data {
        var random = TreeRandom(seed: 7)
        let side = Int(Double(imageBytes / 3).squareRoot())
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"]
        var streams: [Int: Data] = [:], kids: [String] = []
        for page in 0..<pages {
            let image = objects.count + 1, content = image + 1, pageID = image + 2
            var noise = [UInt8](repeating: 0, count: side * side * 3)
            for offset in noise.indices { noise[offset] = UInt8(truncatingIfNeeded: random.next()) }
            objects.append("<< /Type /XObject /Subtype /Image /Width \(side) /Height \(side) /ColorSpace /DeviceRGB /BitsPerComponent 8"); streams[image] = Data(noise)
            objects.append("<<"); streams[content] = Data("BT /F 14 Tf 40 450 Td (Chapter \(page + 1) TARGET here) Tj ET q 300 0 0 300 40 100 cm /Im Do Q".utf8)
            objects.append("<< /Type /Page /Parent 2 0 R /Resources << /Font << /F 3 0 R >> /XObject << /Im \(image) 0 R >> >> /Contents \(content) 0 R >>")
            kids.append("\(pageID) 0 R")
        }
        objects[1] = "<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count \(pages) /MediaBox [0 0 400 500] >>"
        return Self.rawPDF(objects, streams: streams)
    }

    @Test("A page-only edit's output grows by a small, fixed amount per other page, however much those pages draw; a whole edit grows by their images")
    func costScalesWithEditedPage() throws {
        func outputs(pages: Int) throws -> (pageOnly: Data, whole: Data) {
            let source = try #require(PDFDocument(data: heavyBook(pages: pages)))
            return (try #require(edit(source, word: "TARGET", page: 0, scope: .editedPage).dataRepresentation()),
                    try #require(edit(source, word: "TARGET", page: 0, scope: .wholeDocument).dataRepresentation()))
        }
        let small = try outputs(pages: 2), large = try outputs(pages: 26)
        let imageBytes = 64 * 64 * 3 * 4
        let pageOnlyGrowth = (large.pageOnly.count - small.pageOnly.count) / 24
        let wholeGrowth = (large.whole.count - small.whole.count) / 24
        print("Edit output per extra page: page-only \(pageOnlyGrowth) bytes, whole \(wholeGrowth) bytes")
        #expect(pageOnlyGrowth < 1_024, "page-only grows \(pageOnlyGrowth) bytes per page")
        #expect(wholeGrowth > imageBytes / 2, "whole grows \(wholeGrowth) bytes per page")
        // The graph itself: a placeholder brings one object, its dictionary, and no stream.
        func graphOutput(pages: Int, keeping: Int?) throws -> Data {
            let data = heavyBook(pages: pages)
            let cg = try cgDocument(data)
            return try PDFNativeObjectGraph(document: cg, keepingContentOf: keeping).write()
        }
        func count(_ marker: String, in data: Data) -> Int { data.ranges(of: Data(marker.utf8)).count }
        let wholeGraph = try graphOutput(pages: 26, keeping: nil), pageOnlyGraph = try graphOutput(pages: 26, keeping: 1)
        #expect(count("\nstream\n", in: wholeGraph) == 26 * 2)
        #expect(count("\nstream\n", in: pageOnlyGraph) == 2, "only the kept page's content and image")
        let pageOnlySmall = try graphOutput(pages: 2, keeping: 1), wholeSmall = try graphOutput(pages: 2, keeping: nil)
        #expect((count(" 0 obj\n", in: pageOnlyGraph) - count(" 0 obj\n", in: pageOnlySmall)) == 24, "one object per placeholder")
        #expect((count(" 0 obj\n", in: wholeGraph) - count(" 0 obj\n", in: wholeSmall)) >= 24 * 4)
    }

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

    /// `pages` pages like a scanned book: each its own 1,000-pixel square Flate image that
    /// decodes to 3 MB (one gradient, compressed once, a separate object on every page).
    private func scannedBook(pages: Int) throws -> PDFDocument {
        let side = 1_000
        var pixels = Data(count: side * side * 3)
        pixels.withUnsafeMutableBytes { buffer in
            for y in 0..<side { for x in 0..<side {
                let offset = (y * side + x) * 3
                buffer[offset] = UInt8(truncatingIfNeeded: x); buffer[offset + 1] = UInt8(truncatingIfNeeded: y); buffer[offset + 2] = UInt8(truncatingIfNeeded: x ^ y)
            } }
        }
        let compressed = try Self.flate(pixels)
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", ""], streams: [Int: Data] = [:], kids: [String] = []
        for _ in 0..<pages {
            let image = objects.count + 1, content = image + 1, page = image + 2
            objects.append("<< /Type /XObject /Subtype /Image /Width \(side) /Height \(side) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode")
            streams[image] = compressed
            objects.append("<<"); streams[content] = Data("q 300 0 0 300 40 100 cm /Im Do Q".utf8)
            objects.append("<< /Type /Page /Parent 2 0 R /Resources << /XObject << /Im \(image) 0 R >> >> /Contents \(content) 0 R >>")
            kids.append("\(page) 0 R")
        }
        objects[1] = "<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count \(pages) /MediaBox [0 0 400 500] >>"
        return try #require(PDFDocument(data: Self.rawPDF(objects, streams: streams)))
    }

    @Test("Listing and previewing an image on a long scanned book costs about what it does on a short one; writing, which needs every page, costs more")
    func imageListingCostFollowsThePage() throws {
        let clock = ContinuousClock()
        func median(_ work: () throws -> Void) rethrows -> Duration {
            var times: [Duration] = []
            for _ in 0..<5 { let start = clock.now; try work(); times.append(clock.now - start) }
            return times.sorted()[2]
        }
        let short = try scannedBook(pages: 2), long = try scannedBook(pages: 24)
        let shortListing = try median { _ = try PDFNativeImageEditor.images(in: short, pageIndex: 0) }
        let longListing = try median { _ = try PDFNativeImageEditor.images(in: long, pageIndex: 0) }
        let image = try #require(try PDFNativeImageEditor.images(in: long, pageIndex: 0).first)
        let longPreview = try median { _ = try PDFNativeImageEditor.preview(in: long, image: image, maximumDimension: 64) }
        let longRemove = try median { _ = try PDFNativeImageEditor.remove(in: long, image: image) }
        print("Image listing: 2 pages \(shortListing), 24 pages \(longListing); preview \(longPreview); remove (whole book) \(longRemove)")
        // Generous margins: a listing that imported every page's image would decode 72 MB.
        #expect(longListing < shortListing * 4 + .milliseconds(40), "24 pages \(longListing) vs 2 pages \(shortListing)")
        #expect(longListing * 3 < longRemove, "listing \(longListing) vs writing \(longRemove)")
        #expect(longPreview * 3 < longRemove + .milliseconds(30), "preview \(longPreview) vs writing \(longRemove)")
    }
}
