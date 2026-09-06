import AppKit
import CoreGraphics
import CoreText
import PDFKit
import Testing
@testable import AnnotateCore

@Suite("Explicit source scan text editing", .serialized)
@MainActor
struct NativeScanEditingTests {
    @Test("Scanned pixels and OCR are removed together while neighboring pixels, text and annotations survive", arguments: [0, 90])
    func scanRoundTrip(rotation: Int) async throws {
        var source = try await fixture()
        var page = try #require(source.page(at: 0))
        source.insert(try #require(page.copy() as? PDFPage), at: 1)
        page.rotation = rotation
        page.setBounds(CGRect(x: 20, y: 20, width: 360, height: 360), for: .cropBox)
        _ = Fixtures.foreignAnnotation(on: page)
        // Establish a real file baseline: PDFKit normalizes newly-created note icons
        // from 25x25 to 24x24 and may create a Popup annotation during the first save.
        source = try Fixtures.reopen(source)
        page = try #require(source.page(at: 0))
        let annotations = page.annotations
        if rotation == 0 {
            let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #require(source.dataRepresentation()).write(to: directory.appendingPathComponent("Scanned-Editing-Smoke.pdf"))
        }
        let selection = try #require(source.findString("TARGET", withOptions: []).first)
        let neighbor = try #require(source.findString("NEIGHBOR", withOptions: []).first).bounds(for: page)
        let region = PageRegion(pageIndex: 0, bounds: selection.bounds(for: page))
        #expect(throws: PDFNativeTextError.scannedText) {
            try PDFNativeTextEditor.replace(in: source, region: region, originalText: "TARGET", replacement: replacement())
        }
        let edited = try PDFNativeTextEditor.replaceScanned(in: source, region: region, originalText: "TARGET", replacement: replacement())
        let saved = try Fixtures.reopen(edited), result = try #require(saved.page(at: 0))
        #expect(result.string?.contains("TARGET") == false)
        #expect(saved.pageCount == 2)
        #expect(saved.page(at: 1)?.string?.contains("TARGET") == true)
        let untouchedSource = try #require(source.page(at: 1)), untouchedSaved = try #require(saved.page(at: 1))
        #expect(try outsideDifference(contentImage(untouchedSource), contentImage(untouchedSaved), excluded: .null) <= 1)
        #expect(saved.findString("EDITED", withOptions: []).count == 1)
        #expect(saved.findString("NEIGHBOR", withOptions: []).count == 2)
        #expect(result.annotations.count == annotations.count)
        for (savedAnnotation, annotation) in zip(result.annotations, annotations) {
            #expect(savedAnnotation.bounds == annotation.bounds)
            #expect(savedAnnotation.contents == annotation.contents)
            #expect(savedAnnotation.type == annotation.type)
            #expect(savedAnnotation.userName == annotation.userName)
        }
        #expect(result.rotation == rotation)
        #expect(result.bounds(for: .cropBox) == page.bounds(for: .cropBox))
        let remaining = try #require(saved.findString("NEIGHBOR", withOptions: []).first).bounds(for: result)
        #expect(abs(remaining.minX - neighbor.minX) < 0.02 && abs(remaining.minY - neighbor.minY) < 0.02)
        // Compare full media in original orientation. The source image's outside pixels must survive.
        page.rotation = 0; result.rotation = 0
        page.setBounds(CGRect(x: 0, y: 0, width: 400, height: 400), for: .cropBox)
        result.setBounds(page.bounds(for: .cropBox), for: .cropBox)
        // Render the source content directly: PDFKit can regenerate note-icon appearance
        // during serialization, separately from the preserved annotation metadata above.
        let before = try contentImage(page)
        let after = try contentImage(result)
        let maxOutsideDifference = try outsideDifference(before, after, excluded: region.bounds.insetBy(dx: -3, dy: -3))
        #expect(maxOutsideDifference <= 1)
        let visible = NSBitmapImageRep(cgImage: after)
        var greenPixels = 0
        for y in Int(400 - region.bounds.maxY)..<Int(400 - region.bounds.minY) {
            for x in Int(region.bounds.minX)..<Int(region.bounds.maxX) {
                if let pixel = visible.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), pixel.greenComponent > pixel.redComponent + 0.2 { greenPixels += 1 }
            }
        }
        #expect(greenPixels > 20)
        // Deletion exposes paper, proving that the source scan's original letters are gone.
        let deleted = try PDFNativeTextEditor.replaceScanned(in: source, region: region, originalText: "TARGET", replacement: NSAttributedString(string: ""))
        let deletePage = try #require(deleted.page(at: 0))
        let deleteImage = NSBitmapImageRep(cgImage: try PDFConversion.renderedImage(page: deletePage, scale: 1))
        var darkPixels = 0
        for y in Int(400 - region.bounds.maxY)..<Int(400 - region.bounds.minY) {
            for x in Int(region.bounds.minX)..<Int(region.bounds.maxX) {
                if let pixel = deleteImage.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), pixel.redComponent < 0.85 { darkPixels += 1 }
            }
        }
        #expect(darkPixels == 0)
        #expect(source.findString("TARGET", withOptions: []).count == 2)
        #expect(imageSizes(saved).contains(CGSize(width: 400, height: 400)))
    }

    @Test("Patterned scan backgrounds are rejected without altering the source")
    func patternedBackground() async throws {
        let source = try await fixture(patterned: true), page = try #require(source.page(at: 0))
        let selected = try #require(source.findString("TARGET", withOptions: []).first)
        let before = try PDFConversion.renderedImage(page: page, scale: 1)
        #expect(throws: PDFNativeTextError.self) {
            try PDFNativeTextEditor.replaceScanned(in: source, region: PageRegion(pageIndex: 0, bounds: selected.bounds(for: page)), originalText: "TARGET", replacement: replacement())
        }
        let after = try PDFConversion.renderedImage(page: page, scale: 1)
        #expect(before.dataProvider?.data == after.dataProvider?.data)
        #expect(source.findString("TARGET", withOptions: []).count == 1)
    }

    private func replacement() -> NSAttributedString { NSAttributedString(string: "EDITED", attributes: [.font: NSFont(name: "Courier-Bold", size: 18)!, .foregroundColor: NSColor.systemGreen]) }

    private func contentImage(_ page: PDFPage) throws -> CGImage {
        let source = try #require(page.pageRef)
        let context = try #require(CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 1600,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        context.drawPDFPage(source)
        return try #require(context.makeImage())
    }

    private func fixture(patterned: Bool = false) async throws -> PDFDocument {
        let bitmap = try #require(CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 1600, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(NSColor.white.cgColor); bitmap.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        if patterned {
            bitmap.setFillColor(NSColor(white: 0.86, alpha: 1).cgColor)
            for x in stride(from: 0, to: 400, by: 16) { bitmap.fill(CGRect(x: x, y: 0, width: 8, height: 400)) }
        }
        for (text, y) in [("TARGET", 270), ("NEIGHBOR", 195)] {
            bitmap.textPosition = CGPoint(x: 60, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont(name: "Courier", size: 28)!, .foregroundColor: NSColor.black])), bitmap)
        }
        let image = try #require(bitmap.makeImage())
        let bytes = NSMutableData(), consumer = try #require(CGDataConsumer(data: bytes as CFMutableData))
        var media = CGRect(x: 0, y: 0, width: 400, height: 400)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil); context.draw(image, in: media)
        context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 25, y: 25, width: 35, height: 35))
        context.endPDFPage(); context.closePDF()
        let source = try #require(PDFDocument(data: bytes as Data))
        let ocr = try await PDFOCR.recognize(document: source, options: PDFOCROptions(languages: ["en-US"]))
        return try #require(PDFDocument(data: ocr.data))
    }

    private func outsideDifference(_ before: CGImage, _ after: CGImage, excluded: CGRect) throws -> Int {
        #expect(before.width == after.width && before.height == after.height)
        let one = try #require(before.dataProvider?.data), two = try #require(after.dataProvider?.data)
        let a = Array(one as Data), b = Array(two as Data)
        var difference = 0
        for y in 0..<before.height {
            for x in 0..<before.width where !excluded.contains(CGPoint(x: Double(x) + 0.5, y: Double(before.height - y) - 0.5)) {
                for channel in 0..<4 { difference = max(difference, abs(Int(a[y * before.bytesPerRow + x * 4 + channel]) - Int(b[y * after.bytesPerRow + x * 4 + channel]))) }
            }
        }
        return difference
    }

    private func imageSizes(_ document: PDFDocument) -> [CGSize] {
        guard let data = document.dataRepresentation(), let provider = CGDataProvider(data: data as CFData), let source = CGPDFDocument(provider), let dictionary = source.page(at: 1)?.dictionary,
              let resources = PDFNativeTextEditor.inheritedResources(dictionary) else { return [] }
        var bytes = Data()
        if let contents = nativeStream(dictionary, "Contents"), let data = try? nativeDecodedStream(contents) { bytes.append(data) }
        if let array = nativeArray(dictionary, "Contents") {
            for index in 0..<CGPDFArrayGetCount(array) { var stream: CGPDFStreamRef?; if CGPDFArrayGetStream(array, index, &stream), let stream, let data = try? nativeDecodedStream(stream) { bytes.append(data); bytes.append(10) } }
        }
        guard let program = try? PDFNativeTextProgram(data: bytes, resources: resources) else { return [] }
        return program.allImages.compactMap { image in
            guard let dictionary = CGPDFStreamGetDictionary(image.stream), let width = nativeNumber(dictionary, "Width"), let height = nativeNumber(dictionary, "Height") else { return nil }
            return CGSize(width: width, height: height)
        }
    }
}
