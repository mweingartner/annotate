import AppKit
import CoreGraphics
import CoreText
import PDFKit

public struct PDFNativeTextStyleResult {
    public let text: NSAttributedString
    /// User-visible notices for unavailable source faces. Empty means no substitution.
    public let fontSubstitutions: [String]
    public let requiresScannedEditing: Bool
    /// How the original text was set, for setting the edit the same way; nil for text
    /// that is not upright and horizontal.
    public let layout: PDFNativeTextLayout?

    public init(text: NSAttributedString, fontSubstitutions: [String], requiresScannedEditing: Bool, layout: PDFNativeTextLayout? = nil) {
        self.text = text; self.fontSubstitutions = fontSubstitutions
        self.requiresScannedEditing = requiresScannedEditing; self.layout = layout
    }
}

/// Reads actual source fonts because PDFKit may substitute private system font names.
@MainActor
public enum PDFNativeTextStyle {
    public static func attributedText(in document: PDFDocument, region: PageRegion, originalText: String,
                                      fallback: NSAttributedString) throws -> PDFNativeTextStyleResult {
        guard !document.isLocked, document.allowsCopying else { throw PDFNativeTextError.permission }
        guard !document.isEncrypted else { throw PDFNativeTextError.unsupported("Source font inspection needs an unencrypted working copy.") }
        guard let page = document.page(at: region.pageIndex), MarkerCodec.finite(region.bounds),
              region.bounds.width >= 1, region.bounds.height >= 1, page.bounds(for: .cropBox).contains(region.bounds),
              fallback.length > 0, fallback.length <= 1_000_000,
              let bytes = document.dataRepresentation(), let provider = CGDataProvider(data: bytes as CFData),
              let source = CGPDFDocument(provider), let dictionary = source.page(at: region.pageIndex + 1)?.dictionary else {
            throw PDFNativeTextError.invalidSelection
        }
        var data = Data()
        if let stream = nativeStream(dictionary, "Contents") { data = try nativeDecodedStream(stream) }
        else if let contents = nativeArray(dictionary, "Contents") {
            for index in 0..<CGPDFArrayGetCount(contents) {
                var stream: CGPDFStreamRef?
                guard CGPDFArrayGetStream(contents, index, &stream), let stream else {
                    throw PDFNativeTextError.malformed("A page content array contains a non-stream object.")
                }
                data.append(try nativeDecodedStream(stream)); data.append(10)
            }
        }
        let program = try PDFNativeTextProgram(data: data, resources: PDFNativeTextEditor.inheritedResources(dictionary))
        try PDFNativeTextEditor.selectGlyphs(in: program, region: region.bounds, originalText: originalText, allowInvisible: true)
        let glyphs = program.glyphs.filter(\.selected)
        var cache: [String: NSFont] = [:]
        // Tracking that brings a substitute font to the original's widths, per original font
        // and size (two missing fonts can map to the same substitute).
        var tracking: [String: (letters: Double, spaces: Double)] = [:]
        var substitutions: [String] = []
        let fallbackFont = fallback.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? NSFont.systemFont(ofSize: 14)
        // Worked out once per font: the substitute and its tracking at the first size met,
        // scaled for other sizes. Glyphs are grouped by font once.
        var substitutes: [String: (font: NSFont, letters: Double, spaces: Double, size: Double)] = [:]
        let byFont = Dictionary(grouping: glyphs, by: \.fontBaseName)
        var sourceUnits: [(scalar: Unicode.Scalar, font: NSFont, color: NSColor?, key: String)] = []
        var spaceStyles: [Int: (font: NSFont, color: NSColor?, key: String)] = [:]
        for glyph in glyphs {
            let key = "\(glyph.fontBaseName)|\(glyph.fontSize)"
            let font: NSFont
            if let cached = cache[key] { font = cached }
            else {
                do { font = try sourceFont(name: glyph.fontBaseName, size: glyph.fontSize) }
                catch let unavailable as UnavailableSourceFont {
                    // The closest installed font: same kind (serif, fixed pitch), weight and
                    // slant, and the glyph widths nearest the PDF's own for these characters.
                    // Never the PDF's own embedded outlines: a document's font must not draw
                    // what the person types, and macOS subsets can't map new characters anyway.
                    let chosen: (font: NSFont, letters: Double, spaces: Double, size: Double)
                    if let known = substitutes[glyph.fontBaseName] { chosen = known }
                    else if substitutes.count >= 32 {
                        // A selection naming dozens of missing fonts gets the fallback beyond the
                        // first few, so matching can't stall the app.
                        let font = (try? sourceFont(name: fallbackFont.fontName, size: glyph.fontSize)) ?? NSFont.systemFont(ofSize: glyph.fontSize)
                        chosen = (font, 0, 0, glyph.fontSize)
                    } else {
                        let closest = closestInstalledFontAndSpacing(to: unavailable.name, flags: program.fontFlags[glyph.fontBaseName] ?? 0,
                                                                     size: glyph.fontSize, glyphs: byFont[glyph.fontBaseName] ?? [])
                        let font = closest?.font
                            ?? (try? sourceFont(name: fallbackFont.fontName, size: glyph.fontSize)) ?? NSFont.systemFont(ofSize: glyph.fontSize)
                        chosen = (font, closest?.letters ?? 0, closest?.spaces ?? 0, glyph.fontSize)
                        substitutes[glyph.fontBaseName] = chosen
                    }
                    let scale = chosen.size > 0 ? glyph.fontSize / chosen.size : 1
                    font = CTFontCreateCopyWithAttributes(chosen.font, glyph.fontSize, nil, nil) as NSFont
                    // Scaled for this size, finite, and never more than half the font size.
                    func bounded(_ value: Double) -> Double {
                        let scaled = value * scale, limit = glyph.fontSize * 0.5
                        guard scaled.isFinite, limit.isFinite, abs(scaled) >= 0.001 else { return 0 }
                        return min(max(scaled, -limit), limit)
                    }
                    let letters = bounded(chosen.letters), spaces = bounded(chosen.spaces)
                    if letters != 0 || spaces != 0 { tracking[key] = (letters, spaces) }
                    let notice = "\(unavailable.name) isn’t installed; using \(font.displayName ?? font.fontName), the closest installed match."
                    if !substitutions.contains(notice) { substitutions.append(notice) }
                }
                cache[key] = font
            }
            let sourceColor = glyph.fillColor.flatMap(NSColor.init(cgColor:))
            // OCR styling describes an invisible search layer, not the scan's ink.
            // New visible text must never inherit its zero-opacity appearance.
            let color = glyph.invisible ? (sourceColor ?? .black).withAlphaComponent(1) : sourceColor
            for scalar in glyph.glyph.text.decomposedStringWithCompatibilityMapping.unicodeScalars {
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { spaceStyles[sourceUnits.count] = (font, color, key) }
                else { sourceUnits.append((scalar, font, color, key)) }
            }
        }
        let characters = characterRanges(in: fallback.string)
        let fallbackUnits = characters.flatMap { normalized($0.text) }
        guard sourceUnits.map(\.scalar) == fallbackUnits, fallbackUnits == normalized(originalText), let first = sourceUnits.first else {
            throw PDFNativeTextError.sourceMismatch
        }
        let result = NSMutableAttributedString(attributedString: fallback)
        var cursor = 0, previous = (font: first.font, color: first.color, key: first.key)
        for character in characters {
            let units = normalized(character.text)
            let style: (font: NSFont, color: NSColor?, key: String)
            if units.isEmpty { style = spaceStyles[cursor] ?? previous }
            else {
                style = (sourceUnits[cursor].font, sourceUnits[cursor].color, sourceUnits[cursor].key)
                // A Unicode character cluster cannot safely carry incompatible source faces.
                guard sourceUnits[cursor..<(cursor + units.count)].allSatisfy({ $0.font == style.font }) else {
                    throw PDFNativeTextError.unsupported("The selected character combines incompatible source font runs.")
                }
                cursor += units.count
                previous = style
            }
            result.addAttribute(.font, value: style.font, range: character.range)
            if let kern = tracking[style.key] {
                let value = units.isEmpty ? kern.spaces : kern.letters
                if value != 0 { result.addAttribute(.kern, value: value, range: character.range) }
            }
            if let color = style.color { result.addAttribute(.foregroundColor, value: color, range: character.range) }
        }
        return PDFNativeTextStyleResult(text: NSAttributedString(attributedString: result), fontSubstitutions: substitutions,
            requiresScannedEditing: glyphs.contains(where: \.invisible), layout: PDFNativeTextLayout.read(glyphs))
    }

    private static func normalized(_ text: String) -> [Unicode.Scalar] {
        text.decomposedStringWithCompatibilityMapping.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func characterRanges(in text: String) -> [(text: String, range: NSRange)] {
        var offset = 0
        return text.map { character in
            let string = String(character), length = string.utf16.count
            defer { offset += length }
            return (string, NSRange(location: offset, length: length))
        }
    }

    private static func sourceFont(name original: String, size: Double) throws -> NSFont {
        guard size.isFinite, size > 0, size <= 10_000 else { throw PDFNativeTextError.unsupported("The source font has an invalid effective size.") }
        var name = original
        if let plus = name.firstIndex(of: "+"), name.distance(from: name.startIndex, to: plus) == 6,
           name[..<plus].allSatisfy({ $0.isASCII && $0.isUppercase }) {
            name = String(name[name.index(after: plus)...])
        }
        // Private SF PostScript names are intentionally inaccessible through NSFont(name:).
        // AppKit's system-font API selects their real weight instead of CoreText's Times fallback.
        for prefix in [".SFNSDisplay", ".SFNSText", ".SFNS", ".AppleSystemUIFont"] where name.hasPrefix(prefix) {
            let components = name.components(separatedBy: "_")
            let baseName = components[0]
            var suffix = String(baseName.dropFirst(prefix.count)).replacingOccurrences(of: "-", with: "").lowercased()
            let italic = suffix.hasSuffix("italic") || suffix.hasSuffix("oblique")
            if suffix.hasSuffix("italic") { suffix.removeLast(6) }
            else if suffix.hasSuffix("oblique") { suffix.removeLast(7) }
            let weights: [String: NSFont.Weight] = ["": .regular, "regular": .regular, "ultralight": .ultraLight,
                "thin": .thin, "light": .light, "medium": .medium, "semibold": .semibold, "demi": .semibold,
                "bold": .bold, "heavy": .heavy, "black": .black]
            guard let weight = weights[suffix] else { throw unavailable(name) }
            let variations = try decodedVariations(Array(components.dropFirst()), name: name)
            var font = NSFont.systemFont(ofSize: size, weight: weight)
            // Apple writes variable SF fonts with a Regular base and 16.16 hex axis values.
            // Match the system API's actual axis values, which can vary between OS releases.
            let weightAxis = NSNumber(value: 0x77676874)
            if let desired = variations[weightAxis]?.doubleValue {
                let candidates: [NSFont.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
                if let matching = candidates.map({ NSFont.systemFont(ofSize: size, weight: $0) }).first(where: {
                    abs(variationValue(weightAxis, in: $0) - desired) < 0.00001
                }) { font = matching }
            }
            if italic {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                guard NSFontManager.shared.traits(of: font).contains(.italicFontMask) else { throw unavailable(name) }
            }
            return try applyingVariations(variations, to: font, name: name)
        }
        guard let font = NSFont(name: name, size: size), font.fontName.caseInsensitiveCompare(name) == .orderedSame else {
            throw unavailable(name)
        }
        return font
    }

    private static func decodedVariations(_ components: [String], name: String) throws -> [NSNumber: NSNumber] {
        var result: [NSNumber: NSNumber] = [:]
        for component in components {
            let tag = Array(component.prefix(4).utf8)
            guard tag.count == 4, tag.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else { throw unavailable(name) }
            let hexadecimal = String(component.dropFirst(4))
            // An axis without a suffix retains its font-program default.
            guard !hexadecimal.isEmpty else { continue }
            guard hexadecimal.count <= 8, let bits = UInt32(hexadecimal, radix: 16) else { throw unavailable(name) }
            let axis = tag.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            result[NSNumber(value: axis)] = NSNumber(value: Double(Int32(bitPattern: bits)) / 65536)
        }
        return result
    }

    private static func variationValue(_ identifier: NSNumber, in font: NSFont) -> Double {
        if let values = CTFontCopyVariation(font) as? [NSNumber: NSNumber], let value = values[identifier] { return value.doubleValue }
        let axes = CTFontCopyVariationAxes(font) as? [[String: Any]] ?? []
        return axes.first(where: { $0[kCTFontVariationAxisIdentifierKey as String] as? NSNumber == identifier })?[kCTFontVariationAxisDefaultValueKey as String] as? Double ?? .nan
    }

    private static func applyingVariations(_ variations: [NSNumber: NSNumber], to font: NSFont, name: String) throws -> NSFont {
        guard !variations.isEmpty else { return font }
        let axes = CTFontCopyVariationAxes(font) as? [[String: Any]] ?? []
        for (identifier, value) in variations {
            guard let axis = axes.first(where: { $0[kCTFontVariationAxisIdentifierKey as String] as? NSNumber == identifier }),
                  let minimum = axis[kCTFontVariationAxisMinimumValueKey as String] as? Double,
                  let maximum = axis[kCTFontVariationAxisMaximumValueKey as String] as? Double,
                  (minimum...maximum).contains(value.doubleValue) else { throw unavailable(name) }
        }
        if variations.allSatisfy({ abs(variationValue($0.key, in: font) - $0.value.doubleValue) < 0.00001 }) { return font }
        let descriptor = font.fontDescriptor.addingAttributes([NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): variations])
        guard let result = NSFont(descriptor: descriptor, size: font.pointSize),
              variations.allSatisfy({ abs(variationValue($0.key, in: result) - $0.value.doubleValue) < 0.00001 }) else { throw unavailable(name) }
        return result
    }

    /// Families that ship with macOS, grouped by kind, to stand in for a font that isn't installed.
    static let sansFamilies = ["Helvetica Neue", "Helvetica", "Arial", "Avenir Next", "Avenir Next Condensed", "Avenir", "Gill Sans",
                               "Optima", "Futura", "Verdana", "Trebuchet MS", "Lucida Grande", "Arial Narrow", "Tahoma", "PT Sans"]
    static let serifFamilies = ["Times New Roman", "Times", "Georgia", "Palatino", "Baskerville", "Hoefler Text", "Iowan Old Style",
                                "Charter", "Cochin", "Didot", "Big Caslon", "Bodoni 72", "Superclarendon", "PT Serif", "New York"]
    static let fixedFamilies = ["Menlo", "Courier New", "Courier", "Monaco", "SF Mono", "PT Mono", "Andale Mono"]

    /// The installed font most like a missing one: the same kind (serif, sans, fixed
    /// pitch), weight and slant as its name and flags say, with glyph widths nearest the
    /// PDF's own for the characters in use. Nil when nothing measurable is installed.
    static func closestInstalledFont(to name: String, flags: Int, size: Double,
                                     glyphs: [PDFNativeGlyphPlacement]) -> NSFont? {
        closestInstalledFontAndTracking(to: name, flags: flags, size: size, glyphs: glyphs)?.font
    }

    /// The closest installed font with separate tracking, in points, for letters and for
    /// word spaces, each bringing the substitute's average width to the original's. Letters
    /// and spaces differ between fonts independently (a wide space with narrow letters), so
    /// one shared value would squeeze the letters to pay for the spaces. Letters are capped
    /// at 10 % of their average width, word spaces at a third of theirs (justified text
    /// varies its spaces that much routinely): slightly different spacing is far less
    /// visible than lines that break differently from the original.
    static func closestInstalledFontAndSpacing(to name: String, flags: Int, size: Double,
                                               glyphs: [PDFNativeGlyphPlacement]) -> (font: NSFont, letters: Double, spaces: Double)? {
        guard let found = closestMatch(to: name, flags: flags, size: size, glyphs: glyphs) else { return nil }
        // Widths outside what any real font declares (1/1000 em) aren't measurements to
        // track against: substitute plainly.
        guard found.counts.values.allSatisfy({ $0.width.isFinite && $0.width >= 0 && $0.width <= 4000 }) else {
            return (found.font, 0, 0)
        }
        func correction(_ space: Bool) -> Double {
            var original = 0.0, substitute = 0.0, count = 0
            for (text, entry) in found.counts where isSpace(text) == space {
                guard let advance = found.advances[text] else { continue }
                original += entry.width * Double(entry.count); substitute += advance * Double(entry.count); count += entry.count
            }
            guard count > 0, original > 0, substitute > 0 else { return 0 }
            // The cap comes from the installed font's widths, not the PDF's, which a crafted
            // file controls; the smaller of the two averages bounds it.
            let average = min(original, substitute) / Double(count)
            let cap = average * (space ? 0.33 : 0.10)
            let perGlyph = min(max((original - substitute) / Double(count), -cap), cap)
            let points = perGlyph / 1000 * size
            return points.isFinite && abs(points) >= 0.001 ? points : 0
        }
        return (found.font, correction(false), correction(true))
    }

    private static func isSpace(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    /// The closest installed font and the tracking, in points, that brings its average
    /// glyph width to the original's so lines break where they did. No tracking beyond
    /// 6 % of the average width: past that it would distort the letters.
    static func closestInstalledFontAndTracking(to name: String, flags: Int, size: Double,
                                                glyphs: [PDFNativeGlyphPlacement]) -> (font: NSFont, tracking: Double)? {
        closestInstalledFontAndSpacing(to: name, flags: flags, size: size, glyphs: glyphs).map { ($0.font, $0.letters) }
    }

    /// The installed font most like a missing one, with each distinct character's advance
    /// in it and the original's character counts and widths (1/1000 em).
    private static func closestMatch(to name: String, flags: Int, size: Double, glyphs: [PDFNativeGlyphPlacement])
        -> (font: NSFont, advances: [String: Double], counts: [String: (count: Int, width: Double)])? {
        guard size.isFinite, size > 0, size <= 10_000 else { return nil }
        let lower = name.lowercased()
        let fixed = flags & 1 != 0 || ["mono", "courier", "consol", "code"].contains { lower.contains($0) }
        let serif = !fixed && (flags & 2 != 0 || ["serif", "roman", "times", "georgia", "garamond", "cambria", "book", "minion",
                                                  "caslon", "palatino", "baskerville"].contains { lower.contains($0) })
            && !lower.contains("sans")
        let italic = flags & 64 != 0 || lower.contains("italic") || lower.contains("oblique")
        let weight: Int = ["black", "heavy"].contains { lower.contains($0) } ? 11
            : lower.contains("extrabold") || lower.contains("ultrabold") ? 10
            : lower.contains("semibold") || lower.contains("demi") ? 8
            : lower.contains("bold") || flags & 262_144 != 0 ? 9
            : lower.contains("medium") ? 6
            : lower.contains("light") ? 3 : 5
        let families = fixed ? fixedFamilies : serif ? serifFamilies : sansFamilies
        // Each distinct character is measured once, weighted by how often it appears.
        var counts: [String: (count: Int, width: Double)] = [:]
        for glyph in glyphs where !glyph.glyph.text.isEmpty {
            counts[glyph.glyph.text, default: (0, glyph.glyph.width)].count += 1
        }
        let visible = counts.filter { !isSpace($0.key) }
        guard !visible.isEmpty else { return nil }
        let total = visible.reduce(0) { $0 + $1.value.width * Double($1.value.count) }
        var best: (font: NSFont, error: Double, advances: [String: Double])?
        for family in families {
            var traits: NSFontTraitMask = []
            if italic { traits.insert(.italicFontMask) }
            guard let candidate = NSFontManager.shared.font(withFamily: family, traits: traits, weight: weight, size: size) else { continue }
            if italic, !NSFontManager.shared.traits(of: candidate).contains(.italicFontMask) { continue }
            let probe = CTFontCreateCopyWithAttributes(candidate, 1000, nil, nil)
            var error = 0.0, advances: [String: Double] = [:], usable = true
            for (text, entry) in counts {
                let characters = Array(text.utf16)
                var ids = [CGGlyph](repeating: 0, count: characters.count)
                guard CTFontGetGlyphsForCharacters(probe, characters, &ids, characters.count) else {
                    if isSpace(text) { continue }
                    usable = false; break
                }
                var sizes = [CGSize](repeating: .zero, count: ids.count)
                CTFontGetAdvancesForGlyphs(probe, .horizontal, ids, &sizes, ids.count)
                let advance = sizes.reduce(0) { $0 + $1.width }
                advances[text] = advance
                if !isSpace(text) { error += abs(advance - entry.width) * Double(entry.count) }
            }
            guard usable else { continue }
            let relative = total > 0 ? error / total : .infinity
            if relative.isFinite, relative < (best?.error ?? .infinity) { best = (candidate, relative, advances) }
        }
        guard let best else { return nil }
        return (best.font, best.advances, counts)
    }

    private struct UnavailableSourceFont: Error { let name: String }

    private static func unavailable(_ name: String) -> UnavailableSourceFont {
        UnavailableSourceFont(name: name)
    }
}
