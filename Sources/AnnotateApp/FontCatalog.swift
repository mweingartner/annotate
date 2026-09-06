import AppKit

/// Uses the same installed font families, faces and trait conversions as the macOS Font panel.
@MainActor
enum FontCatalog {
    static let families: [String] = [NSFont.systemFont(ofSize: 14).familyName ?? ".AppleSystemUIFont"] + NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    static func family(of font: NSFont) -> String { font.familyName ?? font.fontName }
    static func displayName(for family: String) -> String {
        [".AppleSystemUIFont", ".SF NS"].contains(family) ? "System Font" : family
    }

    static func faces(in family: String) -> [FontFace] {
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        return members.compactMap { member in
            guard member.count >= 4, let name = member[0] as? String, let title = member[1] as? String,
                  let weight = member[2] as? NSNumber, let traits = member[3] as? NSNumber,
                  NSFont(name: name, size: 12) != nil else { return nil }
            return FontFace(name: name, title: title, weight: weight.intValue, traits: NSFontTraitMask(rawValue: traits.uintValue))
        }.sorted {
            if $0.weight != $1.weight { return $0.weight < $1.weight }
            let a = $0.traits.contains(.italicFontMask), b = $1.traits.contains(.italicFontMask)
            if a != b { return !a }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    static func font(in family: String, matching original: NSFont) -> NSFont? {
        let manager = NSFontManager.shared
        let traits = manager.traits(of: original).intersection([.boldFontMask, .italicFontMask])
        if let exact = manager.font(withFamily: family, traits: traits, weight: manager.weight(of: original), size: original.pointSize) {
            return exact
        }
        if let regular = manager.font(withFamily: family, traits: [], weight: 5, size: original.pointSize) { return regular }
        return faces(in: family).first.flatMap { NSFont(name: $0.name, size: original.pointSize) }
    }

    static func hasTrait(_ trait: NSFontTraitMask, font: NSFont) -> Bool {
        NSFontManager.shared.traits(of: font).contains(trait)
    }

    static func toggling(_ trait: NSFontTraitMask, font: NSFont) -> NSFont? {
        let originalHasTrait = hasTrait(trait, font: font)
        let converted = originalHasTrait
            ? NSFontManager.shared.convert(font, toNotHaveTrait: trait)
            : NSFontManager.shared.convert(font, toHaveTrait: trait)
        guard hasTrait(trait, font: converted) != originalHasTrait else { return nil }
        return converted
    }
}
