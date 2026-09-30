import AppKit

/// Formatting commands shared by the floating format bar and the Edit inspector, so both
/// change the selected runs (or the whole block, with no selection) the same way.
extension LiveTextEdit {
    func hasTrait(_ trait: NSFontTraitMask) -> Bool { FontCatalog.hasTrait(trait, font: font) }
    func canToggle(_ trait: NSFontTraitMask) -> Bool { FontCatalog.toggling(trait, font: font) != nil }

    func toggle(_ trait: NSFontTraitMask) {
        if attributedText.length == 0 {
            if let changed = FontCatalog.toggling(trait, font: font) { fontName = changed.fontName }
            return
        }
        let changed = RichTextTypography.settingTrait(trait, enabled: !hasTrait(trait), in: attributedText, selection: selectedRange)
        updateAttributedText(changed, selectedRange: selectedRange)
    }

    func chooseFamily(of font: NSFont) {
        if attributedText.length == 0 { fontName = font.fontName; return }
        let changed = RichTextTypography.changingFamily(FontCatalog.family(of: font), in: attributedText, selection: selectedRange)
        updateAttributedText(changed, selectedRange: selectedRange)
    }

    /// Puts an out-of-range size typed into a field back within 4–144 pt.
    func normalizeFontSize() {
        guard !fontSizeIsValid else { return }
        fontSize = fontSize.isFinite ? min(144, max(4, fontSize)) : 14
    }
}
