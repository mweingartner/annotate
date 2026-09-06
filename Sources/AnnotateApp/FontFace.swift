import AppKit

struct FontFace: Identifiable {
    let name: String
    let title: String
    let weight: Int
    let traits: NSFontTraitMask
    var id: String { name }
}
