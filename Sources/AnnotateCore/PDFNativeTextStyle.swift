import AppKit
import CoreGraphics
import CoreText
import PDFKit

public struct PDFNativeTextStyleResult {
    public let text: NSAttributedString
    /// User-visible notices for unavailable source faces. Empty means no substitution.
    public let fontSubstitutions: [String]
    public let requiresScannedEditing: Bool
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
        var substitutions: [String] = []
        let fallbackFont = fallback.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? NSFont.systemFont(ofSize: 14)
        var sourceUnits: [(scalar: Unicode.Scalar, font: NSFont, color: NSColor?)] = []
        var spaceStyles: [Int: (font: NSFont, color: NSColor?)] = [:]
        for glyph in glyphs {
            let key = "\(glyph.fontBaseName)|\(glyph.fontSize)"
            let font: NSFont
            if let cached = cache[key] { font = cached }
            else {
                do { font = try sourceFont(name: glyph.fontBaseName, size: glyph.fontSize) }
                catch let unavailable as UnavailableSourceFont {
                    font = (try? sourceFont(name: fallbackFont.fontName, size: glyph.fontSize)) ?? NSFont.systemFont(ofSize: glyph.fontSize)
                    let notice = "\(unavailable.name): font unavailable; using \(font.displayName ?? font.fontName)."
                    if !substitutions.contains(notice) { substitutions.append(notice) }
                }
                cache[key] = font
            }
            let sourceColor = glyph.fillColor.flatMap(NSColor.init(cgColor:))
            // OCR styling describes an invisible search layer, not the scan's ink.
            // New visible text must never inherit its zero-opacity appearance.
            let color = glyph.invisible ? (sourceColor ?? .black).withAlphaComponent(1) : sourceColor
            for scalar in glyph.glyph.text.decomposedStringWithCompatibilityMapping.unicodeScalars {
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { spaceStyles[sourceUnits.count] = (font, color) }
                else { sourceUnits.append((scalar, font, color)) }
            }
        }
        let characters = characterRanges(in: fallback.string)
        let fallbackUnits = characters.flatMap { normalized($0.text) }
        guard sourceUnits.map(\.scalar) == fallbackUnits, fallbackUnits == normalized(originalText), let first = sourceUnits.first else {
            throw PDFNativeTextError.sourceMismatch
        }
        let result = NSMutableAttributedString(attributedString: fallback)
        var cursor = 0, previous = (font: first.font, color: first.color)
        for character in characters {
            let units = normalized(character.text)
            let style: (font: NSFont, color: NSColor?)
            if units.isEmpty { style = spaceStyles[cursor] ?? previous }
            else {
                style = (sourceUnits[cursor].font, sourceUnits[cursor].color)
                // A Unicode character cluster cannot safely carry incompatible source faces.
                guard sourceUnits[cursor..<(cursor + units.count)].allSatisfy({ $0.font == style.font }) else {
                    throw PDFNativeTextError.unsupported("The selected character combines incompatible source font runs.")
                }
                cursor += units.count
                previous = style
            }
            result.addAttribute(.font, value: style.font, range: character.range)
            if let color = style.color { result.addAttribute(.foregroundColor, value: color, range: character.range) }
        }
        return PDFNativeTextStyleResult(text: NSAttributedString(attributedString: result), fontSubstitutions: substitutions,
            requiresScannedEditing: glyphs.contains(where: \.invisible))
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

    private struct UnavailableSourceFont: Error { let name: String }

    private static func unavailable(_ name: String) -> UnavailableSourceFont {
        UnavailableSourceFont(name: name)
    }
}
