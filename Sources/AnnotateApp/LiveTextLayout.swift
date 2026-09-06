import AppKit

@MainActor
enum LiveTextLayout {
    /// The editor lives in zoomed view coordinates; PDF/CoreText styles remain in PDF points.
    static func scaled(_ source: NSAttributedString, by factor: Double) -> NSAttributedString {
        guard factor.isFinite, factor > 0, abs(factor - 1) > 0.000001 else { return source }
        let result = NSMutableAttributedString(attributedString: source)
        let range = NSRange(location: 0, length: source.length)
        source.enumerateAttributes(in: range) { attributes, run, _ in
            if let font = attributes[.font] as? NSFont {
                result.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: font.pointSize * factor), range: run)
            }
            for key in [NSAttributedString.Key.kern, .baselineOffset] {
                if let number = attributes[key] as? NSNumber { result.addAttribute(key, value: number.doubleValue * factor, range: run) }
            }
            if let original = attributes[.paragraphStyle] as? NSParagraphStyle,
               let style = original.mutableCopy() as? NSMutableParagraphStyle {
                style.firstLineHeadIndent *= factor; style.headIndent *= factor; style.tailIndent *= factor
                style.lineSpacing *= factor; style.paragraphSpacing *= factor; style.paragraphSpacingBefore *= factor
                style.minimumLineHeight *= factor; style.maximumLineHeight *= factor; style.defaultTabInterval *= factor
                style.tabStops = original.tabStops.map { NSTextTab(textAlignment: $0.alignment, location: $0.location * factor, options: $0.options) }
                result.addAttribute(.paragraphStyle, value: style, range: run)
            }
        }
        return result
    }
}
