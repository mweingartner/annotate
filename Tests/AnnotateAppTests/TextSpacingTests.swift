import AnnotateCore
import AppKit
import PDFKit
import Testing
@testable import AnnotateApp

@Suite("Native rich text spacing", .serialized)
@MainActor
struct TextSpacingTests {
    private func session() -> LiveTextEdit {
        LiveTextEdit(identifier: "spacing", pageIndex: 0, text: "AB CD\nSecond paragraph", font: .systemFont(ofSize: 14),
            color: .black, bounds: CGRect(x: 50, y: 100, width: 350, height: 150))
    }

    @Test("Character spacing changes selected runs and paragraph spacing keeps other paragraphs intact")
    func selectionAndZoom() throws {
        let edit = session()
        edit.updateSelection(NSRange(location: 0, length: 2))
        edit.letterSpacing = 2
        edit.lineSpacing = 6
        edit.paragraphSpacing = 10
        #expect(edit.attributedText.attribute(.kern, at: 0, effectiveRange: nil) as? Double == 2)
        #expect(edit.attributedText.attribute(.kern, at: 3, effectiveRange: nil) == nil)
        let paragraph = try #require(edit.attributedText.attribute(.paragraphStyle, at: 3, effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.lineSpacing == 6)
        #expect(paragraph.paragraphSpacing == 10)
        #expect(edit.attributedText.attribute(.paragraphStyle, at: 6, effectiveRange: nil) == nil)
        let zoomed = LiveTextLayout.scaled(edit.attributedText, by: 2.5)
        #expect(zoomed.attribute(.kern, at: 0, effectiveRange: nil) as? Double == 5)
        let restored = LiveTextLayout.scaled(zoomed, by: 0.4)
        #expect(restored.isEqual(to: edit.attributedText))
        edit.updateSelection(NSRange(location: 6, length: 6))
        #expect(edit.letterSpacing == 0)
        #expect(edit.lineSpacing == 0)
        #expect(edit.paragraphSpacing == 0)
    }

    @Test("Spacing changes are written into the native PDF glyph positions")
    func savedGeometry() throws {
        let source = SamplePDF.make()
        let plain = session(), spaced = session()
        spaced.updateSelection(NSRange(location: 0, length: 2))
        spaced.letterSpacing = 2
        spaced.paragraphSpacing = 10
        let region = PageRegion(pageIndex: 0, bounds: plain.bounds)
        func output(_ edit: LiveTextEdit) throws -> PDFDocument {
            let result = try PDFNativeTextEditor.replace(in: source, region: region, originalText: "", replacement: edit.attributedText)
            let data = try #require(result.dataRepresentation())
            return try #require(PDFDocument(data: data))
        }
        let a = try output(plain), b = try output(spaced)
        func bounds(_ text: String, in pdf: PDFDocument) throws -> CGRect {
            let found = try #require(pdf.findString(text, withOptions: []).last)
            return found.bounds(for: try #require(pdf.page(at: 0)))
        }
        // The unformatted CD run shifts right after the expanded AB run; the
        // following paragraph moves down by the requested paragraph spacing.
        #expect(try bounds("CD", in: b).minX > bounds("CD", in: a).minX + 2)
        #expect(try abs(bounds("Second paragraph", in: b).minY - bounds("Second paragraph", in: a).minY + 10) < 0.2)
        #expect(b.page(at: 0)?.annotations.isEmpty == true)
    }
}
