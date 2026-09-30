import AnnotateCore
import AppKit
import CoreText
import PDFKit

/// Sets edited text exactly where and how the original was set: the same first
/// baseline, left margin, first-line indent, distance between lines, alignment and
/// character spacing, read from the original glyphs (`PDFNativeTextLayout`).
@MainActor
enum MatchedLayout {
    /// Whether a layout read from the page is believable for text at `fontSize`. A crafted
    /// or unusual PDF can put the pen far from its glyphs; such a layout is not applied.
    static func isPlausible(_ layout: PDFNativeTextLayout, fontSize: Double) -> Bool {
        guard fontSize.isFinite, fontSize > 0 else { return false }
        let width = layout.right - layout.left
        return abs(layout.characterSpacing) <= fontSize * 0.5
            && (layout.linePitch.map { $0 >= fontSize * 0.5 && $0 <= fontSize * 5 } ?? true)
            && width.isFinite && width > 0 && layout.firstLineIndent < width
    }

    /// The text with the original's paragraph setting. A paragraph being rewrapped takes
    /// the original alignment; other selections keep their line breaks and their alignment
    /// if it was right or centred, otherwise left.
    static func styled(_ text: NSAttributedString, like layout: PDFNativeTextLayout, rewrapping: Bool) -> NSAttributedString {
        guard text.length > 0 else { return text }
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 12)
        let detected = layout.alignment(fontSize: Double(font.pointSize))
        let alignment = rewrapping ? detected : (detected == .right || detected == .center ? detected : .left)
        let firstParagraph = (text.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        let result = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: result.length)
        // Runs are split where the first paragraph ends, so only it gets the indent, even
        // when every paragraph shares one style.
        var runs: [(value: Any?, range: NSRange)] = []
        text.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
            let end = NSMaxRange(firstParagraph)
            if range.location < end, NSMaxRange(range) > end {
                runs.append((value, NSRange(location: range.location, length: end - range.location)))
                runs.append((value, NSRange(location: end, length: NSMaxRange(range) - end)))
            } else { runs.append((value, range)) }
        }
        for (value, range) in runs {
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.alignment = alignment
            // Only the first paragraph of left-set text has the first-line indent;
            // right-aligned and centred lines simply start wherever they fall.
            let indents = (alignment == .left || alignment == .justified || alignment == .natural)
                && NSIntersectionRange(range, firstParagraph).length > 0
            style.firstLineHeadIndent = indents ? layout.firstLineIndent : 0
            if let pitch = layout.linePitch {
                // A fixed line height reproduces the original baselines exactly; spacing
                // derived from font metrics drifts a little on every line.
                style.minimumLineHeight = pitch
                style.maximumLineHeight = pitch
                style.lineSpacing = 0
                // CoreText adds some of the font's leading on top (rounded, so it can't be
                // predicted from the metrics); measure it and take it off.
                let extra = measuredPitch(font: font, style: style) - pitch
                if extra.isFinite, abs(extra) > 0.001, pitch - extra >= 1 {
                    style.minimumLineHeight = pitch - extra
                    style.maximumLineHeight = pitch - extra
                }
            }
            result.addAttribute(.paragraphStyle, value: style, range: range)
        }
        if layout.characterSpacing != 0 {
            // The original's character spacing adds to any tracking a substitute font needs.
            text.enumerateAttribute(.kern, in: whole) { value, range, _ in
                let existing = (value as? NSNumber)?.doubleValue ?? 0
                result.addAttribute(.kern, value: existing + layout.characterSpacing, range: range)
            }
        }
        return result
    }

    /// The distance CoreText actually puts between two lines set in `font` with `style`.
    private static func measuredPitch(font: NSFont, style: NSParagraphStyle) -> Double {
        let sample = NSAttributedString(string: "Hx\u{2028}Hx", attributes: [.font: font, .paragraphStyle: style])
        let framesetter = CTFramesetterCreateWithAttributedString(sample)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: 10_000, height: 10_000), transform: nil), nil)
        let count = (CTFrameGetLines(frame) as? [CTLine])?.count ?? 0
        guard count >= 2 else { return .nan }
        var origins = [CGPoint](repeating: .zero, count: count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        return origins[0].y - origins[1].y
    }

    /// The block that sets `text` with its first baseline on the original's and its
    /// lines between the original margins, or nil when that would leave the page.
    static func bounds(for text: NSAttributedString, like layout: PDFNativeTextLayout, within page: CGRect,
                       on shown: PDFPage? = nil) -> CGRect? {
        guard text.length > 0 else { return nil }
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 12)
        let alignment = (text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment ?? .left
        // Justified, right-aligned and centred text fills exactly its margins. Ragged text
        // gets a hair of room so its longest line still fits after rounding.
        let exact = alignment == .justified || alignment == .right || alignment == .center
        // Justified text fills its column; ragged text is set to the original column,
        // recovered from where its lines broke.
        let left = layout.left
        var width = alignment == .justified ? layout.justifiedMargin - left
            : exact ? layout.right - left : layout.column - left + 0.01
        // The recovered column may reach past the longest line; that room is used only
        // where the page beside the paragraph is empty, so text never runs into a
        // neighbouring column.
        if !exact, let shown, layout.column > layout.right + 0.5 {
            let size = Double(font.pointSize)
            let strip = CGRect(x: layout.right + 0.5, y: (layout.lines.last?.baseline ?? layout.firstBaseline) - size * 0.3,
                               width: layout.column - layout.right, height: layout.firstBaseline - (layout.lines.last?.baseline ?? layout.firstBaseline) + size * 1.3)
            let occupied = shown.selection(for: strip)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            if occupied { width = layout.right - left + 0.5 }
        }
        guard width > 1, [left, width, layout.firstBaseline].allSatisfy(\.isFinite) else { return nil }
        // Where CoreText puts the first baseline below the top of a frame this wide.
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let tall: CGFloat = 100_000
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: width, height: tall), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        guard !lines.isEmpty else { return nil }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        // With a fixed line height the lines sit on a regular grid, except that CoreText
        // pushes a line whose superscript overruns the height off it. The grid is found
        // from a plain line in the same style, so every other line lands exactly.
        var firstBaselineDepth = tall - origins[0].y
        if layout.linePitch != nil {
            let sample = NSAttributedString(string: "Hx", attributes: text.attributes(at: 0, effectiveRange: nil).filter { $0.key != .baselineOffset })
            let plain = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(sample), CFRange(location: 0, length: 0),
                                                 CGPath(rect: CGRect(x: 0, y: 0, width: width, height: tall), transform: nil), nil)
            var origin = CGPoint.zero
            if ((CTFrameGetLines(plain) as? [CTLine])?.count ?? 0) > 0 {
                CTFrameGetLineOrigins(plain, CFRange(location: 0, length: 1), &origin)
                firstBaselineDepth = tall - origin.y
            }
        }
        // Room for every line, down to the last line's descent.
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(lines[lines.count - 1], nil, &descent, nil)
        let height = ceil(tall - origins[lines.count - 1].y + max(descent, -font.descender)) + 1
        let top = layout.firstBaseline + firstBaselineDepth
        let bounds = CGRect(x: left, y: top - height, width: width, height: height)
        guard page.contains(bounds) else { return nil }
        return bounds
    }
}
