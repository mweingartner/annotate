import AppKit

/// Font family and trait changes preserve each selected run's other attributes and point size.
@MainActor
enum RichTextTypography {
    static func changingFamily(_ family: String, in text: NSAttributedString, selection: NSRange) -> NSAttributedString {
        transformFonts(in: text, selection: selection) { FontCatalog.font(in: family, matching: $0) ?? $0 }
    }

    static func settingTrait(_ trait: NSFontTraitMask, enabled: Bool, in text: NSAttributedString, selection: NSRange) -> NSAttributedString {
        transformFonts(in: text, selection: selection) { font in
            enabled ? NSFontManager.shared.convert(font, toHaveTrait: trait) : NSFontManager.shared.convert(font, toNotHaveTrait: trait)
        }
    }

    private static func transformFonts(in text: NSAttributedString, selection: NSRange, transform: (NSFont) -> NSFont) -> NSAttributedString {
        guard text.length > 0 else { return text.copy() as? NSAttributedString ?? NSAttributedString(string: "") }
        let range: NSRange
        if selection.length == 0 { range = NSRange(location: 0, length: text.length) }
        else {
            let start = min(text.length, max(0, selection.location))
            range = NSRange(location: start, length: min(text.length - start, max(0, selection.length)))
        }
        let result = NSMutableAttributedString(attributedString: text)
        text.enumerateAttribute(.font, in: range) { value, affectedRange, _ in
            let font = value as? NSFont ?? NSFont.systemFont(ofSize: 14)
            result.addAttribute(.font, value: transform(font), range: affectedRange)
        }
        return result
    }
}
