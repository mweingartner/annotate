import AnnotateCore
import AppKit
import CoreText
import Observation
import PDFKit

@MainActor @Observable
final class LiveTextEdit {
    let identifier: String
    let pageIndex: Int
    let isExistingContent: Bool
    private(set) var attributedText: NSAttributedString
    private(set) var selectedRange: NSRange
    private var fallbackFont: NSFont
    private var fallbackColor: NSColor
    private let defaultFont: NSFont
    private let defaultColor: NSColor
    private var fallbackAlignment: NSTextAlignment = .left
    private var fallbackUnderline = false
    private var fallbackKern = 0.0
    private var fallbackLineSpacing = 0.0
    private var fallbackParagraphSpacing = 0.0
    private var pendingFontSize: Double?
    /// Incomplete numeric input never displaces the last valid on-page rectangle.
    var bounds: CGRect {
        didSet {
            if geometryIsValid { appliedBounds = bounds }
            changed()
        }
    }
    private(set) var appliedBounds: CGRect
    private let pageBounds: CGRect?
    @ObservationIgnored var needsUndoCheckpoint = false
    @ObservationIgnored var changed: () -> Void = {}
    @ObservationIgnored var selectionChanged: () -> Void = {}
    @ObservationIgnored var nativeSource: PDFDocument?
    @ObservationIgnored var nativeOriginalRegion: PageRegion?
    @ObservationIgnored var nativeOriginalText = ""
    var nativeUpdateFailed = false
    var nativeFailureMessage: String?
    var canEditScannedText = false
    var usesScannedTextEditing = false
    var fontSubstitutionMessage: String?
    @ObservationIgnored var isApplyingNativeUpdate = false

    init(identifier: String, pageIndex: Int, text: String, font: NSFont, color: NSColor, bounds: CGRect,
         pageBounds: CGRect? = nil, attributedText: NSAttributedString? = nil, isExistingContent: Bool = false) {
        self.identifier = identifier
        self.pageIndex = pageIndex
        self.isExistingContent = isExistingContent
        fallbackFont = font
        fallbackColor = color
        defaultFont = font
        defaultColor = color
        self.bounds = bounds
        appliedBounds = bounds
        self.pageBounds = pageBounds
        let initial = attributedText ?? NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        self.attributedText = NSAttributedString(attributedString: initial)
        selectedRange = NSRange(location: 0, length: initial.length)
        synchronizeFallbacks()
    }

    /// Compatibility for plain-text callers. Replacing a substring keeps the untouched rich runs.
    var text: String {
        get { attributedText.string }
        set {
            guard newValue != attributedText.string else { return }
            let old = attributedText.string
            var prefixLength = 0
            for (first, second) in zip(old, newValue) {
                guard first == second else { break }
                prefixLength += String(first).utf16.count
            }
            let oldLength = attributedText.length, newLength = newValue.utf16.count
            var suffixLength = 0
            for (first, second) in zip(old.reversed(), newValue.reversed()) {
                let count = String(first).utf16.count
                guard first == second, suffixLength + count <= min(oldLength, newLength) - prefixLength else { break }
                suffixLength += count
            }
            let removed = NSRange(location: prefixLength, length: oldLength - prefixLength - suffixLength)
            let added = (newValue as NSString).substring(with: NSRange(location: prefixLength, length: newLength - prefixLength - suffixLength))
            let result = NSMutableAttributedString(attributedString: attributedText)
            if oldLength == 0 { result.append(NSAttributedString(string: added, attributes: typingAttributes)) }
            else { result.replaceCharacters(in: removed, with: added) }
            updateAttributedText(result, selectedRange: NSRange(location: prefixLength + added.utf16.count, length: 0))
        }
    }

    var font: NSFont { attributesAtSelection[.font] as? NSFont ?? fallbackFont }
    var fontName: String {
        get { font.fontName }
        set {
            guard let requested = NSFont(name: newValue, size: font.pointSize) else { return }
            fallbackFont = requested
            transformFonts { NSFont(name: newValue, size: $0.pointSize) ?? $0 }
        }
    }
    var fontSize: Double {
        get { pendingFontSize ?? font.pointSize }
        set {
            guard newValue.isFinite, (4...144).contains(newValue) else {
                pendingFontSize = newValue
                return
            }
            pendingFontSize = nil
            fallbackFont = NSFontManager.shared.convert(fallbackFont, toSize: newValue)
            transformFonts { NSFontManager.shared.convert($0, toSize: newValue) }
        }
    }
    var fontSizeIsValid: Bool { pendingFontSize == nil }
    var color: NSColor {
        get { attributesAtSelection[.foregroundColor] as? NSColor ?? fallbackColor }
        set {
            fallbackColor = newValue
            applyAttribute(.foregroundColor, value: newValue)
        }
    }
    var alignment: NSTextAlignment {
        get { (attributesAtSelection[.paragraphStyle] as? NSParagraphStyle)?.alignment ?? fallbackAlignment }
        set {
            fallbackAlignment = newValue
            guard attributedText.length > 0 else { changed(); return }
            let paragraphs = (attributedText.string as NSString).paragraphRange(for: formattingRange)
            let result = NSMutableAttributedString(attributedString: attributedText)
            attributedText.enumerateAttribute(.paragraphStyle, in: paragraphs) { value, range, _ in
                let paragraph = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                paragraph.alignment = newValue
                result.addAttribute(.paragraphStyle, value: paragraph, range: range)
            }
            commit(result)
        }
    }
    var isUnderlined: Bool {
        get {
            if let value = attributesAtSelection[.underlineStyle] as? NSNumber { return value.intValue != 0 }
            return fallbackUnderline
        }
        set {
            fallbackUnderline = newValue
            applyAttribute(.underlineStyle, value: newValue ? NSUnderlineStyle.single.rawValue : nil)
        }
    }

    var letterSpacing: Double {
        get { (attributesAtSelection[.kern] as? NSNumber)?.doubleValue ?? fallbackKern }
        set {
            guard newValue.isFinite, (-10...30).contains(newValue) else { return }
            fallbackKern = newValue
            applyAttribute(.kern, value: newValue)
        }
    }
    var lineSpacing: Double {
        get { (attributesAtSelection[.paragraphStyle] as? NSParagraphStyle).map { Double($0.lineSpacing) } ?? fallbackLineSpacing }
        set {
            guard newValue.isFinite, (0...144).contains(newValue) else { return }
            fallbackLineSpacing = newValue
            transformParagraphs { $0.lineSpacing = newValue }
        }
    }
    var paragraphSpacing: Double {
        get { (attributesAtSelection[.paragraphStyle] as? NSParagraphStyle).map { Double($0.paragraphSpacing) } ?? fallbackParagraphSpacing }
        set {
            guard newValue.isFinite, (0...144).contains(newValue) else { return }
            fallbackParagraphSpacing = newValue
            transformParagraphs { $0.paragraphSpacing = newValue }
        }
    }

    var typingAttributes: [NSAttributedString.Key: Any] {
        var attributes = attributesAtSelection
        attributes[.font] = font
        attributes[.foregroundColor] = color
        let paragraph = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacing = paragraphSpacing
        attributes[.paragraphStyle] = paragraph
        attributes[.kern] = letterSpacing
        if isUnderlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        else { attributes.removeValue(forKey: .underlineStyle) }
        return attributes
    }

    func updateAttributedText(_ text: NSAttributedString, selectedRange: NSRange) {
        let contentChanged = !attributedText.isEqual(to: text)
        let previousSelection = self.selectedRange
        attributedText = NSAttributedString(attributedString: text)
        self.selectedRange = clamped(selectedRange, length: text.length)
        pendingFontSize = nil
        synchronizeFallbacks()
        if contentChanged { changed() }
        else if previousSelection != self.selectedRange { selectionChanged() }
    }

    func updateSelection(_ range: NSRange) {
        let selection = clamped(range, length: attributedText.length)
        guard selection != selectedRange else { return }
        selectedRange = selection
        pendingFontSize = nil
        synchronizeFallbacks()
        selectionChanged()
    }

    var geometryIsValid: Bool {
        [bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height].allSatisfy(\.isFinite)
            && bounds.size.width >= 1 && bounds.size.height >= 1 && (pageBounds?.contains(bounds) ?? true)
    }
    var textOverflows: Bool {
        guard attributedText.length > 0 else { return false }
        guard appliedBounds.width >= 1, appliedBounds.height >= 1 else { return true }
        return !textFits(in: appliedBounds.size)
    }

    /// Grows or shrinks downward while retaining the top edge and width. Never spills off the page.
    @discardableResult
    func fitHeightToText() -> Bool {
        guard geometryIsValid else { return false }
        let size = requiredTextSize(width: appliedBounds.width)
        let height = max(1, ceil(size.height))
        let fitted = CGRect(x: appliedBounds.minX, y: appliedBounds.maxY - height, width: appliedBounds.width, height: height)
        guard height.isFinite, pageBounds?.contains(fitted) ?? true, textFits(in: fitted.size) else { return false }
        bounds = fitted
        return true
    }

    var x: Double { get { Double(bounds.origin.x) } set { bounds.origin.x = newValue } }
    var y: Double { get { Double(bounds.origin.y) } set { bounds.origin.y = newValue } }
    var width: Double { get { Double(bounds.width) } set { bounds.size.width = newValue } }
    var height: Double { get { Double(bounds.height) } set { bounds.size.height = newValue } }

    private var attributesAtSelection: [NSAttributedString.Key: Any] {
        guard attributedText.length > 0 else { return [:] }
        let location = selectedRange.length == 0 && selectedRange.location > 0 ? selectedRange.location - 1 : selectedRange.location
        return attributedText.attributes(at: min(max(0, location), attributedText.length - 1), effectiveRange: nil)
    }
    private var formattingRange: NSRange {
        selectedRange.length == 0 ? NSRange(location: 0, length: attributedText.length) : clamped(selectedRange, length: attributedText.length)
    }
    private func clamped(_ range: NSRange, length: Int) -> NSRange {
        let location = min(length, max(0, range.location))
        return NSRange(location: location, length: min(length - location, max(0, range.length)))
    }
    private func synchronizeFallbacks() {
        // Missing attributes use the session's source defaults, never the style of the
        // previously selected run. Empty text intentionally retains the last typing style.
        guard attributedText.length > 0 else { return }
        let attributes = attributesAtSelection
        fallbackFont = attributes[.font] as? NSFont ?? defaultFont
        fallbackColor = attributes[.foregroundColor] as? NSColor ?? defaultColor
        fallbackAlignment = (attributes[.paragraphStyle] as? NSParagraphStyle)?.alignment ?? .natural
        fallbackUnderline = ((attributes[.underlineStyle] as? NSNumber)?.intValue ?? 0) != 0
        fallbackKern = (attributes[.kern] as? NSNumber)?.doubleValue ?? 0
        fallbackLineSpacing = Double((attributes[.paragraphStyle] as? NSParagraphStyle)?.lineSpacing ?? 0)
        fallbackParagraphSpacing = Double((attributes[.paragraphStyle] as? NSParagraphStyle)?.paragraphSpacing ?? 0)
    }
    private func transformParagraphs(_ transform: (NSMutableParagraphStyle) -> Void) {
        guard attributedText.length > 0 else { changed(); return }
        let range = (attributedText.string as NSString).paragraphRange(for: formattingRange)
        let result = NSMutableAttributedString(attributedString: attributedText)
        attributedText.enumerateAttribute(.paragraphStyle, in: range) { value, run, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            transform(style)
            result.addAttribute(.paragraphStyle, value: style, range: run)
        }
        commit(result)
    }
    private func transformFonts(_ transform: (NSFont) -> NSFont) {
        guard attributedText.length > 0 else { changed(); return }
        let result = NSMutableAttributedString(attributedString: attributedText)
        attributedText.enumerateAttribute(.font, in: formattingRange) { value, range, _ in
            result.addAttribute(.font, value: transform(value as? NSFont ?? fallbackFont), range: range)
        }
        commit(result)
    }
    private func applyAttribute(_ key: NSAttributedString.Key, value: Any?) {
        guard attributedText.length > 0 else { changed(); return }
        let result = NSMutableAttributedString(attributedString: attributedText)
        if let value { result.addAttribute(key, value: value, range: formattingRange) }
        else { result.removeAttribute(key, range: formattingRange) }
        commit(result)
    }
    private func commit(_ text: NSAttributedString) {
        guard !attributedText.isEqual(to: text) else { return }
        attributedText = NSAttributedString(attributedString: text)
        synchronizeFallbacks()
        changed()
    }
    private func requiredTextSize(width: Double) -> CGSize {
        let source: NSAttributedString
        if attributedText.length == 0 { source = NSAttributedString(string: " ", attributes: typingAttributes) }
        else { source = attributedText }
        let framesetter = CTFramesetterCreateWithAttributedString(source)
        return CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: source.length), nil,
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude), nil)
    }

    /// Match PDFNativeTextEditor's full CoreText destination rectangle exactly.
    private func textFits(in size: CGSize) -> Bool {
        guard attributedText.length > 0 else { return true }
        let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributedText.length),
            CGPath(rect: CGRect(origin: .zero, size: size), transform: nil), nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        return visible.location + visible.length == attributedText.length
    }
}
