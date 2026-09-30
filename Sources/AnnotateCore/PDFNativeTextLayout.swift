import AppKit
import CoreGraphics

/// How the original text was set on the page, read from its glyphs' pen positions, so an
/// edit can be set the same way: same first baseline, margins, line pitch, alignment,
/// first-line indent and character spacing. Page space; horizontal text only.
public struct PDFNativeTextLayout: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        /// Where the pen starts on this line (the first glyph's origin).
        public let start: Double
        /// Where the last visible glyph ends (its origin plus its width), ignoring
        /// trailing spaces, which justified and ragged lines both carry.
        public let end: Double
        /// The line's baseline.
        public let baseline: Double
        /// Where the line's first word ends.
        public var firstWordEnd: Double = .nan

        public init(start: Double, end: Double, baseline: Double, firstWordEnd: Double = .nan) {
            self.start = start; self.end = end; self.baseline = baseline; self.firstWordEnd = firstWordEnd
        }
    }

    public let lines: [Line]
    /// Character spacing (Tc) shared by every glyph, in points; zero when it varies.
    public let characterSpacing: Double
    /// The width of a word space, in points, when the text has one.
    public var spaceWidth: Double = .nan

    public init(lines: [Line], characterSpacing: Double) {
        precondition(!lines.isEmpty, "A text layout has at least one line")
        self.lines = lines; self.characterSpacing = characterSpacing
    }

    /// The widest right margin consistent with where the original lines broke: each line
    /// ended because the next line's first word would not fit after a space. Ragged text
    /// set to this margin breaks where it did even in a slightly wider substitute font.
    public var column: Double {
        guard lines.count > 1, spaceWidth.isFinite else { return right }
        let limits = zip(lines, lines.dropFirst()).compactMap { line, next -> Double? in
            guard next.firstWordEnd.isFinite else { return nil }
            return line.end + spaceWidth + (next.firstWordEnd - next.start)
        }
        guard let limit = limits.min(), limit > right else { return right }
        // Just short of the limit, so the next word still doesn't fit. (The reader only uses
        // the room past the longest line where the page there is empty.)
        return max(right, limit - max(0.5, spaceWidth * 0.25))
    }

    public var firstBaseline: Double { lines[0].baseline }
    /// The left margin of the text: the start of its lines, not counting an indented
    /// first line.
    public var left: Double {
        lines.count > 1 ? lines.dropFirst().map(\.start).min() ?? lines[0].start : lines[0].start
    }
    /// The right margin: where the longest line ends.
    public var right: Double { lines.map(\.end).max() ?? lines[0].end }
    /// How far the first line starts to the right of the others.
    public var firstLineIndent: Double { max(0, lines[0].start - left) }

    /// The distance from one baseline to the next, or nil for a single line.
    public var linePitch: Double? {
        guard lines.count > 1 else { return nil }
        let steps = zip(lines, lines.dropFirst()).map { $0.baseline - $1.baseline }
        guard steps.allSatisfy({ $0 > 0 }) else { return nil }
        return steps.reduce(0, +) / Double(steps.count)
    }

    /// How the lines line up, for text set at `fontSize`. Two or more lines sharing both
    /// edges, with a shorter last line, are justified (justified line ends jitter by a
    /// glyph's overhang, so that test allows a tenth of the font size); lines sharing only
    /// the right edge are right-aligned and lines sharing only a centre are centred (these
    /// edges are exact, so half a point). Anything else, including one line, is left.
    public func alignment(fontSize: Double) -> NSTextAlignment {
        guard lines.count > 1 else { return .left }
        let exact = 0.5, loose = max(0.75, fontSize * 0.1)
        let lefts = lines.dropFirst().map(\.start), ends = lines.map(\.end)
        func spread(_ values: [Double]) -> Double { (values.max() ?? 0) - (values.min() ?? 0) }
        if lines.count >= 3, spread(lefts) <= exact, spread(Array(ends.dropLast())) <= loose,
           ends.last! < justifiedMargin - loose { return .justified }
        let starts = lines.map(\.start)
        if spread(ends) <= exact, spread(starts) > exact { return .right }
        if spread(lines.map { ($0.start + $0.end) / 2 }) <= exact, spread(starts) > exact { return .center }
        return .left
    }

    /// The right margin of justified text: the typical end of its full lines, so a
    /// glyph that overhangs the column doesn't widen it.
    public var justifiedMargin: Double {
        let full = lines.dropLast().map(\.end).sorted()
        guard !full.isEmpty else { return right }
        return full[full.count / 2]
    }

    /// Reads the layout of glyphs in reading order, or nil when they are not upright
    /// horizontal text (rotated or skewed text keeps the editor's plain placement).
    static func read(_ glyphs: [PDFNativeGlyphPlacement]) -> PDFNativeTextLayout? {
        guard let first = glyphs.first, glyphs.allSatisfy(\.upright),
              glyphs.allSatisfy({ [$0.origin.x, $0.origin.y, $0.advance, $0.fontSize].allSatisfy(\.isFinite) }) else { return nil }
        var lines: [Line] = []
        var start = first.origin.x, baseline = first.origin.y, end = first.origin.x, size = first.fontSize
        var previous = first, firstWordEnd = Double.nan, inFirstWord = true, spaces: [Double] = []
        func close() { lines.append(Line(start: start, end: end, baseline: baseline, firstWordEnd: firstWordEnd)) }
        for glyph in glyphs {
            // A new line: the baseline moves by a good part of a line, or the pen jumps
            // back to the left.
            if abs(glyph.origin.y - baseline) > max(size, glyph.fontSize) * 0.5
                || (glyph !== first && glyph.origin.x < previous.origin.x - max(size, glyph.fontSize)) {
                close()
                start = glyph.origin.x; baseline = glyph.origin.y; end = glyph.origin.x; size = glyph.fontSize
                firstWordEnd = .nan; inFirstWord = true
            }
            let visible = !glyph.glyph.text.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
            if visible {
                // The glyph's own width, without the character spacing that follows it.
                let width = max(0, glyph.advance - glyph.characterSpacing)
                end = max(end, glyph.origin.x + width)
                if inFirstWord { firstWordEnd = glyph.origin.x + width }
            } else {
                if firstWordEnd.isFinite { inFirstWord = false }
                if glyph.glyph.text == " " { spaces.append(glyph.advance) }
            }
            start = min(start, glyph.origin.x)
            previous = glyph
        }
        close()
        // Lines must come down the page in order. PDFs may draw lines in any order; a layout
        // read out of order would anchor the edit on the wrong line, so none is reported.
        // (Cells on one baseline, read left to right, are fine.)
        guard zip(lines, lines.dropFirst()).allSatisfy({ $0.baseline >= $1.baseline }) else { return nil }
        let spacings = Set(glyphs.map { ($0.characterSpacing * 100).rounded() })
        let spacing = spacings.count == 1 ? glyphs[0].characterSpacing : 0
        var layout = PDFNativeTextLayout(lines: lines, characterSpacing: abs(spacing) < 0.001 ? 0 : spacing)
        // A typical space; justified lines stretch theirs, so take the narrowest.
        layout.spaceWidth = spaces.min() ?? .nan
        return layout
    }
}
