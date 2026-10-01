import AppKit
import CoreGraphics
import PDFKit
import Testing
@testable import AnnotateCore

/// A one-page PDF written object by object, so a test can place exactly the structure a
/// crafted file would. Object 1 is the catalog and 2 the page tree; the page is object 3.
/// Shared with NativeHardeningDepthTests.
enum HandPDF {
    static func data(_ objects: [String]) -> Data {
        var data = Data("%PDF-1.7\n".utf8), offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }

    static func stream(_ content: String, _ entries: String = "") -> String {
        "<< \(entries) /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
    }

    static let helvetica = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"

    /// The page's own dictionary and resources, as Core Graphics reads them.
    static func page(_ data: Data) throws -> (CGPDFDocument, CGPDFDictionaryRef) {
        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        return (document, try #require(document.page(at: 1)?.dictionary))
    }
}

@Suite("Hardening against crafted PDFs", .serialized)
@MainActor
struct NativeHardeningTests {
    /// Replaces `phrase` with `replacement` where it stands, as the editor does.
    private func edit(_ document: PDFDocument, _ phrase: String, to replacement: String) throws -> PDFDocument {
        let page = try #require(document.page(at: 0))
        let found = try #require(document.findString(phrase, withOptions: []).first).bounds(for: page)
        let region = found.insetBy(dx: -1, dy: -1)
        let original = try #require(page.selection(for: region)?.string)
        let font = try #require(NSFont(name: "Helvetica", size: 12))
        return try PDFNativeTextEditor.replace(in: document, region: PageRegion(pageIndex: 0, bounds: region), originalText: original,
            replacement: NSAttributedString(string: replacement, attributes: [.font: font, .ligature: 0]),
            destination: PageRegion(pageIndex: 0, bounds: CGRect(x: region.minX, y: region.minY - 4, width: 300, height: region.height + 8)), reflow: nil).document
    }

    private func elapsed(_ work: () throws -> Void) rethrows -> Duration {
        let clock = ContinuousClock(), start = clock.now
        try work()
        return clock.now - start
    }

    // MARK: Numbers

    @Test("Only PDF numbers are numbers: no hex, exponents, infinities, or doubled points",
          arguments: [("12", true), ("-3.5", true), (".5", true), ("+4.", true), ("-.25", true),
                      ("0x10", false), ("1e3", false), ("inf", false), ("nan", false), ("1.2.3", false), ("--1", false), ("4-", false), ("+", false), (".", false)])
    func numberGrammar(word: String, isNumber: Bool) {
        #expect((PDFNativeLexer.number(ArraySlice(Array(word.utf8))) != nil) == isNumber, "\(word)")
    }

    @Test("A stream's tokens and an operator's operands are bounded before anything else reads them")
    func lexerBounded() {
        var operands = PDFNativeLexer(Data((String(repeating: "1 ", count: PDFNativeLexer.maximumOperands + 1) + "n").utf8))
        #expect(throws: PDFNativeTextError.self) { _ = try operands.operations() }
        var array = PDFNativeLexer(Data(("[" + String(repeating: "1 ", count: PDFNativeLexer.maximumTokens) + "] TJ").utf8))
        #expect(throws: PDFNativeTextError.self) { _ = try array.operations() }
        var ordinary = PDFNativeLexer(Data("BT /F1 12 Tf 72 700 Td [(A) -20 (B)] TJ ET".utf8))
        #expect((try? ordinary.operations())?.count == 5)
    }

    @Test("A form drawn many times shares one token allowance: the page's, not one per drawing")
    func tokensSharedAcrossForms() throws {
        // Each drawing of the form reads a million-token array; twelve drawings exceed the page's allowance.
        let array = "[" + String(repeating: "1 ", count: 1_000_000) + "] pop"
        let drawings = String(repeating: "/Fm Do ", count: 12)
        let data = HandPDF.data(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /Fm 4 0 R >> >> /Contents 5 0 R >>",
            HandPDF.stream(array, "/Type /XObject /Subtype /Form /BBox [0 0 1 1]"), HandPDF.stream(drawings)])
        let (owner, page) = try HandPDF.page(data)
        try withExtendedLifetime(owner) {
            #expect(throws: PDFNativeTextError.self) {
                try PDFNativeTextProgram(data: Data(drawings.utf8), resources: PDFNativeTextEditor.inheritedResources(page))
            }
        }
    }

    @Test("A name that isn't plain printable ASCII stops editing rather than being matched loosely",
          arguments: ["/Im#E9 Do", "/Im#C3#A9 Do", "/Im#00x Do", "/Im#20x Do", "/Im\u{E9} Do"])
    func nonASCIINamesRefused(content: String) {
        var lexer = PDFNativeLexer(Data(content.utf8))
        #expect(throws: PDFNativeTextError.self) { _ = try lexer.operations() }
    }

    // MARK: Work limits

    @Test("Forms that draw each other many times over are refused quickly, not worked through")
    func formFanOutRefused() throws {
        // Five levels, each drawing the next ten times: a hundred thousand form instances,
        // far past the editor's limit. (PDFKit's own text search on such a page is slow;
        // that is outside Annotate's engine and is not timed here.)
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                       "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> /XObject << /Fm 6 0 R >> >> /Contents 5 0 R >>",
                       HandPDF.helvetica, HandPDF.stream("BT /F1 12 Tf 72 700 Td (Hello there) Tj ET q /Fm Do Q")]
        for level in 0..<5 {
            let next = 7 + level
            let body = level == 4 ? "0 0 1 1 re f" : Array(repeating: "/Fm Do", count: 10).joined(separator: " ")
            let resources = level == 4 ? "" : "/Resources << /XObject << /Fm \(next) 0 R >> >>"
            objects.append(HandPDF.stream(body, "/Type /XObject /Subtype /Form /BBox [0 0 1 1] \(resources)"))
        }
        let document = try #require(PDFDocument(data: HandPDF.data(objects)))
        let page = try #require(document.page(at: 0))
        var region = CGRect.null, original = ""
        let lookup = try elapsed {
            region = try #require(document.findString("Hello there", withOptions: []).first).bounds(for: page).insetBy(dx: -1, dy: -1)
            original = try #require(page.selection(for: region)?.string)
        }
        _ = lookup
        let font = try #require(NSFont(name: "Helvetica", size: 12))
        let time = elapsed {
            #expect(throws: PDFNativeTextError.self) {
                try PDFNativeTextEditor.replace(in: document, region: PageRegion(pageIndex: 0, bounds: region), originalText: original,
                    replacement: NSAttributedString(string: "Hello again", attributes: [.font: font]),
                    destination: PageRegion(pageIndex: 0, bounds: CGRect(x: region.minX, y: region.minY - 4, width: 300, height: region.height + 8)), reflow: nil)
            }
        }
        #expect(time < .seconds(2), "\(time)")
    }

    @Test("A font selected over and over is read once")
    func fontReadOnce() throws {
        // A sizeable ToUnicode map, then twenty thousand selections of the font.
        let entries = (0..<12).flatMap { _ in (32..<127).map { String(format: "<%02X> <%04X>", $0, $0) } }
        let cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap 1 begincodespacerange <00> <FF> endcodespacerange\n"
            + stride(from: 0, to: entries.count, by: 100).map { start in
                let chunk = entries[start..<min(start + 100, entries.count)]
                return "\(chunk.count) beginbfchar\n" + chunk.joined(separator: "\n") + "\nendbfchar"
            }.joined(separator: "\n") + "\nendcmap CMapName currentdict /CMap defineresource pop end end"
        let content = "BT " + String(repeating: "/F1 12 Tf ", count: 20_000) + "72 700 Td (Hello) Tj ET"
        let data = HandPDF.data(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 6 0 R >>",
            HandPDF.stream(content), HandPDF.stream(cmap)])
        let (owner, page) = try HandPDF.page(data)
        let time = try withExtendedLifetime(owner) {
            try elapsed { _ = try PDFNativeTextProgram(data: Data(content.utf8), resources: PDFNativeTextEditor.inheritedResources(page)) }
        }
        #expect(time < .seconds(2), "\(time)")
    }

    @Test("A composite font's overlapping width ranges are bounded in total")
    func widthTableBounded() throws {
        let ranges = Array(repeating: "0 65535 500", count: 6).joined(separator: " ")
        let data = HandPDF.data(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F2 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type0 /BaseFont /Crafted /Encoding /Identity-H /DescendantFonts [6 0 R] >>",
            HandPDF.stream("BT /F2 12 Tf 72 700 Td <0001> Tj ET"),
            "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Crafted /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /W [\(ranges)] >>"])
        let (owner, page) = try HandPDF.page(data)
        try withExtendedLifetime(owner) {
            let resources = try #require(PDFNativeTextEditor.inheritedResources(page))
            let fonts = try #require(nativeDictionary(resources, "Font"))
            let font = try #require(nativeDictionary(fonts, "F2"))
            #expect(throws: PDFNativeTextError.self) { try PDFNativeFont(font) }
        }
    }

    @Test("A stream compressed twice is never decoded; once is fine",
          arguments: [("/Filter [/FlateDecode /FlateDecode]", false), ("/Filter [/LZWDecode /FlateDecode]", false),
                      ("/Filter /FlateDecode", true), ("/Filter [/ASCIIHexDecode /FlateDecode]", true), ("", true),
                      // Fax and JBIG2 images must state a size within the decoding limit first.
                      ("/Filter /CCITTFaxDecode /Width 100000 /Height 100000", false), ("/Filter /JBIG2Decode /Width 100000 /Height 100000", false),
                      ("/Filter /CCITTFaxDecode", false), ("/Filter /CCF /Width 2550 /Height 3300 /DecodeParms << /K -1 /Columns 2550 /Rows 3300 >>", true),
                      // The fax decoder sizes its output from its own parameters: they must match the image.
                      ("/Filter /CCITTFaxDecode /Width 1 /Height 1 /DecodeParms << /K -1 /Columns 1000000 >>", false),
                      ("/Filter /CCITTFaxDecode /Width 2550 /Height 3300 /DecodeParms << /K -1 /Columns 2550 >>", false),
                      ("/Filter [/ASCIIHexDecode /CCITTFaxDecode] /Width 1728 /Height 2200 /DecodeParms [null << /K -1 /Rows 2200 >>]", true),
                      // Values the decoder reads differently, and parameters shaped unlike the filters.
                      ("/Filter /CCF /Width 2550 /Height 3300 /DecodeParms << /K -1 /Columns 2550 /Rows 3300.0 >>", false),
                      ("/Filter /CCF /Width 2550.5 /Height 3300 /DecodeParms << /K -1 /Columns 2550 /Rows 3300 >>", false),
                      ("/Filter [/AHx /CCF] /Width 2550 /Height 3300 /DecodeParms << /K -1 /Columns 2550 /Rows 3300 >>", false),
                      ("/Filter /CCF /Width 2550 /Height 3300 /DecodeParms [<< /K -1 /Columns 2550 /Rows 3300 >>]", false),
                      ("/Filter [/AHx /CCF] /Width 2550 /Height 3300 /DecodeParms [<< /K -1 /Columns 2550 /Rows 3300 >>]", false),
                      ("/Filter /CCF /Width 2550 /Height 3300 /DecodeParms << /K -1 /Columns 0 /Rows 3300 >>", false),
                      ("/Filter [/FlateDecode /CCITTFaxDecode] /Width 2550 /Height 3300", false)])
    func chainedCompression(filter: String, bounded: Bool) throws {
        let data = HandPDF.data(["<< /Type /Catalog /Pages 2 0 R /Crafted 6 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R >>", HandPDF.helvetica, HandPDF.stream(""),
            HandPDF.stream("x", filter)])
        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        let catalog = try #require(document.catalog)
        let stream = try #require(nativeStream(catalog, "Crafted"))
        #expect(nativeStreamExpansionIsBounded(stream) == bounded)
    }

    @Test("Editing a page whose file carries a doubly compressed stream is refused before decoding it")
    func chainedCompressionEditRefused() throws {
        let document = try #require(PDFDocument(data: HandPDF.data(["<< /Type /Catalog /Pages 2 0 R /Crafted 6 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            HandPDF.helvetica, HandPDF.stream("BT /F1 12 Tf 72 700 Td (Hello there) Tj ET"),
            HandPDF.stream("x", "/Filter [/FlateDecode /FlateDecode]")])))
        #expect(throws: (any Error).self) { try edit(document, "Hello there", to: "Hello again") }
    }

    // MARK: Character codes

    @Test("A simple font's strings split into one-byte codes, whatever its ToUnicode map claims")
    func simpleFontCodesAreOneByte() throws {
        // The map claims two-byte codes; a renderer reads "AB" as two one-byte codes.
        let cmap = "begincmap 1 begincodespacerange <0000> <FFFF> endcodespacerange 1 beginbfchar <4142> <0058> endbfchar endcmap"
        let content = "BT /F1 12 Tf 72 700 Td (AB) Tj ET"
        let data = HandPDF.data(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 6 0 R >>",
            HandPDF.stream(content), HandPDF.stream(cmap)])
        let (owner, page) = try HandPDF.page(data)
        try withExtendedLifetime(owner) {
            // Reading "AB" as the single code <4142> would edit the wrong glyphs; refusing is right.
            #expect(throws: PDFNativeTextError.self) {
                try PDFNativeTextProgram(data: Data(content.utf8), resources: PDFNativeTextEditor.inheritedResources(page))
            }
        }
    }

    // MARK: Leftovers of edited content

    private func savedPage(_ document: PDFDocument) throws -> (CGPDFDocument, CGPDFDictionaryRef) {
        try HandPDF.page(try #require(document.dataRepresentation()))
    }

    @Test("An edited page drops its stored thumbnail, which would still show the old text")
    func thumbnailDropped() throws {
        let document = try #require(PDFDocument(data: HandPDF.data(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R /Thumb 6 0 R >>",
            HandPDF.helvetica, HandPDF.stream("BT /F1 12 Tf 72 700 Td (Hello there) Tj ET"),
            HandPDF.stream("00", "/Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode")])))
        let edited = try edit(document, "Hello there", to: "Hello again")
        let (owner, page) = try savedPage(edited)
        withExtendedLifetime(owner) {
            var thumb: CGPDFObjectRef?
            #expect(!CGPDFDictionaryGetObject(page, "Thumb", &thumb))
        }
    }

    @Test("Editing text inside a form removes every name for the old form that nothing draws")
    func aliasesPruned() throws {
        let document = try #require(PDFDocument(data: HandPDF.data(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> /XObject << /Fm 6 0 R /Alias 6 0 R >> >> /Contents 5 0 R >>",
            HandPDF.helvetica, HandPDF.stream("BT /F1 12 Tf 72 700 Td (Visible line) Tj ET q /Fm Do Q"),
            HandPDF.stream("BT /F1 12 Tf 72 600 Td (Secret words) Tj ET", "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >>")])))
        let edited = try edit(document, "Secret words", to: "Public words")
        let (owner, page) = try savedPage(edited)
        try withExtendedLifetime(owner) {
            let resources = try #require(nativeDictionary(page, "Resources"))
            let objects = try #require(nativeDictionary(resources, "XObject"))
            #expect(nativeStream(objects, "Alias") == nil, "the alias would keep the old words in the file")
            #expect(nativeStream(objects, "Fm") == nil)
        }
        #expect(edited.findString("Public words", withOptions: []).count == 1)
        #expect(edited.findString("Visible line", withOptions: []).count == 1)
    }

    @Test("Moving an image keeps it drawn: its new name is never pruned as an alias")
    func movedImageKept() throws {
        let document = try #require(PDFDocument(data: HandPDF.data(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /Im 4 0 R >> >> /Contents 5 0 R >>",
            HandPDF.stream("00FF00FF", "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode"),
            HandPDF.stream("q 100 0 0 100 100 500 cm /Im Do Q")])))
        let image = try #require(PDFNativeImageEditor.images(in: document, pageIndex: 0).first)
        let moved = try PDFNativeImageEditor.update(in: document, image: image, bounds: CGRect(x: 200, y: 300, width: 100, height: 100))
        let bytes = try #require(moved.dataRepresentation())
        let reopened = try #require(PDFDocument(data: bytes))
        #expect(try PDFNativeImageEditor.images(in: reopened, pageIndex: 0).count == 1)
    }

    // MARK: Markers

    @Test("Reading markers is bounded: a large payload repeated on many annotations is decoded only so often")
    func markerReadingBounded() throws {
        let document = PDFDocument()
        let page = PDFPage()
        document.insert(page, at: 0)
        // Valid-looking JSON the decoder has to read to the end before rejecting.
        let payload = "{\"version\":1,\"marker\":{\"pad\":\"" + String(repeating: "x", count: 1_000_000) + "\"}}"
        for _ in 0..<1_000 {
            let annotation = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 10, height: 10), forType: .square, withProperties: nil)
            annotation.setValue(MarkerCodec.ownerValue, forAnnotationKey: MarkerCodec.ownerKey)
            annotation.setValue(UUID().uuidString, forAnnotationKey: MarkerCodec.identifierKey)
            annotation.setValue(payload, forAnnotationKey: MarkerCodec.metadataKey)
            page.addAnnotation(annotation)
        }
        var found: [PDFMarker] = []
        let time = elapsed { found = MarkerCodec.markers(in: document) }
        #expect(found.isEmpty)
        #expect(time < .seconds(3), "\(time)")
    }

    @Test("Erasing an area a marker touches clears the marker's quote, which would keep the erased words")
    func erasedQuoteCleared() throws {
        let document = try Fixtures.document()
        let selection = try #require(document.findString("specific question", withOptions: .caseInsensitive).first)
        let page = try #require(selection.pages.first)
        let erased = PageRegion(pageIndex: document.index(for: page), bounds: selection.bounds(for: page))
        let elsewhere = PageRegion(pageIndex: erased.pageIndex == 0 ? 1 : 0, bounds: CGRect(x: 72, y: 72, width: 100, height: 14))
        let marker = PDFMarker(categories: [.important], color: MarkerColor(red: 0.95, green: 0.68, blue: 0.16), icon: "star.fill",
                               quote: "a specific question", note: "My own note", question: "", regions: [erased, elsewhere])
        try MarkerCodec.apply(marker, to: document)
        _ = try PDFContentEditor.replaceArea(erased, in: document)
        let kept = try #require(MarkerCodec.markers(in: document).first { $0.id == marker.id })
        #expect(kept.quote.isEmpty)
        #expect(kept.note == "My own note")
        #expect(kept.regions == [elsewhere])
        let comments = document.page(at: elsewhere.pageIndex)?.annotations.compactMap(\.contents).joined() ?? ""
        #expect(!comments.localizedCaseInsensitiveContains("specific question"))
    }
}
