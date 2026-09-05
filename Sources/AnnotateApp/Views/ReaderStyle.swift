import SwiftUI

enum ReaderStyle {
    // Teal remains a reading aid; the annotation's chosen color never styles controls.
    // Use dark ink in light appearance and light ink in dark appearance.
    static let accent = Color(nsColor: NSColor(name: "AnnotateAccent") { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark
            ? NSColor(srgbRed: 0.40, green: 0.84, blue: 0.81, alpha: 1)
            : NSColor(srgbRed: 0, green: 0.37, blue: 0.36, alpha: 1)
    })
    // White labels retain more than 7:1 contrast against this opaque action fill.
    static let actionFill = Color(red: 0, green: 0.34, blue: 0.33)

    static func outline(selected: Bool = false, contrast: ColorSchemeContrast) -> Color {
        if contrast == .increased { return selected ? .primary : .secondary }
        return selected ? accent : .primary.opacity(0.16)
    }

    static let spacing: CGFloat = 16
    static let compactSpacing: CGFloat = 8
    static let panelPadding: CGFloat = 18
    static let radius: CGFloat = 12
    static let panelMinimum: CGFloat = 260
    static let panelIdeal: CGFloat = 296
    static let panelMaximum: CGFloat = 380
}
