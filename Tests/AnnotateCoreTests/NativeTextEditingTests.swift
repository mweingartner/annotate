import AppKit
import CoreGraphics
import PDFKit
import Testing
@testable import AnnotateCore

@Suite("Genuine native PDF text editing", .serialized)
@MainActor
struct NativeTextEditingTests {
    @Test("TJ replacement removes original glyphs and preserves adjacent text positions, vectors, and annotations")
    func kernedSourceRoundTrip() throws {
        let source = try rawDocument()
        let page = try #require(source.page(at: 0))
        _ = Fixtures.foreignAnnotation(on: page)
        let selected = try #require(source.findString("TARGET", withOptions: []).first)
        let after = try #require(source.findString("after", withOptions: []).first).bounds(for: page)
        let region = PageRegion(pageIndex: 0, bounds: selected.bounds(for: page).insetBy(dx: 0, dy: -3))
        let output = try PDFNativeTextEditor.replace(in: source, region: region, originalText: "TARGET", replacement: styled("Edited"))
        let saved = try Fixtures.reopen(output)
        let newPage = try #require(saved.page(at: 0))
        #expect(saved.findString("TARGET", withOptions: []).isEmpty)
        #expect(saved.findString("Edited", withOptions: []).count == 1)
        #expect(saved.findString("Before", withOptions: []).count == 1)
        #expect(saved.findString("Sentinel", withOptions: []).count == 1)
        #expect(newPage.annotations.count == 1)
        let newAfter = try #require(saved.findString("after", withOptions: []).first).bounds(for: newPage)
        #expect(abs(after.minX - newAfter.minX) < 0.02)
        #expect(abs(after.minY - newAfter.minY) < 0.02)
        let bytes = try #require(output.dataRepresentation())
        #expect(!String(decoding: bytes, as: UTF8.self).contains("TARGET"))
        #expect(try pageStreams(saved).contains("25 25 30 30 re f"))
        #expect(try !pageStreams(saved).contains("/Subtype /Image"))
        #expect(source.findString("TARGET", withOptions: []).count == 1)
    }

    @Test("Compressed subset-font text edits remain searchable through repeated save and reopen")
    func subsetAndRepeatedEdit() throws {
        let source = SamplePDF.make()
        let selection = try #require(source.findString("attention", withOptions: []).first)
        let page = try #require(selection.pages.first)
        let index = source.index(for: page)
        let sourceData = try #require(source.dataRepresentation())
        let provider = try #require(CGDataProvider(data: sourceData as CFData)), cg = try #require(CGPDFDocument(provider))
        let dictionary = try #require(cg.page(at: index + 1)?.dictionary)
        let stream = try #require(nativeStream(dictionary, "Contents")), streamDictionary = try #require(CGPDFStreamGetDictionary(stream))
        #expect(nativeName(streamDictionary, "Filter") == "FlateDecode")
        let resources = try #require(nativeDictionary(dictionary, "Resources"))
        let fonts = try #require(nativeDictionary(resources, "Font"))
        var mappedSubset = false
        CGPDFDictionaryApplyBlock(fonts, { _, value, _ in
            var font: CGPDFDictionaryRef?
            if CGPDFObjectGetValue(value, .dictionary, &font), let font,
               nativeName(font, "BaseFont")?.contains("+") == true, nativeStream(font, "ToUnicode") != nil { mappedSubset = true }
            return true
        }, nil)
        #expect(mappedSubset)
        let region = PageRegion(pageIndex: index, bounds: selection.bounds(for: page).insetBy(dx: 0, dy: -5))
        let before = source.string ?? ""
        let output = try PDFNativeTextEditor.replace(in: source, region: region, originalText: "attention", replacement: styled("FOCUS", font: NSFont(name: "Times-Bold", size: 11)!))
        #expect(output.findString("FOCUS", withOptions: []).count == 1)
        #expect((output.string ?? "").count > before.count - 30)
        let reopened = try Fixtures.reopen(output)
        let focus = try #require(reopened.findString("FOCUS", withOptions: []).first)
        let targetPage = try #require(reopened.page(at: index))
        let next = try PDFNativeTextEditor.replace(in: reopened, region: PageRegion(pageIndex: index, bounds: focus.bounds(for: targetPage).insetBy(dx: 0, dy: -5)), originalText: "FOCUS", replacement: styled("CLEAR", font: NSFont(name: "Courier", size: 9)!))
        #expect(next.findString("CLEAR", withOptions: []).count == 1)
        #expect(next.findString("FOCUS", withOptions: []).isEmpty)
        let native = try #require(next.findString("CLEAR", withOptions: []).first?.attributedString)
        let font = native.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.fontName.contains("Courier") == true)
        #expect(abs((font?.pointSize ?? 0) - 9) < 0.1)
    }

    @Test("Original attributed text fits its exact PDFKit selection rectangle")
    func unchangedSelectionFits() throws {
        let source = SamplePDF.make(), selection = try #require(source.findString("attention", withOptions: []).first)
        let page = try #require(selection.pages.first), text = try #require(selection.attributedString)
        let result = try PDFNativeTextEditor.replace(in: source, region: PageRegion(pageIndex: source.index(for: page), bounds: selection.bounds(for: page)), originalText: selection.string ?? "attention", replacement: text)
        #expect(result.findString("attention", withOptions: []).count == source.findString("attention", withOptions: []).count)
    }

    @Test("Crop origin and page rotation remain unchanged", arguments: [0, 90, 180, 270])
    func rotatedCropped(rotation: Int) throws {
        let source = try Fixtures.geometryDocument(rotation: rotation, crop: CGRect(x: 50, y: 80, width: 300, height: 350))
        let page = try #require(source.page(at: 0))
        let selected = try #require(source.findString("Rotation", withOptions: []).first)
        let output = try PDFNativeTextEditor.replace(in: source, region: PageRegion(pageIndex: 0, bounds: selected.bounds(for: page).insetBy(dx: 0, dy: -4)), originalText: "Rotation", replacement: styled("Updated", font: NSFont.systemFont(ofSize: 10)))
        let result = try #require(output.page(at: 0))
        #expect(result.rotation == rotation)
        #expect(result.bounds(for: .cropBox) == page.bounds(for: .cropBox))
        #expect(output.findString("Rotation", withOptions: []).isEmpty)
        #expect(output.findString("sentinel", withOptions: []).count == 1)
        #expect(output.findString("Updated", withOptions: []).count == 1)
    }

    @Test("Deletion and native insertion need no covering annotation")
    func deletionAndAddition() throws {
        let source = try rawDocument()
        let page = try #require(source.page(at: 0)), selection = try #require(source.findString("TARGET", withOptions: []).first)
        let region = PageRegion(pageIndex: 0, bounds: selection.bounds(for: page).insetBy(dx: 0, dy: -3))
        let deleted = try PDFNativeTextEditor.replace(in: source, region: region, originalText: "TARGET", replacement: NSAttributedString(string: ""))
        #expect(deleted.findString("TARGET", withOptions: []).isEmpty)
        let added = try PDFNativeTextEditor.replace(in: deleted, region: PageRegion(pageIndex: 0, bounds: CGRect(x: 50, y: 150, width: 220, height: 50)), originalText: "", replacement: styled("Native insertion"))
        #expect(added.findString("Native insertion", withOptions: []).count == 1)
        #expect(added.page(at: 0)?.annotations.isEmpty == true)
    }

    @Test("A shared form is copied only for the edited invocation")
    func sharedFormIsolation() throws {
        let source = try rawDocument(sharedForm: true), page = try #require(source.page(at: 0))
        let matches = source.findString("TARGET", withOptions: [])
        #expect(matches.count == 2)
        let top = try #require(matches.max { $0.bounds(for: page).minY < $1.bounds(for: page).minY })
        let bottom = try #require(matches.min { $0.bounds(for: page).minY < $1.bounds(for: page).minY }).bounds(for: page)
        let result = try PDFNativeTextEditor.replace(in: source, region: PageRegion(pageIndex: 0, bounds: top.bounds(for: page).insetBy(dx: 0, dy: -3)), originalText: "TARGET", replacement: styled("Edited"))
        #expect(result.findString("TARGET", withOptions: []).count == 1)
        #expect(result.findString("Edited", withOptions: []).count == 1)
        let remaining = try #require(result.findString("TARGET", withOptions: []).first)
        let bounds = remaining.bounds(for: try #require(result.page(at: 0)))
        #expect(abs(bounds.minY - bottom.minY) < 0.02)
    }

    @Test("Movement uses the original glyph location and places rich replacement at its destination")
    func distinctDestination() throws {
        let source = try rawDocument(), page = try #require(source.page(at: 0)), selected = try #require(source.findString("TARGET", withOptions: []).first)
        let rich = NSMutableAttributedString(attributedString: styled("Mixed ", font: NSFont(name: "Times-Bold", size: 16)!))
        rich.append(styled("styles", font: NSFont(name: "Courier-Oblique", size: 12)!))
        let result = try PDFNativeTextEditor.replace(in: source, region: PageRegion(pageIndex: 0, bounds: selected.bounds(for: page)), originalText: "TARGET", replacement: rich, destination: PageRegion(pageIndex: 0, bounds: CGRect(x: 75, y: 150, width: 200, height: 40)))
        #expect(result.findString("TARGET", withOptions: []).isEmpty)
        let placed = try #require(result.findString("Mixed styles", withOptions: []).first)
        let bounds = placed.bounds(for: try #require(result.page(at: 0)))
        #expect(bounds.minX >= 74.9 && bounds.maxY <= 190.1 && bounds.minY >= 149.9)
        let text = try #require(placed.attributedString)
        let firstFont = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let secondFont = text.attribute(.font, at: 6, effectiveRange: nil) as? NSFont
        #expect(firstFont?.fontName.contains("Times") == true)
        #expect(secondFont?.fontName.contains("Courier") == true)
        #expect(firstFont?.pointSize == 16)
        #expect(secondFont?.pointSize == 12)
    }

    @Test("Replacement preserves the original paint order beneath overlapping vector artwork")
    func overlappingArtwork() throws {
        let source = try rawDocument(content: "BT /F1 18 Tf 1 0 0 1 50 350 Tm (TARGET) Tj ET q 0 0 1 rg 50 348 180 12 re f Q")
        let page = try #require(source.page(at: 0)), selected = try #require(source.findString("TARGET", withOptions: []).first)
        let result = try PDFNativeTextEditor.replace(in: source, region: PageRegion(pageIndex: 0, bounds: selected.bounds(for: page).insetBy(dx: 0, dy: -4)), originalText: "TARGET", replacement: styled("Edited", font: NSFont.systemFont(ofSize: 18)))
        let rendered = NSBitmapImageRep(cgImage: try PDFConversion.renderedImage(page: #require(result.page(at: 0)), scale: 1))
        for x in 52..<115 {
            for y in 142..<150 {
                let color = try #require(rendered.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                #expect(color.blueComponent > 0.99 && color.redComponent < 0.01 && color.greenComponent < 0.01)
            }
        }
        #expect(result.findString("TARGET", withOptions: []).isEmpty)
        #expect(result.findString("Edited", withOptions: []).count == 1)
    }

    @Test("Invisible OCR text cannot masquerade as visible source editing")
    func invisibleTextRejected() throws {
        let source = try rawDocument(content: "BT /F1 18 Tf 3 Tr 1 0 0 1 50 350 Tm (TARGET) Tj ET")
        let page = try #require(source.page(at: 0)), selected = try #require(source.findString("TARGET", withOptions: []).first)
        #expect(throws: PDFNativeTextError.self) {
            try PDFNativeTextEditor.replace(in: source, region: PageRegion(pageIndex: 0, bounds: selected.bounds(for: page).insetBy(dx: 0, dy: -3)), originalText: "TARGET", replacement: styled("Edited"))
        }
        #expect(source.findString("TARGET", withOptions: []).count == 1)
    }

    @Test("Ambiguous selection and overflow fail without mutating the source")
    func transactionalFailures() throws {
        let source = try rawDocument(), originalPage = try #require(source.page(at: 0))
        let originalText = source.string
        let region = PageRegion(pageIndex: 0, bounds: CGRect(x: 50, y: 340, width: 220, height: 30))
        #expect(throws: PDFNativeTextError.self) { try PDFNativeTextEditor.replace(in: source, region: region, originalText: "missing", replacement: styled("New")) }
        #expect(throws: PDFNativeTextError.self) { try PDFNativeTextEditor.replace(in: source, region: PageRegion(pageIndex: 0, bounds: CGRect(x: 50, y: 150, width: 10, height: 10)), originalText: "", replacement: styled("This cannot fit")) }
        #expect(source.page(at: 0) === originalPage)
        #expect(source.string == originalText)
        #expect(source.findString("TARGET", withOptions: []).count == 1)
    }

    private func styled(_ text: String, font: NSFont = NSFont.systemFont(ofSize: 12)) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.systemGreen])
    }

    private func rawDocument(sharedForm: Bool = false, content: String? = nil) throws -> PDFDocument {
        let stream = content ?? "q 0 0 1 rg 25 25 30 30 re f Q\nBT /F1 18 Tf 1 0 0 1 50 350 Tm (Before ) Tj [(TARGET) -120 ( after)] TJ ET\nBT /F1 14 Tf 1 0 0 1 50 280 Tm (Sentinel text remains) Tj ET"
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>", "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"]
        if sharedForm {
            let calls = "q /Shared Do Q q 1 0 0 1 0 -140 cm /Shared Do Q"
            objects[2] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /Resources << /XObject << /Shared 6 0 R >> >> /Contents 5 0 R >>"
            objects[4] = "<< /Length \(calls.utf8.count) >>\nstream\n\(calls)\nendstream"
            objects.append("<< /Type /XObject /Subtype /Form /BBox [0 0 400 500] /Resources << /Font << /F1 4 0 R >> >> /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
        }
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try #require(PDFDocument(data: data))
    }

    private func pageStreams(_ document: PDFDocument) throws -> String {
        let bytes = try #require(document.dataRepresentation()), provider = try #require(CGDataProvider(data: bytes as CFData)), cg = try #require(CGPDFDocument(provider)), page = try #require(cg.page(at: 1)), dictionary = try #require(page.dictionary)
        var result = Data()
        if let stream = nativeStream(dictionary, "Contents") { result.append(try nativeDecodedStream(stream)) }
        if let array = nativeArray(dictionary, "Contents") { for index in 0..<CGPDFArrayGetCount(array) { var stream: CGPDFStreamRef?; if CGPDFArrayGetStream(array, index, &stream), let stream { result.append(try nativeDecodedStream(stream)) } } }
        return String(decoding: result, as: UTF8.self)
    }
}
