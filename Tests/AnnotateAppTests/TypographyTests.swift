import AppKit
import Testing
@testable import AnnotateApp

@Suite("Installed PDF typography", .serialized)
@MainActor
struct TypographyTests {
    @Test("The family catalog includes installed system families and actual font faces")
    func installedFamilies() throws {
        #expect(!FontCatalog.families.isEmpty)
        #expect(FontCatalog.families.contains("Helvetica"))
        let faces = FontCatalog.faces(in: "Helvetica")
        #expect(!faces.isEmpty)
        #expect(faces.allSatisfy { NSFont(name: $0.name, size: 17) != nil })
        #expect(Set(faces.map(\.id)).count == faces.count)
    }

    @Test("Bold and italic choose real faces, preserve size, and toggle back")
    func traits() throws {
        let regular = try #require(NSFont(name: "Helvetica", size: 23))
        let bold = try #require(FontCatalog.toggling(.boldFontMask, font: regular))
        #expect(FontCatalog.hasTrait(.boldFontMask, font: bold))
        #expect(bold.pointSize == 23)
        let boldItalic = try #require(FontCatalog.toggling(.italicFontMask, font: bold))
        #expect(FontCatalog.hasTrait(.boldFontMask, font: boldItalic))
        #expect(FontCatalog.hasTrait(.italicFontMask, font: boldItalic))
        let italic = try #require(FontCatalog.toggling(.boldFontMask, font: boldItalic))
        #expect(!FontCatalog.hasTrait(.boldFontMask, font: italic))
        #expect(FontCatalog.hasTrait(.italicFontMask, font: italic))
        let restored = try #require(FontCatalog.toggling(.italicFontMask, font: italic))
        #expect(!FontCatalog.hasTrait(.boldFontMask, font: restored))
        #expect(!FontCatalog.hasTrait(.italicFontMask, font: restored))
        #expect(restored.pointSize == 23)
    }

    @Test("Changing families keeps available weight and slant and never invents an unavailable font")
    func familyChange() throws {
        let source = try #require(NSFont(name: "Helvetica-BoldOblique", size: 19))
        let result = try #require(FontCatalog.font(in: "Times", matching: source))
        #expect(FontCatalog.family(of: result) == "Times")
        #expect(result.pointSize == 19)
        #expect(FontCatalog.hasTrait(.boldFontMask, font: result))
        #expect(FontCatalog.hasTrait(.italicFontMask, font: result))
        #expect(FontCatalog.font(in: "Not an installed font family 123", matching: source) == nil)
    }
    @Test("Changing a family preserves mixed sizes, weights, slants, colors, and unselected text")
    func richFamilyChange() throws {
        let body = NSMutableAttributedString(string: "Bold italic plain", attributes: [.font: try #require(NSFont(name: "Helvetica", size: 14)), .foregroundColor: NSColor.black])
        body.addAttribute(.font, value: try #require(NSFont(name: "Helvetica-Bold", size: 22)), range: NSRange(location: 0, length: 4))
        body.addAttribute(.font, value: try #require(NSFont(name: "Helvetica-Oblique", size: 17)), range: NSRange(location: 5, length: 6))
        body.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 5, length: 6))
        let changed = RichTextTypography.changingFamily("Times", in: body, selection: NSRange(location: 0, length: 11))
        let bold = try #require(changed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let italic = try #require(changed.attribute(.font, at: 5, effectiveRange: nil) as? NSFont)
        let untouched = try #require(changed.attribute(.font, at: 12, effectiveRange: nil) as? NSFont)
        #expect(FontCatalog.family(of: bold) == "Times")
        #expect(FontCatalog.hasTrait(.boldFontMask, font: bold))
        #expect(bold.pointSize == 22)
        #expect(FontCatalog.family(of: italic) == "Times")
        #expect(FontCatalog.hasTrait(.italicFontMask, font: italic))
        #expect(italic.pointSize == 17)
        #expect(changed.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor == .red)
        #expect(untouched.fontName == "Helvetica")
        #expect(untouched.pointSize == 14)
        #expect(changed.string == body.string)
    }

    @Test("A trait change affects selected runs without replacing their families or sizes")
    func richTraitChange() throws {
        let body = NSMutableAttributedString(string: "One two", attributes: [.font: try #require(NSFont(name: "Helvetica", size: 14))])
        body.addAttribute(.font, value: try #require(NSFont(name: "Times-Italic", size: 20)), range: NSRange(location: 4, length: 3))
        let changed = RichTextTypography.settingTrait(.boldFontMask, enabled: true, in: body, selection: NSRange(location: 0, length: 0))
        let first = try #require(changed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let second = try #require(changed.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
        #expect(first.fontName == "Helvetica-Bold")
        #expect(first.pointSize == 14)
        #expect(second.fontName == "Times-BoldItalic")
        #expect(second.pointSize == 20)
        #expect(body.attribute(.font, at: 0, effectiveRange: nil) as? NSFont != first)
    }

    @Test("Unavailable families, out-of-range selections and empty text do not discard content")
    func invalidRichChanges() throws {
        let original = NSAttributedString(string: "Keep this", attributes: [.font: NSFont.systemFont(ofSize: 16)])
        let unchanged = RichTextTypography.changingFamily("Unavailable family 123", in: original, selection: NSRange(location: 0, length: 0))
        #expect(unchanged.isEqual(to: original))
        let outside = RichTextTypography.settingTrait(.boldFontMask, enabled: true, in: original, selection: NSRange(location: NSNotFound, length: 30))
        #expect(outside.isEqual(to: original))
        let empty = RichTextTypography.settingTrait(.boldFontMask, enabled: true, in: NSAttributedString(string: ""), selection: NSRange(location: 0, length: 0))
        #expect(empty.length == 0)
    }

}
