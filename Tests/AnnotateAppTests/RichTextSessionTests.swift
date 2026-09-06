import AnnotateCore
import AppKit
import Testing
@testable import AnnotateApp

@Suite("Rich text editing session", .serialized)
@MainActor
struct RichTextSessionTests {
    private func session(_ text: NSAttributedString) -> LiveTextEdit {
        LiveTextEdit(identifier: "test", pageIndex: 0, text: text.string, font: .systemFont(ofSize: 14), color: .black,
                     bounds: CGRect(x: 50, y: 500, width: 300, height: 80), pageBounds: CGRect(x: 0, y: 0, width: 612, height: 792),
                     attributedText: text, isExistingContent: true)
    }

    @Test("Style controls affect only selected characters and retain other rich runs")
    func selectedFormatting() throws {
        let originalFont = try #require(NSFont(name: "Helvetica", size: 14))
        let original = NSAttributedString(string: "First second", attributes: [.font: originalFont, .foregroundColor: NSColor.black])
        let edit = session(original)
        edit.updateSelection(NSRange(location: 0, length: 5))
        edit.fontName = "Times-Italic"
        edit.fontSize = 25
        edit.color = .blue
        edit.isUnderlined = true
        let selected = try #require(edit.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let retained = try #require(edit.attributedText.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)
        #expect(selected.fontName == "Times-Italic")
        #expect(selected.pointSize == 25)
        #expect(retained == originalFont)
        #expect(edit.attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .blue)
        #expect(edit.attributedText.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor == .black)
        #expect(edit.attributedText.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(edit.attributedText.attribute(.underlineStyle, at: 6, effectiveRange: nil) == nil)
        #expect(edit.text == original.string)
    }

    @Test("Selection changes synchronize controls without reporting a document edit")
    func selectionSynchronization() throws {
        let original = NSMutableAttributedString(string: "One two", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        original.addAttributes([.font: try #require(NSFont(name: "Times-Bold", size: 21)), .foregroundColor: NSColor.red, .underlineStyle: NSUnderlineStyle.single.rawValue], range: NSRange(location: 4, length: 3))
        let edit = session(original)
        var edits = 0, selections = 0
        edit.changed = { edits += 1 }
        edit.selectionChanged = { selections += 1 }
        edit.updateSelection(NSRange(location: 4, length: 3))
        #expect(edit.fontName == "Times-Bold")
        #expect(edit.fontSize == 21)
        #expect(edit.color == .red)
        #expect(edit.isUnderlined)
        #expect(edits == 0)
        #expect(selections == 1)
        edit.updateSelection(NSRange(location: 0, length: 3))
        #expect(edit.fontSize == 14)
        #expect(edit.color == .black)
        #expect(!edit.isUnderlined)
        #expect(edits == 0)
    }

    @Test("Paragraph alignment applies to whole touched paragraphs and preserves line spacing")
    func paragraphAlignment() throws {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        let edit = session(NSAttributedString(string: "First paragraph\nSecond paragraph", attributes: [.font: NSFont.systemFont(ofSize: 14), .paragraphStyle: paragraph]))
        edit.updateSelection(NSRange(location: 2, length: 3))
        edit.alignment = .center
        let first = try #require(edit.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let second = try #require(edit.attributedText.attribute(.paragraphStyle, at: 17, effectiveRange: nil) as? NSParagraphStyle)
        #expect(first.alignment == .center)
        #expect(first.lineSpacing == 7)
        #expect(second.alignment == .natural)
        #expect(second.lineSpacing == 7)
        let typing = try #require(edit.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
        #expect(typing.alignment == .center)
        #expect(typing.lineSpacing == 7)
    }

    @Test("Caret formatting affects the whole block and empty text retains a typing style")
    func wholeBlockAndEmpty() throws {
        let edit = session(NSAttributedString(string: "Whole block", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        edit.updateSelection(NSRange(location: 3, length: 0))
        edit.fontSize = 22
        #expect((edit.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 22)
        #expect((edit.attributedText.attribute(.font, at: 8, effectiveRange: nil) as? NSFont)?.pointSize == 22)
        edit.text = ""
        edit.fontName = "Times-Bold"
        edit.color = .blue
        edit.isUnderlined = true
        edit.text = "New"
        #expect(edit.fontName == "Times-Bold")
        #expect(edit.color == .blue)
        #expect(edit.isUnderlined)
    }

    @Test("Invalid numeric input retains valid layout, and fitting text preserves the top edge")
    func layoutValidity() throws {
        let edit = session(NSAttributedString(string: String(repeating: "Long text ", count: 35), attributes: [.font: NSFont.systemFont(ofSize: 24)]))
        #expect(edit.textOverflows)
        let oldTop = edit.appliedBounds.maxY
        let oldBounds = edit.appliedBounds
        edit.width = -2
        #expect(!edit.geometryIsValid)
        #expect(edit.appliedBounds == oldBounds)
        edit.width = oldBounds.width
        edit.fontSize = .nan
        #expect(!edit.fontSizeIsValid)
        #expect(edit.font.pointSize == 24)
        edit.fontSize = 24
        #expect(edit.fitHeightToText())
        #expect(edit.appliedBounds.maxY == oldTop)
        #expect(!edit.textOverflows)
    }

    @Test("Legacy text changes preserve unchanged styled suffixes and Unicode boundaries")
    func plainTextCompatibility() throws {
        let original = NSMutableAttributedString(string: "Hello 🌿 world", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let suffix = (original.string as NSString).range(of: "world")
        original.addAttribute(.foregroundColor, value: NSColor.red, range: suffix)
        let edit = session(original)
        edit.text = "Hello 🌿 bright world"
        let newSuffix = (edit.text as NSString).range(of: "world")
        #expect(edit.attributedText.attribute(.foregroundColor, at: newSuffix.location, effectiveRange: nil) as? NSColor == .red)
        #expect(edit.text == "Hello 🌿 bright world")
    }
}
