import AppKit
import SwiftUI
import Testing
@testable import AnnotateApp

@Suite("Reader contrast", .serialized)
@MainActor
struct ReaderStyleTests {
    @Test("Accent text is legible in standard and increased-contrast appearances", arguments: [
        NSAppearance.Name.aqua, .darkAqua,
        .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua
    ])
    func accentContrast(appearanceName: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: appearanceName))
        appearance.performAsCurrentDrawingAppearance {
            let foreground = NSColor(ReaderStyle.accent)
            #expect(contrast(foreground, .controlBackgroundColor) >= 4.5)
            #expect(contrast(foreground, .windowBackgroundColor) >= 4.5)
        }
    }

    @Test("Primary action fill supports white labels with strong contrast")
    func actionContrast() {
        #expect(contrast(.white, NSColor(ReaderStyle.actionFill)) >= 7)
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
