import AppKit
import CoreText
import PDFKit

/// A paragraph on a PDF page. PDFs store positioned lines, not paragraphs, so a
/// paragraph is recovered from the lines' geometry: consecutive lines of about the same
/// height, stacked at about one line's spacing, sharing a left edge (a first-line indent
/// is allowed). Headings, captions and the next paragraph break that pattern.
enum ParagraphText {
    /// The paragraph around `point`, or nil when the point is not on a line of text.
    @MainActor
    static func selection(at point: CGPoint, on page: PDFPage) -> PDFSelection? { paragraph(at: point, on: page)?.selection }

    /// The paragraph around `point`, and whether it may be rewrapped: lines joined only
    /// because they share a right edge or centre (a title block, a signature, a column of
    /// figures) keep their line breaks, so editing one line never rejoins the others.
    @MainActor
    static func paragraph(at point: CGPoint, on page: PDFPage) -> (selection: PDFSelection, rewraps: Bool)? {
        guard let all = page.selection(for: page.bounds(for: .cropBox)) else { return nil }
        let lines = all.selectionsByLine().filter {
            $0.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let frames = lines.map { $0.bounds(for: page) }
        guard let hit = frames.firstIndex(where: { $0.insetBy(dx: -2, dy: -2).contains(point) }) else { return nil }
        let range = paragraphRange(around: hit, in: frames)
        guard let paragraph = lines[range.lowerBound].copy() as? PDFSelection else { return nil }
        for index in range.dropFirst() { paragraph.add(lines[index]) }
        let rewraps = range.dropFirst().allSatisfy { sharesLeftEdge(frames[$0 - 1], frames[$0]) }
        return (paragraph, rewraps)
    }

    /// Whether `lower` continues `upper` along the left edge (same edge, or `upper` indented).
    static func sharesLeftEdge(_ upper: CGRect, _ lower: CGRect) -> Bool {
        let height = max(upper.height, lower.height)
        return abs(upper.minX - lower.minX) <= height * 0.5 || (upper.minX > lower.minX && upper.minX - lower.minX <= height * 3)
    }

    /// The indices of the lines that form one paragraph with line `index`. Lines are in
    /// reading order, top to bottom, in page space (y grows upward).
    static func paragraphRange(around index: Int, in lines: [CGRect]) -> ClosedRange<Int> {
        var first = index, last = index
        while first > 0, continues(lines[first - 1], into: lines[first]) { first -= 1 }
        while last < lines.count - 1, continues(lines[last], into: lines[last + 1]) { last += 1 }
        return first...last
    }

    /// Whether `lower` reads as the next line of the same paragraph as `upper`.
    static func continues(_ upper: CGRect, into lower: CGRect) -> Bool {
        let height = max(upper.height, lower.height)
        guard height > 0, [upper, lower].allSatisfy({ $0.width > 0 && $0.minX.isFinite && $0.minY.isFinite }) else { return false }
        let gap = upper.minY - lower.maxY
        let similarSize = abs(upper.height - lower.height) <= height * 0.25
        let stacked = gap >= -height * 0.5 && gap <= height * 0.75
        // Same left edge, or the upper line indented as a paragraph's first line; or, for
        // right-aligned and centred text, the same right edge or centre.
        let aligned = abs(upper.minX - lower.minX) <= height * 0.5
            || (upper.minX > lower.minX && upper.minX - lower.minX <= height * 3)
            // Glyph edges are exact; ragged lines rarely share a right edge this closely.
            || abs(upper.maxX - lower.maxX) <= 0.5
            || abs(upper.midX - lower.midX) <= 0.5
        let overlap = min(upper.maxX, lower.maxX) - max(upper.minX, lower.minX)
        return similarSize && stacked && aligned && overlap > min(upper.width, lower.width) * 0.5
    }

    /// The distance from one line to the next in a selection spanning several lines, or
    /// nil for a single line. Measured between line centres, which ascenders and
    /// descenders shift far less than line tops or bottoms.
    @MainActor
    static func linePitch(of selection: PDFSelection, on page: PDFPage) -> CGFloat? {
        let centres = selection.selectionsByLine()
            .filter { $0.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
            .map { $0.bounds(for: page).midY }
        guard centres.count > 1 else { return nil }
        let steps = zip(centres, centres.dropFirst()).map { $0 - $1 }.filter { $0 > 0 }
        guard !steps.isEmpty else { return nil }
        return steps.reduce(0, +) / CGFloat(steps.count)
    }

    /// Sets line spacing so rewrapped lines sit `pitch` apart, as the original lines did.
    /// The first line keeps its place; the spacing goes between lines.
    static func keepingLinePitch(_ pitch: CGFloat, in text: NSAttributedString) -> NSAttributedString {
        guard pitch.isFinite, pitch > 0, text.length > 0 else { return text }
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 12)
        let natural = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        let spacing = max(0, pitch - natural)
        let result = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: result.length)
        text.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.lineSpacing = spacing
            result.addAttribute(.paragraphStyle, value: style, range: range)
        }
        return result
    }

    /// Turns the line ends PDFKit reports inside a paragraph into spaces, keeping every
    /// character's attributes, so the text rewraps as a paragraph when edited. A word
    /// hyphenated across lines joins without a space (a soft hyphen disappears), and a
    /// line that starts a list item keeps its line break.
    static func joiningLines(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let string = result.string as NSString
        // Spaces, tabs and blank lines around a line end belong to that one line end.
        let lineEnd = try! NSRegularExpression(pattern: "[ \\t]*(?:(?:\\r\\n|\\n|\\r)[ \\t]*)+")
        let matches = lineEnd.matches(in: result.string, range: NSRange(location: 0, length: string.length))
        for match in matches.reversed() {
            let before = match.range.location > 0 ? string.substring(with: NSRange(location: match.range.location - 1, length: 1)) : ""
            // A short look-ahead is all the rules need; copying the rest of the text for
            // every line end would be quadratic on a page of thousands of lines.
            let end = NSMaxRange(match.range)
            let after = string.substring(with: NSRange(location: end, length: min(8, string.length - end)))
            if before == "\u{00AD}" {
                // A soft hyphen only marks where the word was broken.
                result.replaceCharacters(in: NSRange(location: match.range.location - 1, length: match.range.length + 1), with: "")
            } else if ["-", "\u{2010}"].contains(before), after.first?.isLowercase == true,
                      match.range.location >= 2,
                      string.substring(with: NSRange(location: match.range.location - 2, length: 1)).first?.isLetter == true {
                // A word broken across lines ("exam-" + "ple"); a spaced dash ("this -") is not.
                result.replaceCharacters(in: match.range, with: "")
            } else if startsListItem(after) {
                result.replaceCharacters(in: match.range, with: "\n")
            } else {
                result.replaceCharacters(in: match.range, with: " ")
            }
        }
        return result
    }

    /// "• ", "– ", "* ", "1. ", "2) ", "a) " and the like.
    static func startsListItem(_ line: String) -> Bool {
        line.range(of: #"^(?:[•◦▪‣–—*-]|\d{1,3}[.)]|[A-Za-z][.)])\s"#, options: .regularExpression) != nil
    }
}
