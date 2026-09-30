import AppKit
import CoreText
import PDFKit
import Testing
@testable import AnnotateCore

/// SplitMix64, so every fuzz case replays exactly from the seed printed with a failure.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// How the original text was set (`PDFNativeTextLayout`): its invariants under random and
/// hostile lines, `read` from synthetic glyphs and from real content streams, and the
/// substitute font choices that let an edit keep the original's look.
@Suite("Reading the original text layout", .serialized)
@MainActor
struct NativeTextLayoutTests {
    // MARK: - Layout invariants

    private func layout(_ lines: [(Double, Double, Double)], spaceWidth: Double = .nan, firstWordEnds: [Double]? = nil) -> PDFNativeTextLayout {
        var result = PDFNativeTextLayout(lines: lines.enumerated().map { index, line in
            .init(start: line.0, end: line.1, baseline: line.2, firstWordEnd: firstWordEnds?[index] ?? .nan)
        }, characterSpacing: 0)
        result.spaceWidth = spaceWidth
        return result
    }

    @Test("A single line: left-aligned, no pitch, no indent, and its own margins", arguments: [
        (72.0, 300.0, 700.0), (0, 0, 0), (-50, -10, -20), (300, 300.5, 1e6)
    ])
    func singleLine(line: (Double, Double, Double)) {
        let single = layout([line], spaceWidth: 3)
        #expect(single.alignment(fontSize: 12) == .left)
        #expect(single.alignment(fontSize: 1_000) == .left)
        #expect(single.linePitch == nil)
        #expect(single.firstLineIndent == 0)
        #expect(single.left == line.0)
        #expect(single.right == line.1)
        #expect(single.column == line.1)
        #expect(single.justifiedMargin == line.1)
        #expect(single.firstBaseline == line.2)
    }

    @Test("Baselines that rise, repeat or overflow give no line pitch", arguments: [
        [(72.0, 500.0, 600.0), (72, 500, 614)],              // reversed: the second line is above
        [(72.0, 500.0, 600.0), (72, 500, 600)],              // the same baseline twice
        [(72.0, 500.0, 700.0), (72, 500, 686), (72, 300, 690)], // one step up among steps down
        [(72.0, 500.0, .infinity), (72, 500, .infinity)],    // inf - inf is NaN
        [(72.0, 500.0, .nan), (72, 500, 686)],
    ])
    func noPitch(lines: [(Double, Double, Double)]) {
        #expect(layout(lines).linePitch == nil)
    }

    @Test("Two lines never read as justified, however well their edges agree")
    func twoLinesNeverJustified() {
        // Both edges shared and a shorter last line: justified needs a third line to tell
        // a stretched line from one that simply ended at the margin.
        #expect(layout([(72, 500, 700), (72, 300, 686)]).alignment(fontSize: 12) == .left)
        #expect(layout([(72, 500, 700), (72, 500, 686)]).alignment(fontSize: 12) == .left)
        #expect(layout([(72, 500, 700), (72, 500, 686), (72, 300, 672)]).alignment(fontSize: 12) == .justified)
    }

    @Test("An indented first line of justified text is still justified; a hanging one is not an indent")
    func indentReading() {
        let indented = layout([(96, 500, 700), (72, 500, 686), (72, 500, 672), (72, 200, 658)])
        #expect(indented.alignment(fontSize: 12) == .justified)
        #expect(indented.firstLineIndent == 24)
        #expect(indented.left == 72)
        // A first line starting left of the others (hanging) has no indent.
        let hanging = layout([(60, 500, 700), (72, 500, 686), (72, 300, 672)])
        #expect(hanging.firstLineIndent == 0)
        #expect(hanging.left == 72)
    }

    @Test("Justified line ends may jitter by a tenth of the font size; right and centre edges must agree to half a point")
    func alignmentTolerances() {
        // Ends within 1.2 pt at 12 pt (a glyph's overhang): justified, to their median.
        let jittered = layout([(72, 500, 700), (72, 500.8, 686), (72, 500.1, 672), (72, 300, 658)])
        #expect(jittered.alignment(fontSize: 12) == .justified)
        #expect(jittered.justifiedMargin == 500.1)
        // A spread of 1.3 pt at 12 pt is ragged, but 24 pt text allows 2.4 pt.
        let ragged = layout([(72, 500, 700), (72, 501.3, 686), (72, 500, 672), (72, 300, 658)])
        #expect(ragged.alignment(fontSize: 12) == .left)
        #expect(ragged.alignment(fontSize: 24) == .justified)
        // Small text still allows 0.75 pt.
        #expect(layout([(72, 500, 700), (72, 500.7, 686), (72, 300, 672)]).alignment(fontSize: 4) == .justified)
        // A last line reaching (nearly) the margin can't be told from a full line: left.
        #expect(layout([(72, 500, 700), (72, 500, 686), (72, 499.5, 672)]).alignment(fontSize: 12) == .left)
        // Right and centre edges are exact: 0.5 pt, however large the text.
        #expect(layout([(100, 500, 700), (150, 500.5, 686), (300, 500, 672)]).alignment(fontSize: 48) == .right)
        #expect(layout([(100, 500, 700), (150, 500.6, 686), (300, 500, 672)]).alignment(fontSize: 48) == .left)
        #expect(layout([(100, 400, 700), (150, 350.9, 686)]).alignment(fontSize: 48) == .center)
        #expect(layout([(100, 400, 700), (150, 351.2, 686)]).alignment(fontSize: 48) == .left)
        // Same starts and ends with only two lines: left, never right or centred.
        #expect(layout([(72, 500, 700), (72, 500, 686)]).alignment(fontSize: 12) == .left)
    }

    @Test("The justified margin is the median full-line end, so one overhanging glyph doesn't widen it")
    func justifiedMargin() {
        let overhang = layout([(72, 500, 700), (72, 503, 686), (72, 500, 672), (72, 500, 658), (72, 200, 644)])
        #expect(overhang.justifiedMargin == 500)
        #expect(overhang.right == 503)
        #expect(layout([(72, 480, 700), (72, 300, 686)]).justifiedMargin == 480)
    }

    @Test("Column: the widest margin at which every line still breaks where it did")
    func columnFromBreaks() {
        // Line 1 ends at 400; the next line's first word is 60 wide; a space is 4.
        // The next word would have fit up to 464, so the column is just short of that.
        let ragged = layout([(72, 400, 700), (72, 380, 686), (72, 200, 672)], spaceWidth: 4,
                            firstWordEnds: [120, 132, 110])
        // Limits: 400 + 4 + 60 = 464 and 380 + 4 + 38 = 422; the tighter wins, less a hair.
        #expect(abs(ragged.column - (422 - 1)) < 1e-9)
        #expect(ragged.column >= ragged.right)
        // A limit inside the longest line (a line that ended early for another reason, e.g.
        // a hard break) can't narrow the column below the text.
        let early = layout([(72, 400, 700), (72, 150, 686), (72, 380, 672)], spaceWidth: 4, firstWordEnds: [120, 90, 100])
        #expect(early.column == early.right)
        // Without a measured space, or first words, the column is the right margin.
        #expect(layout([(72, 400, 700), (72, 380, 686)]).column == 400)
        #expect(layout([(72, 400, 700), (72, 380, 686)], spaceWidth: 4).column == 400)
        #expect(layout([(72, 400, 700), (72, 380, 686)], spaceWidth: .infinity, firstWordEnds: [100, 100]).column == 400)
    }

    /// Random lines, drawn so each starts before it ends (as `read` always produces).
    private func randomLayout(_ random: inout SplitMix64) -> PDFNativeTextLayout {
        let count = Int.random(in: 1...8, using: &random)
        let left = Double.random(in: -500...1_000, using: &random)
        var baseline = Double.random(in: -1_000...2_000, using: &random)
        let pitch = Double.random(in: 0...40, using: &random)
        var lines: [(Double, Double, Double)] = [], ends: [Double] = []
        for _ in 0..<count {
            let start = left + (Bool.random(using: &random) ? Double.random(in: 0...60, using: &random) : 0)
            let end = start + Double.random(in: 0...600, using: &random)
            lines.append((start, end, baseline))
            ends.append(start + Double.random(in: 0...(end - start), using: &random))
            // Mostly downward steps, sometimes flat or upward.
            baseline -= Int.random(in: 0..<10, using: &random) == 0 ? -pitch : pitch
        }
        return layout(lines, spaceWidth: Bool.random(using: &random) ? Double.random(in: 0...12, using: &random) : .nan,
                      firstWordEnds: ends)
    }

    @Test("Fuzz: finite layouts keep their invariants", arguments: 0..<200)
    func fuzzInvariants(seed: UInt64) {
        var random = SplitMix64(seed: seed)
        let value = randomLayout(&random)
        let context = "seed \(seed): \(value.lines)"
        #expect(value.left <= value.right, "\(context)")
        #expect(value.column >= value.right, "\(context)")
        #expect(value.column.isFinite, "\(context)")
        #expect(value.firstLineIndent >= 0, "\(context)")
        if let pitch = value.linePitch { #expect(pitch > 0 && pitch.isFinite, "\(context)") }
        #expect(value.justifiedMargin >= value.lines.map(\.end).min()! && value.justifiedMargin <= value.right, "\(context)")
        for fontSize in [0.0, 4, 12, 500] {
            let alignment = value.alignment(fontSize: fontSize)
            #expect([.left, .right, .center, .justified].contains(alignment), "\(context)")
            if value.lines.count < 3 { #expect(alignment != .justified, "\(context)") }
            // Deterministic.
            #expect(value.alignment(fontSize: fontSize) == alignment)
        }
    }

    @Test("Metamorphic: moving the text moves its margins and changes nothing else", arguments: 0..<100)
    func fuzzTranslation(seed: UInt64) {
        var random = SplitMix64(seed: seed)
        let value = randomLayout(&random)
        // Power-of-two offsets keep every sum exact, so the comparisons can be exact.
        let dx = Double(Int.random(in: -64...64, using: &random)) * 4, dy = Double(Int.random(in: -64...64, using: &random)) * 8
        var moved = PDFNativeTextLayout(lines: value.lines.map {
            .init(start: $0.start + dx, end: $0.end + dx, baseline: $0.baseline + dy, firstWordEnd: $0.firstWordEnd + dx)
        }, characterSpacing: value.characterSpacing)
        moved.spaceWidth = value.spaceWidth
        let context = "seed \(seed) dx \(dx) dy \(dy)"
        #expect(abs(moved.left - (value.left + dx)) < 1e-6, "\(context)")
        #expect(abs(moved.right - (value.right + dx)) < 1e-6, "\(context)")
        #expect(abs(moved.column - (value.column + dx)) < 1e-6, "\(context)")
        #expect(abs(moved.firstLineIndent - value.firstLineIndent) < 1e-6, "\(context)")
        #expect(abs(moved.firstBaseline - (value.firstBaseline + dy)) < 1e-6, "\(context)")
        switch (value.linePitch, moved.linePitch) {
        case (nil, nil): break
        case let (a?, b?): #expect(abs(a - b) < 1e-6, "\(context)")
        default: Issue.record("pitch appeared or vanished after moving: \(context)")
        }
        // Alignment compares edge spreads, which translation doesn't change, away from
        // the tolerance boundary.
        #expect(abs(moved.justifiedMargin - (value.justifiedMargin + dx)) < 1e-6, "\(context)")
        #expect(moved.alignment(fontSize: 12) == value.alignment(fontSize: 12), "\(context)")
    }

    @Test("Fuzz: hostile numbers (NaN, infinities, zeros, negatives) never trap", arguments: 0..<200)
    func fuzzHostile(seed: UInt64) {
        var random = SplitMix64(seed: seed)
        let pool: [Double] = [.nan, .infinity, -.infinity, 0, -0.0, -1, 1, -1e308, 1e308, .ulpOfOne, .leastNonzeroMagnitude, 72, 500]
        func pick() -> Double { Bool.random(using: &random) ? pool.randomElement(using: &random)! : Double.random(in: -1e4...1e4, using: &random) }
        let count = Int.random(in: 1...6, using: &random)
        var value = PDFNativeTextLayout(lines: (0..<count).map { _ in .init(start: pick(), end: pick(), baseline: pick(), firstWordEnd: pick()) },
                                        characterSpacing: pick())
        value.spaceWidth = pick()
        // Everything is total: evaluate every property.
        _ = (value.left, value.right, value.column, value.firstBaseline, value.firstLineIndent)
        if let pitch = value.linePitch { #expect(pitch > 0, "seed \(seed)") }
        #expect(!value.firstLineIndent.isNaN || value.lines[0].start.isNaN, "seed \(seed)")
        #expect(value.firstLineIndent >= 0 || value.firstLineIndent.isNaN, "seed \(seed)")
        _ = value.justifiedMargin
        let alignment = value.alignment(fontSize: pick())
        if count < 3 { #expect(alignment != .justified, "seed \(seed)") }
        // When the margins are finite, the column never falls inside the text.
        if value.right.isFinite, value.column.isFinite { #expect(value.column >= value.right, "seed \(seed)") }
    }

    // MARK: - Reading glyphs

    private func glyph(_ text: String, x: Double, y: Double, advance: Double, width: Double? = nil, size: Double = 12,
                       characterSpacing: Double = 0, upright: Bool = true) -> PDFNativeGlyphPlacement {
        PDFNativeGlyphPlacement(glyph: PDFNativeGlyph(bytes: Array(text.utf8), text: text, width: width ?? (advance - characterSpacing) / size * 1000,
                                                      wordSpace: text == " "),
                                bounds: CGRect(x: x, y: y - 2, width: max(0.001, advance), height: size), compensation: 0,
                                clipping: false, invisible: false, fontBaseName: "Helvetica", fontSize: size, fillColor: nil,
                                origin: CGPoint(x: x, y: y), advance: advance, characterSpacing: characterSpacing, upright: upright)
    }

    /// Lines of words set left to right, each line `pitch` below the last.
    private func glyphs(_ lines: [String], left: Double = 72, top: Double = 700, pitch: Double = 14, indent: Double = 0,
                        charWidth: Double = 6, space: Double = 3, tracking: Double = 0) -> [PDFNativeGlyphPlacement] {
        var result: [PDFNativeGlyphPlacement] = []
        for (row, line) in lines.enumerated() {
            var x = left + (row == 0 ? indent : 0)
            for character in line {
                let advance = (character == " " ? space : charWidth) + tracking
                result.append(glyph(String(character), x: x, y: top - Double(row) * pitch, advance: advance, characterSpacing: tracking))
                x += advance
            }
        }
        return result
    }

    @Test("Reading glyphs recovers lines, margins, pitch, indent, spacing and first words")
    func readsGlyphs() throws {
        let read = try #require(PDFNativeTextLayout.read(glyphs(["Alpha beta gamma ", "delta epsilon ", "zeta"], indent: 12, tracking: 0.5)))
        #expect(read.lines.count == 3)
        #expect(read.firstBaseline == 700)
        #expect(read.linePitch == 14)
        #expect(read.left == 72)
        #expect(read.firstLineIndent == 12)
        #expect(read.characterSpacing == 0.5)
        #expect(read.spaceWidth == 3.5)
        // The first line's trailing space is not part of its end, nor is the last glyph's tracking.
        let first = read.lines[0]
        // "Alpha beta gamma ": the last visible glyph follows 13 letters and 2 spaces.
        #expect(abs(first.end - (84 + 13 * 6.5 + 2 * 3.5 + 6)) < 1e-9)
        #expect(abs(first.firstWordEnd - (84 + 4 * 6.5 + 6)) < 1e-9)
        #expect(abs(read.lines[1].firstWordEnd - (72 + 4 * 6.5 + 6)) < 1e-9)
    }

    @Test("Reading gives nil for no glyphs, non-finite positions, or any glyph that isn't upright")
    func readRejects() {
        #expect(PDFNativeTextLayout.read([]) == nil)
        var set = glyphs(["Upright text"])
        set.append(glyph("x", x: 200, y: 700, advance: 6, upright: false))
        #expect(PDFNativeTextLayout.read(set) == nil)
        for bad in [Double.nan, .infinity, -.infinity] {
            #expect(PDFNativeTextLayout.read(glyphs(["Fine"]) + [glyph("x", x: bad, y: 700, advance: 6)]) == nil)
            #expect(PDFNativeTextLayout.read(glyphs(["Fine"]) + [glyph("x", x: 200, y: bad, advance: 6)]) == nil)
            #expect(PDFNativeTextLayout.read(glyphs(["Fine"]) + [glyph("x", x: 200, y: 700, advance: bad)]) == nil)
            #expect(PDFNativeTextLayout.read(glyphs(["Fine"]) + [glyph("x", x: 200, y: 700, advance: 6, size: bad)]) == nil)
        }
    }

    @Test("Varying character spacing reads as none; whitespace-only text has no first word or space")
    func readSpacingAndWhitespace() throws {
        let mixed = glyphs(["Tight"], tracking: 0.2) + glyphs(["loose"], left: 120, tracking: 1)
        #expect(try #require(PDFNativeTextLayout.read(mixed)).characterSpacing == 0)
        let blank = try #require(PDFNativeTextLayout.read(glyphs(["\t\t"])))
        #expect(blank.lines.count == 1)
        #expect(blank.lines[0].firstWordEnd.isNaN)
        #expect(blank.spaceWidth.isNaN)
        #expect(blank.left <= blank.right)
    }

    @Test("The space width is the narrowest space: justified lines stretch theirs (Tw), the last line doesn't")
    func narrowestSpace() throws {
        var set = glyphs(["Stretched words here "], space: 5.5) + glyphs(["and here "], top: 686, space: 4.25)
        set += glyphs(["end"], top: 672, space: 3)
        #expect(try #require(PDFNativeTextLayout.read(set)).spaceWidth == 4.25)
        let pdf = try document("BT /F1 12 Tf 14 TL 1 0 0 1 72 700 Tm 2.5 Tw (Justified words set wide) Tj T* 0 Tw (last line set tight) Tj ET")
        let read = try #require(try style(pdf, "Justified words set wide last line set tight").layout)
        #expect(abs(read.spaceWidth - (try helveticaWidth(" ", size: 12))) < 0.001)
    }

    @Test("A superscript's rise stays on its line; a pen jump back to the left starts a new line")
    func readRiseAndPenJump() throws {
        var set = glyphs(["E mc"])
        set.append(glyph("2", x: 72 + 3 * 6 + 3, y: 704, advance: 4, size: 8))
        set.append(contentsOf: glyphs([" holds"], left: 72 + 3 * 6 + 7))
        let read = try #require(PDFNativeTextLayout.read(set))
        #expect(read.lines.count == 1)
        #expect(read.firstBaseline == 700)
        // Same baseline, but the pen goes back to the left margin: a new line (e.g. a
        // table cell or a line set with Tm rather than Td).
        let jump = try #require(PDFNativeTextLayout.read(glyphs(["first line"]) + glyphs(["again"], top: 700)))
        #expect(jump.lines.count == 2)
    }

    @Test("Fuzz: reading random upright paragraphs never traps and recovers what was set", arguments: 0..<150)
    func fuzzRead(seed: UInt64) throws {
        var random = SplitMix64(seed: seed)
        let words = ["a", "the", "reader", "annotates", "margin", "evidence", "x", "PDF", "—", "ﬁle"]
        let lineCount = Int.random(in: 1...6, using: &random)
        let lines = (0..<lineCount).map { _ in
            (0..<Int.random(in: 1...6, using: &random)).map { _ in words.randomElement(using: &random)! }.joined(separator: " ")
                + (Bool.random(using: &random) ? " " : "")
        }
        let size = Double.random(in: 4...40, using: &random)
        let pitch = size * Double.random(in: 1.0...2.0, using: &random)
        let tracking = Bool.random(using: &random) ? 0 : Double.random(in: -0.5...2, using: &random)
        let indent = Bool.random(using: &random) ? 0 : Double.random(in: 1...40, using: &random)
        let set = glyphs(lines, left: Double.random(in: 0...300, using: &random), top: Double.random(in: 300...800, using: &random),
                         pitch: pitch, indent: indent, charWidth: size * 0.5, space: size * 0.25, tracking: tracking)
            .map { glyph($0.glyph.text, x: $0.origin.x, y: $0.origin.y, advance: $0.advance, size: size, characterSpacing: $0.characterSpacing) }
        let context = "seed \(seed): \(lines)"
        let read = try #require(PDFNativeTextLayout.read(set), "\(context)")
        #expect(read.lines.count == lineCount, "\(context)")
        #expect(read.left <= read.right, "\(context)")
        #expect(read.column >= read.right, "\(context)")
        for line in read.lines { #expect(line.start <= line.end, "\(context)") }
        if lineCount > 1 { #expect(abs((read.linePitch ?? .nan) - pitch) < 1e-6, "\(context)") }
        else { #expect(read.linePitch == nil, "\(context)") }
        if lineCount > 1 { #expect(abs(read.firstLineIndent - indent) < 1e-6, "\(context)") }
        #expect(abs(read.characterSpacing - (abs(tracking) < 0.001 ? 0 : tracking)) < 0.006, "\(context)")
        if lineCount < 3 { #expect(read.alignment(fontSize: size) != .justified, "\(context)") }
        // Deterministic: reading the same glyphs twice gives the same numbers.
        let again = try #require(PDFNativeTextLayout.read(set))
        #expect(again.lines.map(\.start) == read.lines.map(\.start) && again.lines.map(\.end) == read.lines.map(\.end), "\(context)")
        #expect(again.column == read.column || (again.column.isNaN && read.column.isNaN), "\(context)")
    }

    // MARK: - Cost

    private func milliseconds(_ body: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try body()
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    }

    @Test("Reading is linear: the page's glyph limit (250 000) reads in well under a second")
    func readCost() throws {
        let line = String(repeating: "word ", count: 20)
        let small = glyphs(Array(repeating: line, count: 250))          // 25 000 glyphs
        let large = glyphs(Array(repeating: line, count: 2_500))        // 250 000 glyphs
        var smallLayout: PDFNativeTextLayout?, largeLayout: PDFNativeTextLayout?
        let smallTime = milliseconds { smallLayout = PDFNativeTextLayout.read(small) }
        let largeTime = milliseconds { largeLayout = PDFNativeTextLayout.read(large) }
        print("TEXT_LAYOUT_READ glyphs=25000 ms=\(Int(smallTime.rounded())) glyphs=250000 ms=\(Int(largeTime.rounded()))")
        #expect(try #require(smallLayout).lines.count == 250)
        #expect(try #require(largeLayout).lines.count == 2_500)
        #expect(largeTime < 1_000)
        // Ten times the glyphs costs about ten times as much, not a hundred (allowing noise).
        #expect(largeTime < max(smallTime, 1) * 40, "\(smallTime) → \(largeTime) ms")
        // Every property of the largest layout is cheap too.
        let value = try #require(largeLayout)
        let propertyTime = milliseconds { _ = (value.column, value.linePitch, value.justifiedMargin, value.alignment(fontSize: 12), value.left, value.right) }
        #expect(propertyTime < 250, "\(propertyTime) ms")
    }

    @Test("Choosing a substitute for a page of text stays quick")
    func substituteCost() throws {
        let page = try measured(String(repeating: sample + " ", count: 60), in: "Georgia")   // ~3 800 glyphs
        var found: (font: NSFont, tracking: Double)?
        let time = milliseconds { found = PDFNativeTextStyle.closestInstalledFontAndTracking(to: "Unknown", flags: 2, size: 12, glyphs: page) }
        print("SUBSTITUTE_CHOICE glyphs=\(page.count) ms=\(Int(time.rounded()))")
        #expect(try #require(found).font.familyName == "Georgia")
        #expect(time < 2_000)
    }

    // MARK: - Reading real content streams

    /// A one-page PDF (612 × 792) whose content stream is `content`, with /F1 Helvetica.
    private func document(_ content: String, rotation: Int = 0, form: String? = nil) throws -> PDFDocument {
        var resources = "/Font << /F1 4 0 R >>"
        if form != nil { resources += " /XObject << /Fm 6 0 R >>" }
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate \(rotation) /Resources << \(resources) >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"]
        if let form {
            objects.append("<< /Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Length \(form.utf8.count) >>\nstream\n\(form)\nendstream")
        }
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try #require(PDFDocument(data: data))
    }

    private func style(_ pdf: PDFDocument, _ text: String, region: CGRect = CGRect(x: 20, y: 100, width: 570, height: 650)) throws -> PDFNativeTextStyleResult {
        try PDFNativeTextStyle.attributedText(in: pdf, region: PageRegion(pageIndex: 0, bounds: region), originalText: text,
            fallback: NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)]))
    }

    /// Helvetica's advance for `text` at `size`, as the PDF's standard metrics give it.
    private func helveticaWidth(_ text: String, size: Double) throws -> Double {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let characters = Array(text.utf16)
        var ids = [CGGlyph](repeating: 0, count: characters.count)
        #expect(CTFontGetGlyphsForCharacters(font, characters, &ids, characters.count))
        var advances = [CGSize](repeating: .zero, count: ids.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, ids, &advances, ids.count)
        return advances.reduce(0) { $0 + $1.width }
    }

    @Test("Character spacing (Tc) is read in page points, scaled by Tz and the text matrix, and not counted after the last glyph")
    func readsCharacterSpacing() throws {
        let plain = try #require(try style(document("BT /F1 12 Tf 2 Tc 1 0 0 1 50 400 Tm (Wide text) Tj ET"), "Wide text").layout)
        #expect(plain.characterSpacing == 2)
        #expect(plain.lines.count == 1)
        #expect(plain.lines[0].start == 50)
        // Nine glyphs, eight gaps of Tc between them; none after the last "t".
        #expect(abs(plain.lines[0].end - (50 + (try helveticaWidth("Wide text", size: 12)) + 8 * 2)) < 0.1)
        #expect(abs(plain.spaceWidth - ((try helveticaWidth(" ", size: 12)) + 2)) < 0.01)
        let condensed = try #require(try style(document("BT /F1 12 Tf 2 Tc 50 Tz 1 0 0 1 50 400 Tm (Wide text) Tj ET"), "Wide text").layout)
        #expect(abs(condensed.characterSpacing - 1) < 1e-9)
        let doubled = try #require(try style(document("BT /F1 6 Tf 1 Tc 2 0 0 2 50 400 Tm (Wide text) Tj ET"), "Wide text").layout)
        #expect(abs(doubled.characterSpacing - 2) < 1e-9)
        #expect(abs(doubled.lines[0].end - plain.lines[0].end) < 0.1)
        let negative = try #require(try style(document("BT /F1 12 Tf -0.5 Tc 1 0 0 1 50 400 Tm (Tight text) Tj ET"), "Tight text").layout)
        #expect(negative.characterSpacing == -0.5)
        #expect(negative.left < negative.right)
    }

    @Test("Superscripts and subscripts (Ts) stay on their line's baseline")
    func readsRise() throws {
        for rise in ["4", "-3", "5.5"] {
            let pdf = try document("BT /F1 12 Tf 14 TL 1 0 0 1 72 600 Tm (E = mc) Tj \(rise) Ts /F1 8 Tf (2) Tj 0 Ts /F1 12 Tf ( holds for) Tj T* (every observer.) Tj ET")
            let read = try #require(try style(pdf, "E = mc2 holds for every observer.").layout, "rise \(rise)")
            #expect(read.lines.count == 2, "rise \(rise): \(read.lines)")
            #expect(read.firstBaseline == 600, "rise \(rise)")
            #expect(read.linePitch == 14, "rise \(rise)")
        }
    }

    @Test("Lines set with T*, Td and a first-line indent read their pitch, margins and indent")
    func readsParagraph() throws {
        let pdf = try document("BT /F1 12 Tf 15 TL 1 0 0 1 96 700 Tm (The first line is indented) Tj -24 -15 Td (and the rest of the lines) Tj T* (start at the margin.) Tj ET")
        let read = try #require(try style(pdf, "The first line is indented and the rest of the lines start at the margin.").layout)
        #expect(read.lines.map(\.baseline) == [700, 685, 670])
        #expect(read.left == 72)
        #expect(read.firstLineIndent == 24)
        #expect(read.linePitch == 15)
        #expect(read.alignment(fontSize: 12) == .left)
    }

    @Test("Text in a scaled form XObject reads in page space")
    func readsFormInPageSpace() throws {
        let pdf = try document("q 2 0 0 2 0 0 cm /Fm Do Q", form: "BT /F1 6 Tf 7 TL 1 0 0 1 36 350 Tm (Scaled form text) Tj T* (on two lines) Tj ET")
        let read = try #require(try style(pdf, "Scaled form text on two lines").layout)
        #expect(read.left == 72)
        #expect(read.firstBaseline == 700)
        #expect(read.linePitch == 14)
    }

    @Test("Rotated, skewed or mirrored text has no layout, but its font is still read", arguments: [
        "0 1 -1 0 300 200",   // a quarter turn
        "0 -1 1 0 300 600",   // the other quarter turn
        "1 0 0.3 1 72 400",   // skewed (synthetic italic)
        "-1 0 0 1 400 400",   // mirrored
        "1 0 0 -1 72 400",    // upside down
    ])
    func rotatedText(matrix: String) throws {
        let pdf = try document("BT /F1 12 Tf \(matrix) Tm (Turned text) Tj ET")
        let result = try style(pdf, "Turned text", region: CGRect(x: 1, y: 1, width: 610, height: 790))
        #expect(result.layout == nil)
        #expect((result.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontName == "Helvetica")
    }

    @Test("A rotated page's upright content still reads its layout, in unrotated page space")
    func rotatedPage() throws {
        let pdf = try document("BT /F1 12 Tf 14 TL 1 0 0 1 72 700 Tm (Upright on a turned page) Tj T* (second line) Tj ET", rotation: 90)
        let read = try #require(try style(pdf, "Upright on a turned page second line").layout)
        #expect(read.firstBaseline == 700)
        #expect(read.linePitch == 14)
    }

    // MARK: - Closest installed font

    /// Glyphs whose PDF widths are `font`'s own advances, scaled by `scale`.
    private func measured(_ text: String, in fontName: String, scale: Double = 1) throws -> [PDFNativeGlyphPlacement] {
        let font = CTFontCreateWithName(fontName as CFString, 1000, nil)
        return try text.map(String.init).enumerated().map { index, character in
            let characters = Array(character.utf16)
            var ids = [CGGlyph](repeating: 0, count: characters.count)
            _ = CTFontGetGlyphsForCharacters(font, characters, &ids, characters.count)
            var advances = [CGSize](repeating: .zero, count: ids.count)
            CTFontGetAdvancesForGlyphs(font, .horizontal, ids, &advances, ids.count)
            let width = advances.reduce(0) { $0 + $1.width } * scale
            #expect(width.isFinite)
            return glyph(character, x: 72 + Double(index) * 6, y: 700, advance: width / 1000 * 12, width: width)
        }
    }

    private let sample = "Reading closely means noticing the argument beneath the prose."

    @Test("A serif-flagged or serif-named missing font gets an installed serif", arguments: [
        ("AcmeText", 2), ("AcmeSerif-Regular", 0), ("TimesTen-Roman", 0), ("Minion Pro", 0), ("FooBook", 0)
    ])
    func serifSubstitute(name: String, flags: Int) throws {
        let found = try #require(PDFNativeTextStyle.closestInstalledFontAndTracking(to: name, flags: flags, size: 12,
                                                                                     glyphs: try measured(sample, in: "Georgia")))
        #expect(PDFNativeTextStyle.serifFamilies.contains(found.font.familyName ?? ""), "\(name) → \(found.font.fontName)")
        #expect(found.font.pointSize == 12)
    }

    @Test("A mono-named or fixed-pitch-flagged missing font gets an installed fixed-pitch font", arguments: [
        ("AcmeMono-Regular", 0), ("CourierStd", 0), ("Consolas", 0), ("SourceCodePro-Regular", 0), ("AcmeText", 1),
        ("AcmeSerif", 3),   // fixed pitch and serif: fixed pitch wins
    ])
    func fixedSubstitute(name: String, flags: Int) throws {
        let found = try #require(PDFNativeTextStyle.closestInstalledFontAndTracking(to: name, flags: flags, size: 11,
                                                                                     glyphs: try measured(sample, in: "Menlo")))
        #expect(PDFNativeTextStyle.fixedFamilies.contains(found.font.familyName ?? ""), "\(name) → \(found.font.fontName)")
        #expect(found.font.isFixedPitch, "\(name) → \(found.font.fontName)")
    }

    @Test("A sans name stays sans even when it says Book; slant and weight follow the name and flags")
    func sansWeightAndSlant() throws {
        let glyphs = try measured(sample, in: "Helvetica")
        let book = try #require(PDFNativeTextStyle.closestInstalledFontAndTracking(to: "AcmeSans-Book", flags: 0, size: 12, glyphs: glyphs))
        #expect(PDFNativeTextStyle.sansFamilies.contains(book.font.familyName ?? ""), "\(book.font.fontName)")
        let italic = try #require(PDFNativeTextStyle.closestInstalledFontAndTracking(to: "AcmeSans", flags: 64, size: 12, glyphs: glyphs))
        #expect(NSFontManager.shared.traits(of: italic.font).contains(.italicFontMask), "\(italic.font.fontName)")
        let bold = try #require(PDFNativeTextStyle.closestInstalledFontAndTracking(to: "AcmeSans-Bold", flags: 0, size: 12, glyphs: glyphs))
        #expect(NSFontManager.shared.traits(of: bold.font).contains(.boldFontMask), "\(bold.font.fontName)")
        let forced = try #require(PDFNativeTextStyle.closestInstalledFontAndTracking(to: "AcmeSans", flags: 262_144, size: 12, glyphs: glyphs))
        #expect(NSFontManager.shared.traits(of: forced.font).contains(.boldFontMask), "\(forced.font.fontName)")
    }

    @Test("An exact match needs no tracking; tracking is capped at 10 % of the average width")
    func trackingBounds() throws {
        let exact = try #require(PDFNativeTextStyle.closestInstalledFontAndTracking(to: "Unknown", flags: 2, size: 12,
                                                                                     glyphs: try measured(sample, in: "Times New Roman")))
        #expect(exact.font.familyName == "Times New Roman")
        #expect(exact.tracking == 0)
        for scale in [0.9, 0.97, 1.02, 1.05, 1.3] {
            let glyphs = try measured(sample, in: "Georgia", scale: scale)
            let found = try #require(PDFNativeTextStyle.closestInstalledFontAndTracking(to: "Unknown", flags: 2, size: 12, glyphs: glyphs))
            let visible = glyphs.filter { $0.glyph.text != " " }
            let average = visible.reduce(0) { $0 + $1.glyph.width } / Double(visible.count)
            #expect(abs(found.tracking) <= average * 0.10 / 1000 * 12 + 1e-9, "scale \(scale): \(found.tracking)")
            // Letter tracking never widens the gap between the substitute's letter widths and
            // the PDF's (spaces get their own correction).
            let chosen = try measured(sample, in: found.font.fontName).filter { $0.glyph.text != " " }
            let gap = visible.reduce(0) { $0 + $1.glyph.width } - chosen.reduce(0) { $0 + $1.glyph.width }
            let tracked = gap - Double(visible.count) * found.tracking / 12 * 1000
            #expect(abs(tracked) <= abs(gap) + 1e-6, "scale \(scale): \(found.font.fontName) \(found.tracking)")
        }
    }

    @Test("Declared widths no real font has give a substitute with no tracking, however far off they are")
    func hostileWidths() throws {
        for scale in [10.0, 1_000, 1e300] {
            let glyphs = try measured(sample, in: "Georgia", scale: scale)
            let found = try #require(PDFNativeTextStyle.closestInstalledFontAndSpacing(to: "Unknown", flags: 2, size: 12, glyphs: glyphs))
            #expect(found.letters == 0 && found.spaces == 0, "scale \(scale)")
        }
        // A plausible but wide original is tracked, and never by more than 10 % of the
        // installed font's own letters.
        let wide = try #require(PDFNativeTextStyle.closestInstalledFontAndSpacing(to: "Unknown", flags: 2, size: 12,
                                                                                  glyphs: try measured(sample, in: "Georgia", scale: 1.3)))
        #expect(wide.letters.isFinite && abs(wide.letters) <= 12 * 0.1)
    }

    @Test("Nothing measurable, or an impossible size, gives no substitute", arguments: [0.0, -12, .nan, .infinity, 20_000])
    func noSubstitute(size: Double) throws {
        #expect(PDFNativeTextStyle.closestInstalledFontAndTracking(to: "Unknown", flags: 0, size: size, glyphs: try measured("abc", in: "Helvetica")) == nil)
    }

    @Test("Whitespace-only or empty glyphs give no substitute")
    func whitespaceOnly() throws {
        #expect(PDFNativeTextStyle.closestInstalledFontAndTracking(to: "Unknown", flags: 0, size: 12, glyphs: []) == nil)
        #expect(PDFNativeTextStyle.closestInstalledFontAndTracking(to: "Unknown", flags: 0, size: 12, glyphs: try measured("   ", in: "Helvetica")) == nil)
        #expect(PDFNativeTextStyle.closestInstalledFont(to: "Unknown", flags: 0, size: 12, glyphs: try measured("\n", in: "Helvetica")) == nil)
    }
}
