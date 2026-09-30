import AnnotateCore
import AppKit
import CoreText
import PDFKit
import Testing
@testable import AnnotateApp

/// A small, fast, seedable generator (SplitMix64) so every fuzz case replays exactly
/// from the seed printed with a failure.
struct SeededGenerator: RandomNumberGenerator {
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

@Suite("Paragraph detection and joining: edge cases, properties and fuzzing", .serialized)
@MainActor
struct ParagraphTextPropertyTests {
    // MARK: - Line geometry edge cases

    @Test("Degenerate or non-finite line geometry never continues a paragraph", arguments: [
        CGRect(x: 72, y: 683, width: 400, height: 0),                        // zero height
        CGRect(x: CGFloat.nan, y: 683, width: 400, height: 14),                     // NaN origin
        CGRect(x: 72, y: CGFloat.infinity, width: 400, height: 14),                 // infinite origin
        CGRect(x: 72, y: 683, width: CGFloat.nan, height: 14),                      // NaN width
        CGRect(x: 72, y: 683, width: 400, height: CGFloat.nan),                     // NaN height
        CGRect.null,
        CGRect.infinite,
        CGRect.zero,
    ])
    func degenerateLower(lower: CGRect) {
        let upper = CGRect(x: 72, y: 700, width: 400, height: 14)
        #expect(!ParagraphText.continues(upper, into: lower))
        #expect(!ParagraphText.continues(lower, into: upper))
    }

    @Test("Continuation thresholds: size, gap, indent and overlap limits", arguments: [
        // Heights differ by exactly a quarter of the taller line: still one paragraph.
        (CGRect(x: 72, y: 700, width: 400, height: 16), CGRect(x: 72, y: 684, width: 400, height: 12), true),
        // Just over a quarter: a different size, so a different block.
        (CGRect(x: 72, y: 700, width: 400, height: 16), CGRect(x: 72, y: 684, width: 400, height: 11.9), false),
        // Gap of exactly 0.75 × height continues; a little more breaks.
        (CGRect(x: 72, y: 700, width: 400, height: 16), CGRect(x: 72, y: 672, width: 400, height: 16), true),
        (CGRect(x: 72, y: 700, width: 400, height: 16), CGRect(x: 72, y: 671.9, width: 400, height: 16), false),
        // Lines overlapping by up to half a line still stack; more is the same line or out of order.
        (CGRect(x: 72, y: 700, width: 400, height: 16), CGRect(x: 72, y: 692, width: 400, height: 16), true),
        (CGRect(x: 72, y: 700, width: 400, height: 16), CGRect(x: 72, y: 692.1, width: 400, height: 16), false),
        // A lower line above the upper one is never its continuation.
        (CGRect(x: 72, y: 700, width: 400, height: 16), CGRect(x: 72, y: 720, width: 400, height: 16), false),
        // First-line indent up to three line heights; a deeper indent is not a first line.
        (CGRect(x: 120, y: 700, width: 350, height: 16), CGRect(x: 72, y: 684, width: 400, height: 16), true),
        (CGRect(x: 120.1, y: 700, width: 350, height: 16), CGRect(x: 72, y: 684, width: 400, height: 16), false),
        // A lower line indented (hanging) further than half a line is not the same paragraph.
        (CGRect(x: 72, y: 700, width: 400, height: 16), CGRect(x: 81, y: 684, width: 390, height: 16), false),
        (CGRect(x: 72, y: 700, width: 400, height: 16), CGRect(x: 80, y: 684, width: 392, height: 16), true),
        // Short last line: overlap is measured against the shorter line, so it still continues.
        (CGRect(x: 72, y: 700, width: 400, height: 16), CGRect(x: 72, y: 684, width: 30, height: 16), true),
    ])
    func thresholds(upper: CGRect, lower: CGRect, expected: Bool) {
        #expect(ParagraphText.continues(upper, into: lower) == expected, "\(upper) → \(lower)")
    }

    @Test("Paragraph range handles a single line, the first and last line, and blocks of paragraphs")
    func rangeEdges() {
        let line = CGRect(x: 72, y: 700, width: 400, height: 14)
        #expect(ParagraphText.paragraphRange(around: 0, in: [line]) == 0...0)
        // Two paragraphs of three lines, split by a paragraph gap, then a heading.
        var lines: [CGRect] = []
        for index in 0..<3 { lines.append(CGRect(x: 72, y: 700 - CGFloat(index) * 16, width: 400, height: 14)) }
        for index in 0..<3 { lines.append(CGRect(x: 72, y: 620 - CGFloat(index) * 16, width: 400, height: 14)) }
        lines.append(CGRect(x: 72, y: 560, width: 300, height: 28))
        #expect(ParagraphText.paragraphRange(around: 0, in: lines) == 0...2)
        #expect(ParagraphText.paragraphRange(around: 2, in: lines) == 0...2)
        #expect(ParagraphText.paragraphRange(around: 3, in: lines) == 3...5)
        #expect(ParagraphText.paragraphRange(around: 5, in: lines) == 3...5)
        #expect(ParagraphText.paragraphRange(around: 6, in: lines) == 6...6)
    }

    @Test("A paragraph on a rotated page is the same paragraph: rotation is display only")
    func rotatedPage() throws {
        let pdf = SamplePDF.make()
        let page = try #require(pdf.page(at: 0))
        let line = try #require(pdf.findString("an exact", withOptions: []).first)
        let point = CGPoint(x: line.bounds(for: page).midX, y: line.bounds(for: page).midY)
        let upright = try #require(ParagraphText.selection(at: point, on: page)?.string)
        for rotation in [90, 180, 270] {
            page.rotation = rotation
            let turned = try #require(ParagraphText.selection(at: point, on: page)?.string, "rotation \(rotation)")
            #expect(turned == upright, "rotation \(rotation)")
        }
    }

    @Test("A point on a heading selects the heading alone, not the paragraph under it")
    func headingIsItsOwnBlock() throws {
        let pdf = SamplePDF.make()
        let page = try #require(pdf.page(at: 0))
        let heading = try #require(pdf.findString("A better way to return", withOptions: []).first)
        let bounds = heading.bounds(for: page)
        let found = try #require(ParagraphText.selection(at: CGPoint(x: bounds.midX, y: bounds.midY), on: page)?.string)
        #expect(found.trimmingCharacters(in: .whitespacesAndNewlines) == "A better way to return")
    }

    @Test("A blank page has no paragraphs")
    func blankPage() {
        let page = PDFPage()
        #expect(ParagraphText.selection(at: CGPoint(x: 100, y: 100), on: page) == nil)
    }

    // MARK: - Line pitch

    @Test("Line pitch is nil for one line and the mean centre-to-centre step for several")
    func linePitch() throws {
        let pdf = SamplePDF.make()
        let page = try #require(pdf.page(at: 0))
        let single = try #require(pdf.findString("an exact", withOptions: []).first)
        #expect(ParagraphText.linePitch(of: single, on: page) == nil)
        let line = try #require(pdf.findString("an exact", withOptions: []).first)
        let paragraph = try #require(ParagraphText.selection(at: CGPoint(x: line.bounds(for: page).midX,
                                                                          y: line.bounds(for: page).midY), on: page))
        let centres = paragraph.selectionsByLine().map { $0.bounds(for: page).midY }
        #expect(centres.count >= 2)
        let pitch = try #require(ParagraphText.linePitch(of: paragraph, on: page))
        let expected = (try #require(centres.first) - (try #require(centres.last))) / CGFloat(centres.count - 1)
        #expect(abs(pitch - expected) < 0.01)
        // 12 pt body text: its lines sit a little more than 12 pt apart.
        #expect(pitch > 12 && pitch < 24)
    }

    // MARK: - Keeping line pitch

    @Test("Keeping line pitch preserves text, fonts and each run's other paragraph settings")
    func keepingPitchPreservesRuns() throws {
        let font = NSFont.systemFont(ofSize: 12)
        let centred = NSMutableParagraphStyle(); centred.alignment = .center; centred.headIndent = 7
        let text = NSMutableAttributedString(string: "Centred then plain", attributes: [.font: font, .paragraphStyle: centred])
        text.setAttributes([.font: NSFont.boldSystemFont(ofSize: 12)], range: NSRange(location: 8, length: 10))
        let spaced = ParagraphText.keepingLinePitch(20, in: text)
        #expect(spaced.string == text.string)
        let natural = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        let first = try #require(spaced.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(first.alignment == .center && first.headIndent == 7)
        #expect(abs(first.lineSpacing - (20 - natural)) < 0.01)
        // A run with no paragraph style gets one too, with the same spacing.
        let second = try #require(spaced.attribute(.paragraphStyle, at: 10, effectiveRange: nil) as? NSParagraphStyle)
        #expect(abs(second.lineSpacing - (20 - natural)) < 0.01)
        #expect(spaced.attribute(.font, at: 10, effectiveRange: nil) as? NSFont == NSFont.boldSystemFont(ofSize: 12))
        // The input is not mutated.
        #expect((text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing == 0)
    }

    @Test("Keeping line pitch ignores unusable pitches and empty text", arguments: [0, -3, .infinity, -.infinity, .nan] as [CGFloat])
    func keepingPitchRejects(pitch: CGFloat) {
        let text = NSAttributedString(string: "Text", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        #expect(ParagraphText.keepingLinePitch(pitch, in: text) === text)
        let empty = NSAttributedString(string: "")
        #expect(ParagraphText.keepingLinePitch(18, in: empty) === empty)
    }

    @Test("Keeping line pitch without a font measures against the 12 pt system font")
    func keepingPitchWithoutFont() throws {
        let font = NSFont.systemFont(ofSize: 12)
        let natural = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        let spaced = ParagraphText.keepingLinePitch(natural + 3, in: NSAttributedString(string: "No font"))
        let style = try #require(spaced.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(abs(style.lineSpacing - 3) < 0.01)
    }

    // MARK: - Joining lines

    @Test("Joining lines: examples of every line end and surrounding blanks", arguments: [
        ("", ""),
        ("one line", "one line"),
        ("a\nb", "a b"),
        ("a\rb", "a b"),
        ("a\r\nb", "a b"),
        ("a\n\rb", "a b"),           // \n then \r: two line ends, one join
        ("a \t\n\t b", "a b"),
        ("a\n\nb", "a b"),           // a blank line joins once
        ("Steps:\n\n1. Open", "Steps:\n1. Open"),  // no stray space before a kept list break
        ("this -\nthat", "this - that"),           // a spaced dash is not a broken word
        ("\nlead", " lead"),
        ("trail\n", "trail "),
        ("tabs\tstay\tinside", "tabs\tstay\tinside"),
        ("  spaces  stay  ", "  spaces  stay  "),
        ("é\u{2028}ü", "é\u{2028}ü"),  // Unicode line separator is not a PDF line end
        ("😀\n😀", "😀 😀"),
    ])
    func joiningExamples(input: String, expected: String) {
        #expect(ParagraphText.joiningLines(NSAttributedString(string: input)).string == expected)
    }

    @Test("Joining lines does not mutate its input")
    func joiningDoesNotMutate() {
        let input = NSMutableAttributedString(string: "a\nb")
        _ = ParagraphText.joiningLines(input)
        #expect(input.string == "a\nb")
    }

    // MARK: - Property / fuzz passes

    private static let tag = NSAttributedString.Key("AnnotateTestSourceIndex")

    /// The reference behaviour of `joiningLines`, written independently: each run of
    /// blanks and line ends (CRLF as one; blank lines included) becomes one space. Returns the joined
    /// UTF-16 units with, for each, the source index it came from and whether it is a
    /// joining space standing for `range` in the source.
    private static func referenceJoin(_ units: [UInt16]) -> [(unit: UInt16, source: Int, joined: Range<Int>?)] {
        let space: UInt16 = 0x20, tab: UInt16 = 0x09, cr: UInt16 = 0x0D, lf: UInt16 = 0x0A
        func blank(_ unit: UInt16) -> Bool { unit == space || unit == tab }
        var output: [(unit: UInt16, source: Int, joined: Range<Int>?)] = []
        var index = 0
        while index < units.count {
            var end = index
            while end < units.count, blank(units[end]) { end += 1 }
            if end < units.count, units[end] == cr || units[end] == lf {
                // A run of line ends (blank lines) with the blanks around them is one join.
                while end < units.count, units[end] == cr || units[end] == lf {
                    end += (units[end] == cr && end + 1 < units.count && units[end + 1] == lf) ? 2 : 1
                    while end < units.count, blank(units[end]) { end += 1 }
                }
                output.append((space, index, index..<end))
                index = end
            } else if end > index {
                for position in index..<end { output.append((units[position], position, nil)) }
                index = end
            } else {
                output.append((units[index], index, nil))
                index += 1
            }
        }
        return output
    }

    /// Text built from pieces; `plain` leaves out hyphens, soft hyphens and anything that
    /// can start a list item, so every line end becomes exactly one space.
    private static func randomText(_ generator: inout SeededGenerator, plain: Bool) -> String {
        let common = ["\r", "\n", "\r\n", "\t", " ", "  ", "word", "é", "😀", "\u{2028}", ",", "\n\r"]
        let special = ["-", "\u{2010}", "\u{00AD}", "a", "B", ".", ")", "1", "•", "*", "–", "Word", "\u{00AD}\n"]
        let pieces = plain ? common : common + special
        let count = Int.random(in: 0...40, using: &generator)
        return (0..<count).map { _ in pieces.randomElement(using: &generator)! }.joined()
    }

    /// Tags every UTF-16 unit with its own index and scatters bold runs.
    private static func tagged(_ string: String, seed: UInt64, _ generator: inout SeededGenerator) -> NSAttributedString {
        let length = string.utf16.count
        let source = NSMutableAttributedString(string: string)
        for index in 0..<length { source.addAttribute(tag, value: index, range: NSRange(location: index, length: 1)) }
        if length > 0 {
            for _ in 0..<3 {
                let start = Int.random(in: 0..<length, using: &generator)
                let run = Int.random(in: 0...(length - start), using: &generator)
                source.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: CGFloat(seed % 20 + 6)),
                                    range: NSRange(location: start, length: run))
            }
        }
        return source
    }

    @Test("Fuzz: plain text joins exactly as the reference, one space per line end, attributes aligned",
          arguments: Array(UInt64(1)...UInt64(300)))
    func joiningFuzz(seed: UInt64) throws {
        var generator = SeededGenerator(seed: seed)
        let string = Self.randomText(&generator, plain: true)
        let units = Array(string.utf16)
        let source = Self.tagged(string, seed: seed, &generator)
        let joined = ParagraphText.joiningLines(source)
        let context = "seed \(seed), input \(string.debugDescription)"
        let lineEnds = joined.string.utf16.filter { $0 == 0x0A || $0 == 0x0D }
        #expect(lineEnds.isEmpty, "\(context)")
        let expected = Self.referenceJoin(units)
        #expect(Array(joined.string.utf16) == expected.map(\.unit), "\(context)")
        guard joined.length == expected.count else { return }
        for (index, entry) in expected.enumerated() {
            let tag = joined.attribute(Self.tag, at: index, effectiveRange: nil) as? Int
            let font = joined.attribute(.font, at: index, effectiveRange: nil) as? NSFont
            if let range = entry.joined {
                // A joining space carries the attributes of text it replaced.
                let owner = try #require(tag, "\(context) at \(index)")
                #expect(range.contains(owner), "\(context) at \(index)")
            } else {
                #expect(tag == entry.source, "\(context) at \(index)")
                #expect(font == source.attribute(.font, at: entry.source, effectiveRange: nil) as? NSFont, "\(context) at \(index)")
            }
        }
    }

    @Test("Fuzz: with hyphens, soft hyphens and list markers, joining keeps every character once, in order, and breaks only before list items",
          arguments: Array(UInt64(1)...UInt64(400)))
    func joiningRulesFuzz(seed: UInt64) throws {
        var generator = SeededGenerator(seed: seed)
        let string = Self.randomText(&generator, plain: false)
        let units = Array(string.utf16)
        let source = Self.tagged(string, seed: seed, &generator)
        let joined = ParagraphText.joiningLines(source)
        let context = "seed \(seed), input \(string.debugDescription), output \(joined.string.debugDescription)"
        #expect(ParagraphText.joiningLines(source).isEqual(to: joined), "Deterministic: \(context)")
        // Idempotent, except that a second pass drops blanks left just before a kept list
        // break (a blank line before a list item leaves "text \n- item"; reported, not pinned).
        let again = ParagraphText.joiningLines(joined).string
        let settled = joined.string.replacingOccurrences(of: "[ \t]+\n", with: "\n", options: .regularExpression)
        #expect(again == settled, "Idempotent: \(context)")
        let output = Array(joined.string.utf16)
        #expect(!output.contains(0x0D), "\(context)")
        // A line break survives only where a list item starts.
        let text = joined.string as NSString
        for (index, unit) in output.enumerated() where unit == 0x0A {
            #expect(ParagraphText.startsListItem(text.substring(from: index + 1)), "\(context) at \(index)")
        }
        // Each output unit comes from a distinct source unit, in order: either itself, or
        // the space or break standing for a line end.
        let blanks: Set<UInt16> = [0x20, 0x09, 0x0A, 0x0D]
        var tags: [Int] = []
        for (index, unit) in output.enumerated() {
            let tag = try #require(joined.attribute(Self.tag, at: index, effectiveRange: nil) as? Int, "\(context) at \(index)")
            #expect(tag > (tags.last ?? -1), "\(context) at \(index)")
            tags.append(tag)
            #expect(unit == units[tag] || ((unit == 0x20 || unit == 0x0A) && blanks.contains(units[tag])), "\(context) at \(index)")
        }
        // Every visible character survives with its own attributes; a soft hyphen goes only
        // where it ends a line.
        let kept = Set(tags)
        for (index, unit) in units.enumerated() where !blanks.contains(unit) {
            var next = index + 1
            while next < units.count, units[next] == 0x20 || units[next] == 0x09 { next += 1 }
            let endsLine = next < units.count && (units[next] == 0x0A || units[next] == 0x0D)
            let expectedKept = !(unit == 0xAD && endsLine)
            #expect(kept.contains(index) == expectedKept, "\(context): source unit \(index)")
        }
    }

    @Test("Joining rules: hyphenated words, soft hyphens and list items", arguments: [
        ("inter-\nnational", "inter-national"),
        ("inter\u{2010}\nnational", "inter\u{2010}national"),
        ("inter\u{00AD}\nnational", "international"),
        ("inter\u{00AD} \n national", "international"),
        ("soft\u{00AD}hyphen stays mid-line", "soft\u{00AD}hyphen stays mid-line"),
        ("COVID-\n19", "COVID- 19"),               // not a lowercase continuation: keep the space
        ("Anglo-\nSaxon", "Anglo- Saxon"),
        ("Steps:\n1. Open\n2. Save", "Steps:\n1. Open\n2. Save"),
        ("Items:\n• one\n• two", "Items:\n• one\n• two"),
        ("Choose:\na) this\nb) that", "Choose:\na) this\nb) that"),
        ("Text\n- item", "Text\n- item"),
        ("Text\n-item", "Text -item"),             // no space after the dash: not a list marker
        ("Text\r\n  * star", "Text\n* star"),
        ("version\n2.0 ships", "version 2.0 ships"),
        ("in 1999\n100 people", "in 1999 100 people"),
    ])
    func joiningRules(input: String, expected: String) {
        #expect(ParagraphText.joiningLines(NSAttributedString(string: input)).string == expected)
    }

    /// Coordinates that PDFs and PDFKit can hand us, sane or not.
    private static func randomCoordinate(_ generator: inout SeededGenerator) -> CGFloat {
        switch Int.random(in: 0..<12, using: &generator) {
        case 0: return .nan
        case 1: return .infinity
        case 2: return -.infinity
        case 3: return 0
        case 4: return -CGFloat.random(in: 0...800, using: &generator)
        case 5: return CGFloat.greatestFiniteMagnitude
        default: return CGFloat.random(in: 0...800, using: &generator).rounded()
        }
    }

    private static func randomLines(_ generator: inout SeededGenerator) -> [CGRect] {
        let count = Int.random(in: 1...25, using: &generator)
        let style = Int.random(in: 0..<3, using: &generator)
        var top = CGFloat.random(in: 400...780, using: &generator).rounded()
        return (0..<count).map { _ in
            switch style {
            case 0: // Anything at all, including NaN/inf, zero and negative sizes.
                return CGRect(x: randomCoordinate(&generator), y: randomCoordinate(&generator),
                              width: randomCoordinate(&generator), height: randomCoordinate(&generator))
            case 1: // Mostly plausible text lines, some overlapping or out of order.
                let height = [10, 12, 14, 24].randomElement(using: &generator)! as CGFloat
                top -= CGFloat(Int.random(in: -8...30, using: &generator))
                return CGRect(x: CGFloat(Int.random(in: 40...120, using: &generator)), y: top,
                              width: CGFloat(Int.random(in: 0...500, using: &generator)), height: height)
            default: // A rotated page's lines in page space: tall, narrow columns side by side.
                top += CGFloat(Int.random(in: 10...20, using: &generator))
                return CGRect(x: top, y: CGFloat(Int.random(in: 40...120, using: &generator)),
                              width: 14, height: CGFloat(Int.random(in: 50...500, using: &generator)))
            }
        }
    }

    @Test("Fuzz: paragraph ranges never trap, contain their line, stay in bounds, and are maximal chains",
          arguments: Array(UInt64(1)...UInt64(400)))
    func paragraphRangeFuzz(seed: UInt64) {
        var generator = SeededGenerator(seed: seed)
        let lines = Self.randomLines(&generator)
        for index in lines.indices {
            let range = ParagraphText.paragraphRange(around: index, in: lines)
            let context = "seed \(seed), line \(index) of \(lines)"
            #expect(range.contains(index), "\(context)")
            #expect(range.lowerBound >= 0 && range.upperBound < lines.count, "\(context)")
            #expect(ParagraphText.paragraphRange(around: index, in: lines) == range, "Deterministic: \(context)")
            // Every line of a paragraph finds the same paragraph.
            for member in range { #expect(ParagraphText.paragraphRange(around: member, in: lines) == range, "\(context)") }
            // Neighbours inside continue; the lines just outside do not.
            for member in range.dropLast() { #expect(ParagraphText.continues(lines[member], into: lines[member + 1]), "\(context)") }
            if range.lowerBound > 0 { #expect(!ParagraphText.continues(lines[range.lowerBound - 1], into: lines[range.lowerBound]), "\(context)") }
            if range.upperBound < lines.count - 1 { #expect(!ParagraphText.continues(lines[range.upperBound], into: lines[range.upperBound + 1]), "\(context)") }
        }
    }

    @Test("Metamorphic: moving both lines, or scaling both by a power of two, never changes continuation",
          arguments: Array(UInt64(1)...UInt64(200)))
    func continuationMetamorphic(seed: UInt64) {
        var generator = SeededGenerator(seed: seed)
        // Integral coordinates keep every translated and power-of-two-scaled value exact.
        func line() -> CGRect {
            CGRect(x: CGFloat(Int.random(in: 30...200, using: &generator)), y: CGFloat(Int.random(in: 500...720, using: &generator)),
                   width: CGFloat(Int.random(in: 0...500, using: &generator)), height: CGFloat(Int.random(in: 0...30, using: &generator)))
        }
        let upper = line()
        var lower = line()
        if Bool.random(using: &generator) { lower.origin.y = upper.minY - CGFloat(Int.random(in: 8...30, using: &generator)) }
        let base = ParagraphText.continues(upper, into: lower)
        let dx = CGFloat(Int.random(in: -300...300, using: &generator)), dy = CGFloat(Int.random(in: -300...300, using: &generator))
        let context = "seed \(seed): \(upper) → \(lower)"
        #expect(ParagraphText.continues(upper.offsetBy(dx: dx, dy: dy), into: lower.offsetBy(dx: dx, dy: dy)) == base, "\(context)")
        for scale in [0.5, 2, 4] as [CGFloat] {
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            #expect(ParagraphText.continues(upper.applying(transform), into: lower.applying(transform)) == base, "\(context) × \(scale)")
        }
    }

    @Test("Fuzz: keeping line pitch never produces negative or non-finite spacing", arguments: Array(UInt64(1)...UInt64(100)))
    func keepingPitchFuzz(seed: UInt64) throws {
        var generator = SeededGenerator(seed: seed)
        let size = CGFloat(Int.random(in: 4...144, using: &generator))
        let text = NSAttributedString(string: "Paragraph", attributes: [.font: NSFont.systemFont(ofSize: size)])
        let pitch = CGFloat.random(in: 0.01...400, using: &generator)
        let spaced = ParagraphText.keepingLinePitch(pitch, in: text)
        let style = try #require(spaced.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.lineSpacing >= 0 && style.lineSpacing.isFinite, "seed \(seed), size \(size), pitch \(pitch)")
        #expect(spaced.string == text.string)
    }
}
