import AppKit
import PDFKit
import Testing
@testable import AnnotateCore

@Suite("Marker readability", .serialized)
@MainActor
struct MarkerColorTests {
    nonisolated private static let customColors: [MarkerColor] = [
        .init(red: 0, green: 0, blue: 0),
        .init(red: 0.02, green: 0.03, blue: 0.06),
        .init(red: 1, green: 1, blue: 1),
        .init(red: 0, green: 0, blue: 1),
        .init(red: 1, green: 0, blue: 0),
        .init(red: 0, green: 1, blue: 0),
        .init(red: 0.46, green: 0.46, blue: 0.46),
        .init(red: 0.47, green: 0.47, blue: 0.47)
    ]

    @Test("Every preset and custom badge color has readable ink", arguments: MarkerColor.palette + customColors)
    func colorContrast(color: MarkerColor) throws {
        let ink = try #require(color.readableInkColor.usingColorSpace(.sRGB))
        #expect(contrast(color.nsColor, ink) >= 4.5)
        #expect(ink.alphaComponent == 1)
    }

    @Test("Readable ink covers the custom color picker gamut, including the gray crossover")
    func colorPickerGamut() {
        for red in 0...10 {
            for green in 0...10 {
                for blue in 0...10 {
                    let color = MarkerColor(red: Double(red) / 10, green: Double(green) / 10, blue: Double(blue) / 10)
                    #expect(contrast(color.nsColor, color.readableInkColor) >= 4.5)
                }
            }
        }
        for value in 0...255 {
            let component = Double(value) / 255
            let gray = MarkerColor(red: component, green: component, blue: component)
            #expect(contrast(gray.nsColor, gray.readableInkColor) >= 4.5)
        }
    }

    @Test("Opening an older dark badge repairs only its appearance and preserves foreign annotations")
    func repairLegacyBadge() throws {
        let document = try Fixtures.document()
        var marker = try Fixtures.marker(in: document)
        marker.color = .init(red: 0.02, green: 0.03, blue: 0.06)
        try MarkerCodec.apply(marker, to: document)
        let page = try #require(document.page(at: marker.pageIndex))
        let badge = try #require(page.annotations.first { $0.type == "FreeText" })
        badge.fontColor = .black
        badge.color = marker.color.nsColor.withAlphaComponent(0.9)
        let foreign = PDFAnnotation(bounds: CGRect(x: 300, y: 100, width: 25, height: 25), forType: .freeText, withProperties: nil)
        foreign.contents = "Foreign note"
        foreign.fontColor = .red
        foreign.color = .yellow
        page.addAnnotation(foreign)
        let annotations = page.annotations
        let foreignInk = foreign.fontColor
        let foreignColor = foreign.color

        MarkerCodec.refreshAppearance(in: document)

        #expect(MarkerCodec.markers(in: document) == [marker])
        #expect(page.annotations == annotations)
        #expect(badge.color.alphaComponent == 1)
        #expect(contrast(badge.color, try #require(badge.fontColor)) >= 4.5)
        #expect(foreign.fontColor == foreignInk)
        #expect(foreign.color == foreignColor)
        #expect(foreign.contents == "Foreign note")
        let reopened = try Fixtures.reopen(document)
        #expect(MarkerCodec.markers(in: reopened) == [marker])
        try assertVisibleInk(on: try #require(reopened.page(at: marker.pageIndex)), bounds: badge.bounds, color: marker.color)
    }

    @Test("Appearance repair leaves annotation-restricted PDFs untouched")
    func repairRestrictedPDF() throws {
        let document = try Fixtures.document()
        var marker = try Fixtures.marker(in: document)
        marker.color = .init(red: 0, green: 0, blue: 0)
        try MarkerCodec.apply(marker, to: document)
        let badge = try #require(Fixtures.annotations(in: document).first { $0.type == "FreeText" })
        badge.fontColor = .black
        for annotation in Fixtures.annotations(in: document) {
            if annotation.type == "Text" { annotation.page?.removeAnnotation(annotation) }
            if annotation.type == "Highlight" { annotation.contents = "Restricted legacy comment" }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("annotate-contrast-restricted-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(document.write(to: url, withOptions: [
            .ownerPasswordOption: "owner-password", .userPasswordOption: "reader-password", .accessPermissionsOption: 0
        ]))
        let restricted = try #require(PDFDocument(url: url))
        #expect(restricted.unlock(withPassword: "reader-password"))
        #expect(!restricted.allowsCommenting)
        let restrictedBadge = try #require(Fixtures.annotations(in: restricted).first { $0.type == "FreeText" })
        let priorInk = restrictedBadge.fontColor
        let priorColor = restrictedBadge.color
        let priorAnnotations = Fixtures.annotations(in: restricted)
        MarkerCodec.refreshAppearance(in: restricted)
        #expect(restrictedBadge.fontColor == priorInk)
        #expect(restrictedBadge.color == priorColor)
        #expect(Fixtures.annotations(in: restricted) == priorAnnotations)
        #expect(priorAnnotations.contains { $0.contents == "Restricted legacy comment" })
    }

    @Test("Badge ink stays readable after reopening and flattening a real PDF", arguments: MarkerColor.palette + customColors)
    func persistedBadge(color: MarkerColor) throws {
        let document = try Fixtures.document()
        var marker = try Fixtures.marker(in: document)
        marker.color = color
        try MarkerCodec.apply(marker, to: document)
        let originalBadge = try #require(Fixtures.annotations(in: document).first { $0.type == "FreeText" })
        #expect(contrast(originalBadge.color, try #require(originalBadge.fontColor)) >= 4.5)
        let reopened = try Fixtures.reopen(document)
        #expect(MarkerCodec.markers(in: reopened) == [marker])
        let page = try #require(reopened.page(at: marker.pageIndex))
        let badge = try #require(page.annotations.first { $0.type == "FreeText" })
        #expect(badge.color.alphaComponent == 1)
        #expect(badge.shouldPrint)
        #expect(badge.contents == "★")
        // PDFKit can report black fontColor after reopening a white-ink appearance stream.
        // Check the actual rendered glyph and fill, which also protects third-party readers.
        try assertVisibleInk(on: page, bounds: badge.bounds, color: color)

        let flattened = try #require(PDFDocument(data: PDFExporter.flattenedData(document: reopened, markers: [marker], includeNotes: false)))
        let flattenedPage = try #require(flattened.page(at: marker.pageIndex))
        #expect(flattenedPage.annotations.isEmpty)
        try assertVisibleInk(on: flattenedPage, bounds: badge.bounds, color: color)
    }

    private func contrast(_ first: NSColor, _ second: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            guard let rgb = color.usingColorSpace(.sRGB) else { return .nan }
            let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
            let linear = components.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        let values = [luminance(first), luminance(second)].sorted()
        return (values[1] + 0.05) / (values[0] + 0.05)
    }

    private func assertVisibleInk(on page: PDFPage, bounds: CGRect, color: MarkerColor) throws {
        let scale = 4.0
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        // Read the known sRGB bytes directly. NSBitmapImageRep.colorAt can return a
        // calibrated-RGB NSColor for an sRGB bitmap, producing a false gamma shift.
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        func pixel(x: Int, y: Int) -> NSColor {
            let offset = (y * width + x) * 4
            return NSColor(srgbRed: Double(pixels[offset]) / 255,
                           green: Double(pixels[offset + 1]) / 255,
                           blue: Double(pixels[offset + 2]) / 255, alpha: 1)
        }
        let renderedFill = pixel(x: 5, y: 5)
        #expect(contrast(renderedFill, color.readableInkColor) >= 4.5)
        var visibleInkPixels = 0
        var fillPixels = 0
        // Exclude the badge edge, so surrounding page text cannot pass this assertion.
        for y in 4..<(height - 4) {
            for x in 4..<(width - 4) {
                let rgb = pixel(x: x, y: y)
                let values = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
                if color.usesDarkInk ? values.allSatisfy({ $0 < 0.15 }) : values.allSatisfy({ $0 > 0.85 }) {
                    visibleInkPixels += 1
                }
                if abs(rgb.redComponent - renderedFill.redComponent) < 0.02 && abs(rgb.greenComponent - renderedFill.greenComponent) < 0.02 && abs(rgb.blueComponent - renderedFill.blueComponent) < 0.02 {
                    fillPixels += 1
                }
            }
        }
        #expect(visibleInkPixels >= 20, "The badge glyph must be visibly rendered in contrasting ink, including in flattened output.")
        #expect(fillPixels >= 500, "The badge background must also be rendered; an empty badge is not readable ink.")
    }
}
