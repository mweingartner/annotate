import AppKit
import CoreText
import PDFKit
import Testing
@testable import AnnotateCore

@Suite("Source PDF typography", .serialized)
@MainActor
struct NativeTextStyleTests {
    @Test("Sample headings retain their actual semibold system face and size")
    func sampleHeading() throws {
        let document = SamplePDF.make()
        let text = "A better way to return"
        let selection = try #require(document.findString(text, withOptions: []).first)
        let page = try #require(selection.pages.first)
        let fallback = try #require(selection.attributedString)
        let style = try PDFNativeTextStyle.attributedText(in: document, region: PageRegion(pageIndex: document.index(for: page), bounds: selection.bounds(for: page)), originalText: text, fallback: fallback)
        let result = style.text
        #expect(style.fontSubstitutions.isEmpty)
        let actual = try #require(result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let expected = NSFont.systemFont(ofSize: 14, weight: .semibold)
        #expect(actual.fontName == expected.fontName)
        #expect(abs(actual.pointSize - 14) < 0.001)
        #expect(NSFontManager.shared.weight(of: actual) == NSFontManager.shared.weight(of: expected))
        #expect(result.string == text)
    }

    @Test("Mixed source fonts and colors overwrite PDFKit fallbacks while paragraph styles remain intact")
    func mixedSourceRuns() throws {
        let strong = try #require(NSFont(name: "Helvetica-Bold", size: 18))
        let italic = try #require(NSFont(name: "Times-Italic", size: 23))
        let original = NSMutableAttributedString(string: "Strong ", attributes: [.font: strong, .foregroundColor: NSColor.magenta])
        original.append(NSAttributedString(string: "italic", attributes: [.font: italic, .foregroundColor: NSColor.blue]))
        let document = try rendered(original)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 6; paragraph.headIndent = 8
        let fallback = NSMutableAttributedString(string: original.string, attributes: [.font: NSFont.systemFont(ofSize: 5),
            .foregroundColor: NSColor.yellow, .paragraphStyle: paragraph])
        let result = try PDFNativeTextStyle.attributedText(in: document, region: region, originalText: original.string, fallback: fallback).text
        let first = try #require(result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let last = try #require(result.attribute(.font, at: 7, effectiveRange: nil) as? NSFont)
        #expect(first.fontName == strong.fontName && first.pointSize == 18)
        #expect(last.fontName == italic.fontName && last.pointSize == 23)
        let firstColor = try #require((result.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.deviceRGB))
        let secondColor = try #require((result.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor)?.usingColorSpace(.deviceRGB))
        #expect(firstColor.redComponent > 0.99 && firstColor.blueComponent > 0.99 && firstColor.greenComponent < 0.01)
        #expect(secondColor.blueComponent > 0.99 && secondColor.redComponent < 0.01 && secondColor.greenComponent < 0.01)
        #expect((result.attribute(.paragraphStyle, at: 7, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing == 6)
        #expect((result.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.headIndent == 8)
    }

    @Test("Effective sizes include page-space transforms")
    func effectiveFontSize() throws {
        let original = NSAttributedString(string: "Scaled", attributes: [.font: try #require(NSFont(name: "Helvetica", size: 12))])
        let document = try rendered(original, scale: 1.5)
        let result = try PDFNativeTextStyle.attributedText(in: document, region: PageRegion(pageIndex: 0, bounds: CGRect(x: 60, y: 330, width: 430, height: 90)), originalText: original.string, fallback: original).text
        #expect((result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 18)
    }

    @Test("Canonical accents, ligatures and PDF-inferred whitespace keep their character ranges")
    func normalizedCharacters() throws {
        let font = try #require(NSFont(name: "Helvetica", size: 16))
        let original = NSAttributedString(string: "Café ﬁle", attributes: [.font: font])
        let document = try rendered(original)
        let fallback = NSAttributedString(string: " Cafe\u{301} file\n", attributes: [.font: NSFont.systemFont(ofSize: 6)])
        let result = try PDFNativeTextStyle.attributedText(in: document, region: region, originalText: "Café file", fallback: fallback).text
        #expect(result.string == fallback.string)
        result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length)) { value, _, _ in
            #expect((value as? NSFont)?.fontName == font.fontName)
            #expect((value as? NSFont)?.pointSize == 16)
        }
    }

    @Test("Unavailable source faces report their installed substitute and retain the actual size")
    func unavailableFont() throws {
        let document = try unavailableDocument()
        let fallbackFont = try #require(NSFont(name: "Helvetica", size: 7))
        let result = try PDFNativeTextStyle.attributedText(in: document, region: region, originalText: "Missing",
            fallback: NSAttributedString(string: "Missing", attributes: [.font: fallbackFont]))
        #expect(result.fontSubstitutions.count == 1)
        #expect(result.fontSubstitutions.first?.contains("AnnotateNonexistentFace") == true)
        #expect(result.fontSubstitutions.first?.contains("Helvetica") == true)
        #expect((result.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 18)
    }

    @Test("Mismatched fallback text fails without changing the document")
    func mismatchPreservesSource() throws {
        let original = NSAttributedString(string: "Source", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let document = try rendered(original), page = try #require(document.page(at: 0))
        #expect(throws: PDFNativeTextError.self) {
            try PDFNativeTextStyle.attributedText(in: document, region: region, originalText: "Source", fallback: NSAttributedString(string: "Different"))
        }
        #expect(document.page(at: 0) === page)
        #expect(document.string?.contains("Source") == true)
    }

    private var region: PageRegion { PageRegion(pageIndex: 0, bounds: CGRect(x: 40, y: 215, width: 400, height: 80)) }

    private func rendered(_ text: NSAttributedString, scale: Double = 1) throws -> PDFDocument {
        let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.scaleBy(x: scale, y: scale)
        context.textPosition = CGPoint(x: 50, y: 250)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage(); context.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }

    private func unavailableDocument() throws -> PDFDocument {
        let stream = "BT /F1 18 Tf 1 0 0 1 50 250 Tm (Missing) Tj ET"
        let widths = Array(repeating: "600", count: 256).joined(separator: " ")
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /AnnotateNonexistentFace /FirstChar 0 /LastChar 255 /Widths [\(widths)] /Encoding /WinAnsiEncoding >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try #require(PDFDocument(data: data))
    }
}
