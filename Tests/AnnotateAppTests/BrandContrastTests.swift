import AppKit
import SwiftUI
import Testing
import Atrium
@testable import AnnotateApp

@Suite("Brand colour contrast", .serialized)
@MainActor
struct BrandContrastTests {
    @Test("Lagoon text on the welcome page is legible in standard and increased-contrast appearances", arguments: [
        NSAppearance.Name.aqua, .darkAqua,
        .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua
    ])
    func accentContrast(appearanceName: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: appearanceName))
        appearance.performAsCurrentDrawingAppearance {
            let foreground = NSColor(Palette.accentText)
            #expect(contrast(foreground, .controlBackgroundColor) >= 4.5)
            #expect(contrast(foreground, .windowBackgroundColor) >= 4.5)
        }
    }

    @Test("The Lagoon button fill carries white labels", arguments: [NSAppearance.Name.aqua, .darkAqua])
    func actionContrast(appearanceName: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: appearanceName))
        appearance.performAsCurrentDrawingAppearance {
            #expect(contrast(.white, NSColor(Palette.accent)) >= 4.5)
        }
    }

    private func contrast(_ first: NSColor, _ second: NSColor) -> Double {
        let firstLuminance = luminance(first)
        let secondLuminance = luminance(second)
        return (max(firstLuminance, secondLuminance) + 0.05) / (min(firstLuminance, secondLuminance) + 0.05)
    }

    private func luminance(_ color: NSColor) -> Double {
        guard let rgb = color.usingColorSpace(.sRGB) else { return .nan }
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }
}
