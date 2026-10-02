import AppKit
import CoreGraphics
import CoreText
import PDFKit
import Testing
@testable import AnnotateCore

@Suite("Native existing PDF images", .serialized)
@MainActor
struct NativeImageEditingTests {
    @Test("Replacement previews retain colored pixels after Apply and save/reopen")
    func previewsAfterReplacement() throws {
        let source = try fixture(sharedForm: true)
        let initialImages = try PDFNativeImageEditor.images(in: source, pageIndex: 0)
        let target = try #require(initialImages.first)
        let output = try PDFNativeImageEditor.update(in: source, image: target, replacement: replacement())
        for document in [output, try Fixtures.reopen(output)] {
            let images = try PDFNativeImageEditor.images(in: document, pageIndex: 0)
            let replaced = try #require(images.first), unchanged = try #require(images.last)
            #expect(replaced.id == target.id)
            #expect(replaced != target) // Stable selection ID, distinct complete preview identity.
            for (image, isGreen) in [(replaced, true), (unchanged, false)] {
                let preview = try PDFNativeImageEditor.preview(in: document, image: image, maximumDimension: 160)
                let color = try #require(NSBitmapImageRep(cgImage: preview).colorAt(x: preview.width / 4, y: preview.height / 2)?.usingColorSpace(.deviceRGB))
                if isGreen { #expect(color.greenComponent > 0.97 && color.redComponent < 0.01 && color.blueComponent < 0.01) }
                else { #expect(color.redComponent > 0.99 && color.greenComponent < 0.01 && color.blueComponent < 0.01) }
            }
        }
    }
    @Test("Images enumerate with native geometry across crop and rotation", arguments: [0, 90, 180, 270])
    func enumeration(rotation: Int) throws {
        let document = try fixture(), page = try #require(document.page(at: 0))
        page.rotation = rotation; page.setBounds(CGRect(x: 20, y: 20, width: 360, height: 360), for: .cropBox)
        let images = try PDFNativeImageEditor.images(in: document, pageIndex: 0)
        #expect(images.count == 1)
        let image = try #require(images.first)
        #expect(image.bounds == CGRect(x: 40, y: 200, width: 100, height: 80))
        #expect(image.pixelSize == CGSize(width: 16, height: 12))
        #expect(image.canTransform)
        let preview = try PDFNativeImageEditor.preview(in: document, image: image)
        #expect(preview.width == 320 && preview.height == 256)
        let destination = CGRect(x: 175, y: 100, width: 120, height: 95)
        let moved = try Fixtures.reopen(PDFNativeImageEditor.update(in: document, image: image, bounds: destination))
        let movedImage = try #require(PDFNativeImageEditor.images(in: moved, pageIndex: 0).first)
        #expect(close(movedImage.bounds, destination))
        #expect(moved.page(at: 0)?.rotation == rotation)
        #expect(moved.page(at: 0)?.bounds(for: .cropBox) == page.bounds(for: .cropBox))
        #expect(moved.findString("NEIGHBOR", withOptions: []).count == 1)
    }

    @Test("Deleting removes the original invocation and retired source bytes without changing vectors or text")
    func deletion() throws {
        let source = try fixture(), page = try #require(source.page(at: 0))
        let image = try #require(PDFNativeImageEditor.images(in: source, pageIndex: 0).first)
        let original = try render(page)
        let output = try PDFNativeImageEditor.remove(in: source, image: image)
        let saved = try Fixtures.reopen(output), after = try render(#require(saved.page(at: 0)))
        #expect(try PDFNativeImageEditor.images(in: saved, pageIndex: 0).isEmpty)
        #expect(saved.findString("NEIGHBOR", withOptions: []).count == 1)
        #expect(try outsideDifference(original, after, excluded: image.bounds) == 0)
        let paper = try pixel(after, x: 60, y: 240)
        #expect(paper.redComponent > 0.99 && paper.greenComponent > 0.99 && paper.blueComponent > 0.99)
        let vector = try pixel(after, x: 125, y: 225)
        #expect(vector.blueComponent > 0.99 && vector.redComponent < 0.01)
        let bytes = try #require(output.dataRepresentation())
        #expect(bytes.range(of: sourcePixels()) == nil)
        #expect(try PDFNativeImageEditor.images(in: source, pageIndex: 0).count == 1)
    }

    @Test("Replacement keeps paint order, alpha, annotations, text geometry and another page's shared image")
    func replacementAndSharedPage() throws {
        var source = try fixture(twoPages: true)
        _ = Fixtures.foreignAnnotation(on: try #require(source.page(at: 0)))
        source = try Fixtures.reopen(source)
        let page = try #require(source.page(at: 0)), neighbor = try #require(source.findString("NEIGHBOR", withOptions: []).first).bounds(for: page)
        let image = try #require(PDFNativeImageEditor.images(in: source, pageIndex: 0).first)
        let replacementImage = try replacement(alpha: 0.5)
        let output = try PDFNativeImageEditor.update(in: source, image: image, replacement: replacementImage)
        let saved = try Fixtures.reopen(output), result = try #require(saved.page(at: 0))
        let newImage = try #require(PDFNativeImageEditor.images(in: saved, pageIndex: 0).first)
        #expect(newImage.bounds == image.bounds)
        #expect(newImage.pixelSize == CGSize(width: 20, height: 10))
        let shown = try render(result), green = try pixel(shown, x: 60, y: 240)
        let expected = try imageColorOnWhite(replacementImage)
        #expect(abs(green.greenComponent - expected.greenComponent) <= 1.0 / 255)
        #expect(abs(green.redComponent - expected.redComponent) <= 1.0 / 255)
        #expect(abs(green.blueComponent - expected.blueComponent) <= 1.0 / 255)
        let cover = try pixel(shown, x: 125, y: 225)
        #expect(cover.blueComponent > 0.99 && cover.redComponent < 0.01)
        #expect(try outsideDifference(render(page), shown, excluded: image.bounds) == 0)
        #expect(try outsideDifference(render(#require(source.page(at: 1))), render(#require(saved.page(at: 1))), excluded: .null) == 0)
        let preserved = try #require(saved.findString("NEIGHBOR", withOptions: []).first).bounds(for: result)
        #expect(close(preserved, neighbor))
        #expect(result.annotations.count == page.annotations.count)
        for (before, after) in zip(page.annotations, result.annotations) {
            #expect(before.bounds == after.bounds && before.contents == after.contents && before.type == after.type)
        }
    }

    @Test("A shared Form is copied only for the edited image invocation")
    func sharedForm() throws {
        let source = try fixture(sharedForm: true), before = try PDFNativeImageEditor.images(in: source, pageIndex: 0)
        #expect(before.count == 2)
        let top = try #require(before.max { $0.bounds.minY < $1.bounds.minY })
        let bottom = try #require(before.min { $0.bounds.minY < $1.bounds.minY })
        let destination = CGRect(x: 175, y: 210, width: 80, height: 60)
        let replacementImage = try replacement()
        let edited = try PDFNativeImageEditor.update(in: source, image: top, bounds: destination, replacement: replacementImage)
        let after = try PDFNativeImageEditor.images(in: Fixtures.reopen(edited), pageIndex: 0)
        #expect(after.count == 2)
        #expect(after.contains { close($0.bounds, destination) && $0.pixelSize == CGSize(width: 20, height: 10) })
        #expect(after.contains { $0.bounds == bottom.bounds && $0.pixelSize == bottom.pixelSize })
        let beforePixels = try render(#require(source.page(at: 0))), afterPixels = try render(#require(edited.page(at: 0)))
        #expect(try outsideDifference(beforePixels, afterPixels, excluded: top.bounds.union(destination)) == 0)
        let cleared = try pixel(afterPixels, x: 60, y: 240)
        #expect(cleared.redComponent > 0.99 && cleared.greenComponent > 0.99)
        let green = try pixel(afterPixels, x: 195, y: 240)
        let expected = try imageColorOnWhite(replacementImage)
        #expect(abs(green.greenComponent - expected.greenComponent) <= 1.0 / 255 && green.redComponent < 0.01)
        #expect(edited.findString("NEIGHBOR", withOptions: []).count == 1)
    }

    @Test("Skew and custom clipping disable movement while same-position replacement and deletion remain possible", arguments: ["skew", "clip"])
    func constrainedPlacement(kind: String) throws {
        let source = try fixture(constraint: kind), image = try #require(PDFNativeImageEditor.images(in: source, pageIndex: 0).first)
        #expect(!image.canTransform)
        #expect(image.unsupportedReason != nil)
        #expect(throws: PDFNativeImageError.self) { try PDFNativeImageEditor.update(in: source, image: image, bounds: CGRect(x: 180, y: 100, width: 100, height: 80)) }
        #expect(try PDFNativeImageEditor.images(in: PDFNativeImageEditor.update(in: source, image: image, replacement: replacement()), pageIndex: 0).count == 1)
        #expect(try PDFNativeImageEditor.images(in: PDFNativeImageEditor.remove(in: source, image: image), pageIndex: 0).isEmpty)
    }

    @Test("Stale tokens and invalid geometry cannot alter the source")
    func invalidEdits() throws {
        let source = try fixture(), image = try #require(PDFNativeImageEditor.images(in: source, pageIndex: 0).first)
        let edited = try PDFNativeImageEditor.update(in: source, image: image, replacement: replacement())
        #expect(throws: PDFNativeImageError.staleSelection) { try PDFNativeImageEditor.remove(in: edited, image: image) }
        let sameGeometryDifferentBytes = try fixture(recolored: true)
        #expect(throws: PDFNativeImageError.staleSelection) { try PDFNativeImageEditor.remove(in: sameGeometryDifferentBytes, image: image) }
        for bounds in [CGRect(x: -1, y: 200, width: 100, height: 80), CGRect(x: 40, y: 200, width: 0, height: 80), CGRect(x: 40, y: 200, width: CGFloat.infinity, height: 80)] {
            #expect(throws: PDFNativeImageError.invalidBounds) { try PDFNativeImageEditor.update(in: source, image: image, bounds: bounds) }
        }
        #expect(try PDFNativeImageEditor.images(in: source, pageIndex: 0).first?.bounds == image.bounds)
    }

    @Test("Apple compressed image content can be edited without changing the accompanying subset-font text")
    func applePDFAndFixture() throws {
        let bytes = NSMutableData(), consumer = try #require(CGDataConsumer(data: bytes as CFMutableData))
        var media = CGRect(x: 0, y: 0, width: 400, height: 400)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.draw(try replacement(), in: CGRect(x: 40, y: 200, width: 100, height: 80))
        context.draw(try replacement(alpha: 0.5), in: CGRect(x: 220, y: 100, width: 100, height: 50))
        context.textPosition = CGPoint(x: 40, y: 330)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "IMAGE EDITOR SMOKE", attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black])), context)
        context.endPDFPage(); context.closePDF()
        let source = try #require(PDFDocument(data: bytes as Data))
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let smoke = directory.appendingPathComponent("Image-Editing-Smoke.pdf")
        if !FileManager.default.fileExists(atPath: smoke.path) { try (bytes as Data).write(to: smoke) }
        let images = try PDFNativeImageEditor.images(in: source, pageIndex: 0)
        #expect(images.count == 2)
        let image = try #require(images.first)
        let result = try PDFNativeImageEditor.remove(in: source, image: image)
        #expect(try PDFNativeImageEditor.images(in: result, pageIndex: 0).count == 1)
        #expect(result.findString("IMAGE EDITOR SMOKE", withOptions: []).count == 1)
    }

    @Test("Repeated resource references are hashed once and expanding Form invocations hit an aggregate limit")
    func boundedSharedGraphs() throws {
        let page = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 400] /Contents 4 0 R /Resources << /XObject << /Im 5 0 R >> >> >>"
        let header = [Data("<< /Type /Catalog /Pages 2 0 R >>".utf8), Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8)]
        var shared = header + [Data(page.utf8), stream("q 100 0 0 80 40 200 cm /Im Do Q"), Data("<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /AnnotateMetadata 6 0 R /Length 3 >>\nstream\nRGB\nendstream".utf8)]
        for id in 6...22 { shared.append(Data((id == 22 ? "[(leaf)]" : "[\(id + 1) 0 R \(id + 1) 0 R]").utf8)) }
        #expect(try PDFNativeImageEditor.images(in: rawPDF(shared), pageIndex: 0).count == 1)
        var expanding = header + [Data(page.replacingOccurrences(of: "/Im 5 0 R", with: "/Fm 5 0 R").utf8), stream("/Fm Do")]
        for id in 5...16 {
            let content = id == 16 ? "" : "/Next Do /Next Do"
            let resources = id == 16 ? "" : "/Resources << /XObject << /Next \(id + 1) 0 R >> >>"
            expanding.append(Data("<< /Type /XObject /Subtype /Form /BBox [0 0 400 400] \(resources) /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream".utf8))
        }
        #expect(throws: PDFNativeImageError.self) { try PDFNativeImageEditor.images(in: rawPDF(expanding), pageIndex: 0) }
    }

    /// PDFNativeImageEditor.replacementStream: 32,768 pixels a side, 80,000,000 in all.
    @Test("A replacement image may be exactly 32,768 pixels wide; one more, or more than 80 million pixels, is refused")
    func replacementSizeLimits() throws {
        let source = try fixture()
        let image = try #require(try PDFNativeImageEditor.images(in: source, pageIndex: 0).first)
        let wide = try PDFNativeImageEditor.update(in: source, image: image, replacement: try bitmap(width: 32_768, height: 1))
        #expect(try PDFNativeImageEditor.images(in: wide, pageIndex: 0).first?.pixelSize == CGSize(width: 32_768, height: 1))
        #expect(throws: PDFNativeImageError.invalidImage) {
            try PDFNativeImageEditor.update(in: source, image: image, replacement: try bitmap(width: 32_769, height: 1))
        }
        // 8,000 × 10,001: each side well within the limit, the area 8,000 pixels past it.
        #expect(throws: PDFNativeImageError.invalidImage) {
            try PDFNativeImageEditor.update(in: source, image: image, replacement: try bitmap(width: 8_000, height: 10_001))
        }
    }

    /// A one-bit gray image, so even an oversized one is cheap to build.
    private func bitmap(width: Int, height: Int) throws -> CGImage {
        let rowBytes = (width + 7) / 8
        let provider = try #require(CGDataProvider(data: Data(repeating: 0x55, count: rowBytes * height) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func replacement(alpha: Double = 1) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 80, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: alpha)); context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        return try #require(context.makeImage())
    }
    private func render(_ page: PDFPage) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 1600, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        context.drawPDFPage(try #require(page.pageRef))
        return try #require(context.makeImage())
    }
    private func imageColorOnWhite(_ image: CGImage) throws -> NSColor {
        let context = try #require(CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 80, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 20, height: 10))
        let bitmap = try #require(context.makeImage())
        return try #require(NSBitmapImageRep(cgImage: bitmap).colorAt(x: 10, y: 5)?.usingColorSpace(.deviceRGB))
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> NSColor { try #require(NSBitmapImageRep(cgImage: image).colorAt(x: x, y: 399 - y)?.usingColorSpace(.deviceRGB)) }
    private func close(_ first: CGRect, _ second: CGRect) -> Bool { abs(first.minX - second.minX) < 0.001 && abs(first.minY - second.minY) < 0.001 && abs(first.width - second.width) < 0.001 && abs(first.height - second.height) < 0.001 }
    private func outsideDifference(_ before: CGImage, _ after: CGImage, excluded: CGRect) throws -> Int {
        let a = Array(try #require(before.dataProvider?.data) as Data), b = Array(try #require(after.dataProvider?.data) as Data)
        var difference = 0
        for y in 0..<400 { for x in 0..<400 where !excluded.contains(CGPoint(x: Double(x) + 0.5, y: 399.5 - Double(y))) {
            for channel in 0..<4 { difference = max(difference, abs(Int(a[y * 1600 + x * 4 + channel]) - Int(b[y * 1600 + x * 4 + channel]))) }
        } }
        return difference
    }
    private func sourcePixels() -> Data { Data((0..<(16 * 12)).flatMap { pixel -> [UInt8] in pixel % 16 < 8 ? [255, 0, 0] : [255, 220, 0] }) }
    private func fixture(twoPages: Bool = false, sharedForm: Bool = false, constraint: String? = nil, recolored: Bool = false) throws -> PDFDocument {
        let pixels = recolored ? Data(sourcePixels().map { 255 - $0 }) : sourcePixels()
        let image = Data("<< /Type /XObject /Subtype /Image /Width 16 /Height 12 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length \(pixels.count) >>\nstream\n".utf8) + pixels + Data("\nendstream".utf8)
        let draws: String
        if sharedForm { draws = "q 1 0 0 1 40 200 cm /Fm Do Q q 1 0 0 1 40 80 cm /Fm Do Q" }
        else { draws = "q " + (constraint == "clip" ? "40 200 100 80 re W n " : "") + (constraint == "skew" ? "100 0 20 80 40 200" : "100 0 0 80 40 200") + " cm /Im Do Q" }
        let content = "BT /F 18 Tf 40 330 Td (NEIGHBOR) Tj ET " + draws + " q 0 0 1 rg 120 220 30 10 re f Q"
        let resources = "/Resources << /Font << /F 6 0 R >> /XObject << \(sharedForm ? "/Fm 8 0 R" : "/Im 5 0 R") >> >>"
        var objects: [Data] = [Data("<< /Type /Catalog /Pages 2 0 R >>".utf8), Data("<< /Type /Pages /Kids [3 0 R \(twoPages ? "7 0 R" : "")] /Count \(twoPages ? 2 : 1) >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 400] \(resources) /Contents 4 0 R >>".utf8), stream(content), image,
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8), Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 400] \(resources) /Contents 4 0 R >>".utf8)]
        let form = "q 100 0 0 80 0 0 cm /Im Do Q"
        objects.append(Data("<< /Type /XObject /Subtype /Form /BBox [0 0 300 100] /Resources << /XObject << /Im 5 0 R >> >> /Length \(form.utf8.count) >>\nstream\n\(form)\nendstream".utf8))
        return try rawPDF(objects)
    }
    private func rawPDF(_ objects: [Data]) throws -> PDFDocument {
        var output = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() { offsets.append(output.count); output.append(Data("\(index + 1) 0 obj\n".utf8)); output.append(object); output.append(Data("\nendobj\n".utf8)) }
        let xref = output.count
        output.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { output.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        output.append(Data("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try #require(PDFDocument(data: output))
    }
    private func stream(_ string: String) -> Data { Data("<< /Length \(string.utf8.count) >>\nstream\n\(string)\nendstream".utf8) }
}
