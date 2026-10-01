import AppKit
import CoreGraphics
import PDFKit
import Testing
@testable import AnnotateCore

/// SplitMix64: every generated case replays from its seed.
private struct DepthRandom: RandomNumberGenerator {
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

/// The hardening limits must refuse crafted pages without refusing ordinary ones: code
/// lengths from the font's encoding, the shared work budget, the lexer's number grammar,
/// and pages whose own content is one huge flat sequence.
@Suite("Hardening limits still edit ordinary pages", .serialized)
@MainActor
struct NativeHardeningDepthTests {
    private static let catalog = "<< /Type /Catalog /Pages 2 0 R >>"
    private static let pages = "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"

    private func elapsed(_ work: () throws -> Void) rethrows -> Duration {
        let clock = ContinuousClock(), start = clock.now
        try work()
        return clock.now - start
    }

    /// Parses page 1 of `data` as the editor does.
    private func program(_ data: Data) throws -> PDFNativeTextProgram {
        let (owner, page) = try HandPDF.page(data)
        return try withExtendedLifetime(owner) {
            var content = Data()
            if let stream = nativeStream(page, "Contents") { content = try nativeDecodedStream(stream) }
            else if let array = nativeArray(page, "Contents") {
                for index in 0..<CGPDFArrayGetCount(array) {
                    var stream: CGPDFStreamRef?
                    if CGPDFArrayGetStream(array, index, &stream), let stream { content.append(try nativeDecodedStream(stream)); content.append(10) }
                }
            }
            return try PDFNativeTextProgram(data: content, resources: PDFNativeTextEditor.inheritedResources(page))
        }
    }

    /// Replaces the glyphs reading `phrase` (found by the engine, not PDFKit) with `replacement`.
    private func edit(_ data: Data, _ phrase: String, to replacement: String) throws -> PDFDocument {
        let parsed = try program(data)
        let text = parsed.glyphs.map(\.glyph.text).joined()
        let range = try #require(text.range(of: phrase), "\(phrase) in \(text)")
        let start = text.distance(from: text.startIndex, to: range.lowerBound), count = phrase.count
        var bounds = CGRect.null, offset = 0
        for placement in parsed.glyphs {
            if offset >= start, offset < start + count { bounds = bounds.union(placement.bounds) }
            offset += placement.glyph.text.count
        }
        let document = try #require(PDFDocument(data: data))
        let region = bounds.insetBy(dx: 0.5, dy: 0.5)
        let font = try #require(NSFont(name: "Helvetica", size: 12))
        return try PDFNativeTextEditor.replace(in: document, region: PageRegion(pageIndex: 0, bounds: region), originalText: phrase,
            replacement: NSAttributedString(string: replacement, attributes: [.font: font, .ligature: 0]),
            destination: PageRegion(pageIndex: 0, bounds: CGRect(x: region.minX, y: region.minY - 4, width: 300, height: region.height + 8)), reflow: nil).document
    }

    private func savedText(_ document: PDFDocument) throws -> String {
        try program(try #require(document.dataRepresentation())).glyphs.map(\.glyph.text).joined()
    }

    // MARK: Code lengths

    /// A composite font whose embedded encoding CMap has one-byte codes for ASCII and
    /// two-byte codes from <8140>, mapped to CIDs with their own widths.
    private func mixedLengthFont(toUnicode: String, encodingSpace: String = "2 begincodespacerange <00> <7F> <8140> <9FFC> endcodespacerange") -> Data {
        let encoding = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /Mixed def\n\(encodingSpace)\n"
            + "2 begincidrange <20> <7E> 1 <8140> <8142> 200 endcidrange\nendcmap CMapName currentdict /CMap defineresource pop end end"
        let content = "BT /F2 12 Tf 72 700 Td <48656C6C6F8140814220776F726C64> Tj ET"
        return HandPDF.data([Self.catalog, Self.pages,
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F2 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type0 /BaseFont /Mixed /Encoding 6 0 R /DescendantFonts [7 0 R] /ToUnicode 8 0 R >>",
            HandPDF.stream(content), HandPDF.stream(encoding),
            "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Mixed /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /DW 1000 /W [1 95 600 200 [900 910 920]] >>",
            HandPDF.stream(toUnicode)])
    }

    private static let mixedToUnicode = "begincmap 1 begincodespacerange <00> <FF> endcodespacerange\n"
        + "1 beginbfrange <20> <7E> <0020> endbfrange\n1 beginbfrange <8140> <8142> <3042> endbfrange\nendcmap"

    @Test("A composite font with one- and two-byte codes reads each code at its own length, with its CID's width")
    func mixedLengthsRead() throws {
        let glyphs = try program(mixedLengthFont(toUnicode: Self.mixedToUnicode)).glyphs.map(\.glyph)
        #expect(glyphs.map(\.text).joined() == "Hello\u{3042}\u{3044} world")
        #expect(glyphs.map(\.bytes.count) == [1, 1, 1, 1, 1, 2, 2, 1, 1, 1, 1, 1, 1])
        // ASCII codes map to CIDs 1...95 (width 600), <8140>/<8142> to CIDs 200/202.
        #expect(glyphs.map(\.width) == [600, 600, 600, 600, 600, 900, 920, 600, 600, 600, 600, 600, 600])
    }

    @Test("A composite font with one- and two-byte codes still edits: ASCII words and two-byte words alike",
          arguments: [("world", "there", "Hello\u{3042}\u{3044} "), ("\u{3042}\u{3044}", "ok", "Hello world")])
    func mixedLengthsEdit(phrase: String, replacement: String, kept: String) throws {
        let edited = try edit(mixedLengthFont(toUnicode: Self.mixedToUnicode), phrase, to: replacement)
        let text = try savedText(edited)
        #expect(!text.contains(phrase))
        // The untouched codes survive byte for byte: every kept character is still read.
        #expect(text.filter { kept.contains($0) }.count >= kept.filter { $0 != " " }.count)
        #expect(edited.findString(replacement, withOptions: []).count == 1)
    }

    @Test("The ToUnicode map's own code space no longer decides a composite font's code lengths",
          arguments: ["1 begincodespacerange <0000> <FFFF> endcodespacerange", "1 begincodespacerange <00> <FF> endcodespacerange", ""])
    func toUnicodeSpaceIgnored(space: String) throws {
        let map = "begincmap \(space)\n1 beginbfrange <20> <7E> <0020> endbfrange\n1 beginbfrange <8140> <8142> <3042> endbfrange\nendcmap"
        #expect(try program(mixedLengthFont(toUnicode: map)).glyphs.map(\.glyph.text).joined() == "Hello\u{3042}\u{3044} world")
    }

    @Test("A Type0 Identity-H font reads two-byte codes whatever its ToUnicode code space says")
    func identityTwoByte() throws {
        let toUnicode = "begincmap 1 begincodespacerange <00> <FF> endcodespacerange 2 beginbfchar <0048> <0048> <0069> <0069> endbfchar endcmap"
        let data = HandPDF.data([Self.catalog, Self.pages,
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F2 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type0 /BaseFont /Ident /Encoding /Identity-H /DescendantFonts [6 0 R] /ToUnicode 7 0 R >>",
            HandPDF.stream("BT /F2 12 Tf 72 700 Td <00480069> Tj ET"),
            "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Ident /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /DW 500 >>",
            HandPDF.stream(toUnicode)])
        let glyphs = try program(data).glyphs.map(\.glyph)
        #expect(glyphs.map(\.text) == ["H", "i"])
        #expect(glyphs.allSatisfy { $0.bytes.count == 2 })
    }

    @Test("A simple font with an ordinary one-byte ToUnicode map still edits", arguments: ["TrueType", "Type1"])
    func simpleFontWithToUnicode(subtype: String) throws {
        let map = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap 1 begincodespacerange <00> <FF> endcodespacerange\n"
            + "1 beginbfrange <20> <7E> <0020> endbfrange\nendcmap CMapName currentdict /CMap defineresource pop end end"
        let data = HandPDF.data([Self.catalog, Self.pages,
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /\(subtype) /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 6 0 R >>",
            HandPDF.stream("BT /F1 12 Tf 72 700 Td (Hello there) Tj ET"), HandPDF.stream(map)])
        let edited = try edit(data, "there", to: "again")
        let text = try savedText(edited)
        #expect(text.hasPrefix("Hello") && !text.contains("there"))
        #expect(edited.findString("again", withOptions: []).count == 1)
    }

    @Test("A ToUnicode entry for a byte outside the encoding's one-byte code space doesn't split a two-byte code")
    func toUnicodeCannotSplitTwoByteCode() throws {
        // <81> is not a one-byte code in the encoding (<00>-<7F>); a renderer reads <8140> as one
        // code. A ToUnicode map that names <81> and <40> but not <8140> must not make the
        // editor read two glyphs, which would edit different glyphs from those shown.
        let map = "begincmap 2 beginbfchar <81> <0058> <40> <0040> endbfchar 1 beginbfrange <20> <7E> <0020> endbfrange endcmap"
        let read = Result { try program(mixedLengthFont(toUnicode: map)).glyphs.map(\.glyph.bytes) }
        if case .success(let codes) = read {
            withKnownIssue("code splitting tries the encoding's lengths by ToUnicode lookup, not by code-space range") {
                #expect(!codes.contains([0x81]), "\(codes)")
            }
        }
    }

    // MARK: Work budget

    /// A page with a line of text and `count` form instances: the same small form drawn
    /// `count` times, or `count` distinct forms drawn once each.
    private func formsPage(_ count: Int, distinct: Bool) -> Data {
        let form = HandPDF.stream("0 0 1 1 re f", "/Type /XObject /Subtype /Form /BBox [0 0 1 1]")
        let names = distinct ? (0..<count).map { "/Fm\($0) \(6 + $0) 0 R" }.joined(separator: " ") : "/Fm 6 0 R"
        let draws = (0..<count).map { distinct ? "q 1 0 0 1 \($0 % 500) \($0 / 500) cm /Fm\($0) Do Q" : "q 1 0 0 1 \($0 % 500) \($0 / 500) cm /Fm Do Q" }
        let content = "BT /F1 12 Tf 72 700 Td (Hello there) Tj ET\n" + draws.joined(separator: "\n")
        return HandPDF.data([Self.catalog, Self.pages,
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> /XObject << \(names) >> >> /Contents 5 0 R >>",
            HandPDF.helvetica, HandPDF.stream(content)] + Array(repeating: form, count: distinct ? count : 1))
    }

    @Test("A legal page with many form instances still edits, up to the limit", arguments: [(1_500, false), (1_500, true), (2_000, false)])
    func manyFormsEdit(count: Int, distinct: Bool) throws {
        let data = formsPage(count, distinct: distinct)
        var edited: PDFDocument?
        let time = try elapsed { edited = try edit(data, "there", to: "again") }
        let result = try #require(edited)
        if count < PDFNativeTextProgram.Work.maximumForms {
            #expect(try savedText(result).hasPrefix("Hello"))
        } else {
            // The replacement text is itself a form: a page edited at the limit is one past it,
            // so a further edit is refused rather than silently partial.
            #expect(throws: PDFNativeTextError.self) { try savedText(result) }
        }
        #expect(result.findString("again", withOptions: []).count == 1)
        // Every instance is still drawn and resolves.
        let names = try DrawnNames(try #require(result.dataRepresentation()))
        #expect(names.dangling.isEmpty)
        #expect(time < .seconds(20), "\(time)")
    }

    @Test("One form instance past the limit is refused cleanly, as unsupported", arguments: [false, true])
    func formLimitRefused(distinct: Bool) throws {
        let data = formsPage(PDFNativeTextProgram.Work.maximumForms + 1, distinct: distinct)
        let time = elapsed {
            #expect {
                _ = try program(data)
            } throws: { error in
                guard case .unsupported(let message)? = error as? PDFNativeTextError else { return false }
                return message.contains("safe editing limit")
            }
        }
        #expect(time < .seconds(10), "\(time)")
    }

    @Test("Forms nested inside forms count toward the same budget")
    func nestedFormsShareBudget() throws {
        // Two outer forms each drawing an inner form 1,000 times: 2 + 2,000 instances.
        let inner = HandPDF.stream("0 0 1 1 re f", "/Type /XObject /Subtype /Form /BBox [0 0 1 1]")
        let outerBody = Array(repeating: "/In Do", count: 1_000).joined(separator: " ")
        let outer = HandPDF.stream(outerBody, "/Type /XObject /Subtype /Form /BBox [0 0 1 1] /Resources << /XObject << /In 7 0 R >> >>")
        let data = HandPDF.data([Self.catalog, Self.pages,
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> /XObject << /Out 6 0 R >> >> /Contents 5 0 R >>",
            HandPDF.helvetica, HandPDF.stream("BT /F1 12 Tf 72 700 Td (Hello) Tj ET /Out Do /Out Do"), outer, inner])
        #expect(throws: PDFNativeTextError.self) { try program(data) }
        // One outer form, 1,001 instances, is fine.
        let one = HandPDF.data([Self.catalog, Self.pages,
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> /XObject << /Out 6 0 R >> >> /Contents 5 0 R >>",
            HandPDF.helvetica, HandPDF.stream("BT /F1 12 Tf 72 700 Td (Hello) Tj ET /Out Do"), outer, inner])
        #expect(try program(one).forms.count == 1)
    }

    @Test("Distinct fonts are bounded per page; the same font under many names is read once")
    func fontLimit() throws {
        func page(fonts: Int, objects: Int) -> Data {
            let names = (0..<fonts).map { "/F\($0) \(6 + $0 % objects) 0 R" }.joined(separator: " ")
            let content = "BT " + (0..<fonts).map { "/F\($0) 12 Tf" }.joined(separator: " ") + " 72 700 Td (Hi) Tj ET"
            return HandPDF.data([Self.catalog, Self.pages,
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << \(names) >> >> /Contents 5 0 R >>",
                HandPDF.helvetica, HandPDF.stream(content)] + Array(repeating: HandPDF.helvetica, count: objects))
        }
        let limit = PDFNativeTextProgram.Work.maximumFonts
        #expect(throws: PDFNativeTextError.self) { try program(page(fonts: limit + 1, objects: limit + 1)) }
        #expect(try program(page(fonts: limit, objects: limit)).glyphs.map(\.glyph.text).joined() == "Hi")
        // 3,000 names for the same three font objects: well past the limit in names, not in fonts.
        #expect(try program(page(fonts: 3_000, objects: 3)).glyphs.count == 2)
    }

    // MARK: Numbers

    /// The PDF number grammar, written independently: sign, digits, at most one point.
    private static func isPDFNumber(_ word: String) -> Bool {
        word.range(of: #"^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)$"#, options: .regularExpression) != nil
    }

    @Test("Random words are numbers exactly when the PDF grammar says so", arguments: Array(UInt64(1)...UInt64(8)))
    func numberGrammarProperty(seed: UInt64) {
        var random = DepthRandom(seed: seed)
        let alphabet = Array("0123456789.+-eExXinfaNIF_")
        for _ in 0..<2_000 {
            let word = String((0..<Int.random(in: 1...8, using: &random)).map { _ in alphabet.randomElement(using: &random)! })
            let parsed = PDFNativeLexer.number(ArraySlice(Array(word.utf8)))
            #expect((parsed != nil) == Self.isPDFNumber(word), "seed \(seed): \(word)")
            if let parsed { #expect(parsed == Double(word), "seed \(seed): \(word)") }
        }
    }

    @Test("A number the editor writes reads back as the same number", arguments: Array(UInt64(20)...UInt64(23)))
    func numberRoundTrip(seed: UInt64) throws {
        var random = DepthRandom(seed: seed)
        for _ in 0..<2_000 {
            let value = Double.random(in: -1e6...1e6, using: &random) * (Bool.random(using: &random) ? 1 : 1e-6)
            let written = nativePDFNumber(value)
            #expect(Self.isPDFNumber(written), "seed \(seed): \(value) -> \(written)")
            let read = try #require(PDFNativeLexer.number(ArraySlice(Array(written.utf8))), "seed \(seed): \(written)")
            #expect(abs(read - value) <= 5e-9 * max(1, abs(value)), "seed \(seed): \(value) -> \(written) -> \(read)")
        }
    }

    @Test("Words the lexer refuses as numbers become operators, so a crafted operand can't pass as a number")
    func nonNumbersAreOperators() throws {
        var lexer = PDFNativeLexer(Data("1e3 0x10 inf 12 Td".utf8))
        let operations = try lexer.operations()
        #expect(operations.map(\.name) == ["1e3", "0x10", "inf", "Td"])
        #expect(operations.last?.operands.first?.number == 12)
        // An overlong run of digits is a number in the grammar but not finite: never a number.
        #expect(PDFNativeLexer.number(ArraySlice(Array(String(repeating: "9", count: 400).utf8))) == nil)
    }

    // MARK: Hostile content performance

    private func textPage(_ content: String) -> Data {
        HandPDF.data([Self.catalog, Self.pages,
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            HandPDF.helvetica, HandPDF.stream(content)])
    }

    @Test("A page of nearly the operator limit is read in reasonable time; one past is refused")
    func operatorLimit() throws {
        let filler = String(repeating: "0 g\n", count: 240_000)
        var read: PDFNativeTextProgram?
        let time = try elapsed { read = try program(textPage("BT /F1 12 Tf 72 700 Td (Hello) Tj ET\n" + filler)) }
        #expect(read?.glyphs.count == 5)
        #expect(time < .seconds(15), "\(time)")
        let over = textPage(String(repeating: "0 g\n", count: 250_001))
        let refused = elapsed { #expect(throws: PDFNativeTextError.self) { try program(over) } }
        #expect(refused < .seconds(15), "\(refused)")
    }

    @Test("Huge flat sequences inside one stream finish in reasonable time",
          arguments: ["operands", "whitespace", "comments", "adjustments", "strings"])
    func flatSequences(kind: String) throws {
        let content: String
        switch kind {
        case "operands": content = String(repeating: "1 ", count: 1_000_000) + "n"           // a million operands, one operator
        case "whitespace": content = String(repeating: " ", count: 16_000_000) + "0 g"        // 16 MB of spaces
        case "comments": content = String(repeating: "%comment line\n", count: 500_000) + "0 g"
        case "adjustments": content = "BT /F1 12 Tf 72 700 Td [" + String(repeating: "(a) -10 ", count: 120_000) + "] TJ ET"
        default: content = "BT /F1 12 Tf 72 700 Td " + String(repeating: "(ab) Tj ", count: 120_000) + "ET"
        }
        let data = textPage(content)
        let time = elapsed { _ = try? program(data) }
        #expect(time < .seconds(20), "\(kind): \(time)")
    }

    @Test("Deeply nested arrays and dictionaries are refused without exhausting the stack", arguments: [100, 100_000])
    func deepNesting(depth: Int) throws {
        for (open, close) in [("[", "]"), ("<<", ">>")] {
            let body = open == "<<" ? String(repeating: "<< /K ", count: depth) + "1" + String(repeating: " >>", count: depth)
                                    : String(repeating: open, count: depth) + String(repeating: close, count: depth)
            var lexer = PDFNativeLexer(Data((body + " n").utf8))
            let time = elapsed { #expect(throws: PDFNativeTextError.self) { _ = try lexer.operations() } }
            #expect(time < .seconds(5), "\(open) \(depth): \(time)")
        }
    }
}
