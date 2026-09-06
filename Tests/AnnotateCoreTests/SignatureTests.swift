import AppKit
import PDFKit
import Testing
@testable import AnnotateCore

@Suite("Electronic signature persistence", .serialized)
@MainActor
struct SignatureTests {
    private let region = PageRegion(pageIndex: 0, bounds: CGRect(x: 80, y: 80, width: 180, height: 65))

    @Test("Typed and drawn signatures persist as ordinary PDF annotations")
    func typedAndDrawn() throws {
        let document = try Fixtures.document()
        try PDFSignatureEditor.typed("Ada Lovelace", in: document, regions: [region])
        try PDFSignatureEditor.drawn([[CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 1), CGPoint(x: 1, y: 0)]], in: document, regions: [region])
        let reopened = try Fixtures.reopen(document)
        let signatures = Fixtures.annotations(in: reopened).filter { $0.value(forAnnotationKey: PDFSignatureEditor.ownerKey) != nil }
        #expect(signatures.count == 2)
        #expect(signatures.contains { $0.type == "FreeText" && $0.contents == "Ada Lovelace" })
        let ink = try #require(signatures.first { $0.type == "Ink" })
        #expect(ink.paths?.count == 1)
        #expect(ink.bounds == region.bounds)
    }

    @Test("Uploaded signature appearance survives save/reopen as pixels")
    func imageAppearance() throws {
        let document = try Fixtures.document()
        let image = NSImage(size: CGSize(width: 80, height: 30), flipped: false) { rect in
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
            rect.fill()
            return true
        }
        try PDFSignatureEditor.image(image, in: document, regions: [region])
        let reopened = try Fixtures.reopen(document)
        let page = try #require(reopened.page(at: 0))
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 612 * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        page.draw(with: .mediaBox, to: context)
        let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: 612 * 792 * 4)
        let redPixels = (0..<(612 * 792)).count { pixels[$0 * 4] > 200 && pixels[$0 * 4 + 1] < 70 && pixels[$0 * 4 + 2] < 70 }
        #expect(redPixels > 1_000)
        #expect(page.string?.contains("A place for your attention") == true)
    }

    @Test("Uploaded signatures preserve markers and fields through page replacement")
    func imagePreservesAnnotations() throws {
        let document = try Fixtures.document()
        let marker = try Fixtures.marker(in: document)
        try MarkerCodec.apply(marker, to: document)
        try PDFFormEditor.create(in: document, region: PageRegion(pageIndex: 0, bounds: CGRect(x: 300, y: 80, width: 120, height: 30)), name: "Signer", kind: .text)
        let field = try #require(PDFFormEditor.fields(in: document).first)
        try PDFFormEditor.fill(in: document, field: field, value: "Ada")
        let image = signatureImage()
        try PDFSignatureEditor.image(image, in: document, regions: [region])
        let reopened = try Fixtures.reopen(document)
        #expect(MarkerCodec.markers(in: reopened) == [marker])
        #expect(PDFFormEditor.fields(in: reopened).first?.name == "Signer")
        #expect(PDFFormEditor.fields(in: reopened).first?.value == "Ada")
    }

    @Test("Typed and uploaded signatures stay upright on rotated, cropped pages", arguments: [0, 90, 180, 270])
    func rotatedSignature(_ rotation: Int) throws {
        for typed in [true, false] {
            let document = try Fixtures.geometryDocument(rotation: rotation, crop: CGRect(x: 50, y: 70, width: 300, height: 350))
            let page = try #require(document.page(at: 0))
            let transform = page.transform(for: .cropBox)
            let crop = page.bounds(for: .cropBox).applying(transform)
            let box = CGRect(x: crop.minX + 20, y: crop.minY + 20, width: 180, height: 60).applying(transform.inverted())
            let area = PageRegion(pageIndex: 0, bounds: box)
            if typed { try PDFSignatureEditor.typed("Ada Lovelace", in: document, regions: [area], color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)) }
            else { try PDFSignatureEditor.image(signatureImage(), in: document, regions: [area]) }
            let reopened = try Fixtures.reopen(document)
            let output = try #require(reopened.page(at: 0))
            #expect(output.rotation == rotation)
            #expect(output.bounds(for: .cropBox) == CGRect(x: 50, y: 70, width: 300, height: 350))
            let rendered = try PDFConversion.renderedImage(page: output, scale: 1)
            let bitmap = try #require(CGContext(data: nil, width: rendered.width, height: rendered.height, bitsPerComponent: 8, bytesPerRow: rendered.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.draw(rendered, in: CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
            let pixels = try #require(bitmap.data).bindMemory(to: UInt8.self, capacity: rendered.width * rendered.height * 4)
            var minX = rendered.width, maxX = 0, minY = rendered.height, maxY = 0, count = 0
            for y in 0..<rendered.height {
                for x in 0..<rendered.width {
                    let offset = (y * rendered.width + x) * 4
                    if pixels[offset] < 80, pixels[offset + 1] > 190, pixels[offset + 2] < 80 {
                        count += 1; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
            #expect(count > 100)
            #expect(maxX - minX > (maxY - minY) * 2)
        }
    }

    private func signatureImage() -> NSImage {
        NSImage(size: CGSize(width: 180, height: 60), flipped: false) { rect in
            NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1).setFill(); rect.fill(); return true
        }
    }

    @Test("Multi-page signature validation completes before any page is changed")
    func atomicValidation() throws {
        let document = try Fixtures.document()
        let bad = PageRegion(pageIndex: 400, bounds: region.bounds)
        #expect(throws: (any Error).self) { try PDFSignatureEditor.typed("Ada", in: document, regions: [region, bad]) }
        #expect(Fixtures.annotations(in: document).isEmpty)
    }
}
