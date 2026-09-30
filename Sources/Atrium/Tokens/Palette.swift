import AppKit
import SwiftUI

/// An sRGB colour value with the WCAG maths Atrium uses to prove its contrast claims.
public struct RGB: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    /// Creates a colour from a 24-bit hex value such as `0x0B6E82`.
    public init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    /// Creates a colour from sRGB components. Components are clamped to 0...1, so
    /// contrast ratios always stay within WCAG's 1...21 range.
    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// WCAG 2 relative luminance.
    public var luminance: Double {
        func channel(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG 2 contrast ratio between two colours, from 1 to 21.
    public func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    public static let white = RGB(hex: 0xFFFFFF)
}

/// Atrium's colour. Neutrals come from the system so windows, sidebars and text follow
/// the user's appearance, Increase Contrast and wallpaper tinting (HIG › Color).
///
/// The accent follows the user. System controls, selection and sidebar icons draw in
/// the macOS accent colour the person picked. **Lagoon**, a deep teal, is the app's own
/// colour: set it as the app's `AccentColor` asset, so it appears when the person
/// chooses Multicolor, and use it for brand moments (icon, onboarding). Don't `.tint()`
/// whole windows with it: `List` selection ignores `.tint`, and the window ends up
/// with two accents.
///
/// Lagoon comes in two roles, because no single dark-mode teal can carry white label
/// text *and* read as text on a dark window:
/// - ``accent`` is for fills. White labels sit on it.
/// - ``accentText`` is for teal text, links and symbols drawn on the window background.
public enum Palette {
    /// Lagoon fill in light appearance. White on it: 5.9:1.
    public static let lagoonLight = RGB(hex: 0x0B6E82)
    /// Lagoon fill in dark appearance. White on it: 4.7:1.
    public static let lagoonDark = RGB(hex: 0x157F91)
    /// Lagoon for text and symbols on the dark window background.
    public static let lagoonTextDark = RGB(hex: 0x5CC6D9)

    /// Lagoon as a fill. This is the value of the app's `AccentColor` asset.
    public static let accent = Color(nsColor: dynamic(light: lagoonLight, dark: lagoonDark, name: "AtriumAccent"))

    /// Accent for text, links and symbols drawn directly on a background.
    public static let accentText = Color(nsColor: dynamic(light: lagoonLight, dark: lagoonTextDark, name: "AtriumAccentText"))

    /// The hairline Atrium uses instead of boxes. System separator, so it tracks
    /// Increase Contrast.
    public static let hairline = Color(nsColor: .separatorColor)

    /// Hover wash for quiet controls and rows.
    public static let hover = Color.primary.opacity(0.06)
    /// Pressed wash for quiet controls and rows.
    public static let pressed = Color.primary.opacity(0.11)

    /// Status colours. System colours, so they adapt per appearance and contrast
    /// setting; always pair them with a symbol or word, never colour alone.
    public enum Status {
        public static let positive = Color(nsColor: .systemGreen)
        public static let caution = Color(nsColor: .systemOrange)
        public static let critical = Color(nsColor: .systemRed)
        public static let info = Color(nsColor: .systemBlue)
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func dynamic(light: RGB, dark: RGB, name: String) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            isDark(appearance) ? dark.nsColor : light.nsColor
        }
    }
}
