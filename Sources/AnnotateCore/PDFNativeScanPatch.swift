import CoreGraphics
import Foundation
import ImageIO

/// Explicit scan editing changes the original image data, never a newly rasterized PDF page.
/// Only flat-background, independently identifiable image regions are accepted.
@MainActor
enum PDFNativeScanPatch {
    static func prepare(program: PDFNativeTextProgram, region: CGRect, graph: PDFNativeObjectGraph) throws {
        let selected = program.glyphs.filter(\.selected)
        guard !selected.isEmpty, selected.allSatisfy(\.invisible) else { throw PDFNativeTextError.unsupported("Scan editing requires a selection entirely within an invisible OCR text layer.") }
        let candidates = program.allImages.filter { $0.bounds.intersects(region) }
        guard candidates.count == 1, let image = candidates.first, image.bounds.insetBy(dx: -0.01, dy: -0.01).contains(region) else {
            throw PDFNativeTextError.unsupported("The OCR selection does not lie inside one unambiguous source image.")
        }
        let matrix = image.transform, determinant = matrix.a * matrix.d - matrix.b * matrix.c
        let aligned = (abs(matrix.b) < 0.000001 && abs(matrix.c) < 0.000001)
            || (abs(matrix.a) < 0.000001 && abs(matrix.d) < 0.000001)
        guard aligned, determinant.isFinite, abs(determinant) > 0.000001 else { throw PDFNativeTextError.unsupported("This scan uses a skewed or unsupported image transform.") }
        guard !program.glyphs.contains(where: { glyph in
            guard !glyph.selected, !glyph.glyph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            let overlap = glyph.bounds.intersection(region)
            return !overlap.isNull && overlap.width > 0.75 && overlap.height > glyph.bounds.height * 0.35
        }) else { throw PDFNativeTextError.unsupported("The selected scan area overlaps neighboring text. Select a complete word or line more precisely.") }
        guard let dictionary = CGPDFStreamGetDictionary(image.stream) else { throw PDFNativeTextError.cannotWrite }
        let decoded = try decode(image.stream, dictionary: dictionary)
        let width = decoded.width, height = decoded.height
        guard width <= 32_768, height <= 32_768, width * height <= 80_000_000 else { throw PDFNativeTextError.unsupported("The source scan exceeds the safe pixel-editing limit.") }
        let unit = region.applying(matrix.inverted())
        let pixel = CGRect(x: unit.minX * Double(width), y: (1 - unit.maxY) * Double(height), width: unit.width * Double(width), height: unit.height * Double(height)).integral.insetBy(dx: -1, dy: -1)
        guard pixel.minX >= 3, pixel.minY >= 3, pixel.maxX <= Double(width - 3), pixel.maxY <= Double(height - 3) else {
            throw PDFNativeTextError.unsupported("The selected text is too close to the image edge to verify its paper background.")
        }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setBlendMode(.copy); context.interpolationQuality = .none
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw PDFNativeTextError.cannotWrite }
        let x0 = Int(pixel.minX), x1 = Int(pixel.maxX), y0 = Int(pixel.minY), y1 = Int(pixel.maxY)
        var samples: [[UInt8]] = [[], [], []]
        for y in (y0 - 2)..<(y1 + 2) {
            for x in (x0 - 2)..<(x1 + 2) where x < x0 || x >= x1 || y < y0 || y >= y1 {
                let offset = (y * width + x) * 4
                for channel in 0..<3 { samples[channel].append(rgba[offset + channel]) }
            }
        }
        let background = samples.map { $0.sorted()[$0.count / 2] }
        guard samples.enumerated().allSatisfy({ channel, values in values.allSatisfy { abs(Int($0) - Int(background[channel])) <= 14 } }) else {
            throw PDFNativeTextError.unsupported("The scan has a patterned or uneven background around this text. The original background cannot be recovered safely.")
        }
        // Reject colorful non-text artwork within the selected patch instead of erasing it as ink.
        for y in y0..<y1 {
            for x in x0..<x1 {
                let offset = (y * width + x) * 4
                let values = (0..<3).map { Int(rgba[offset + $0]) }
                let isBackground = (0..<3).allSatisfy { abs(values[$0] - Int(background[$0])) <= 18 }
                guard isBackground || (values.max()! - values.min()! <= 40) else {
                    throw PDFNativeTextError.unsupported("The selected scan pixels contain colored artwork that cannot be separated safely from the text.")
                }
                for channel in 0..<3 { rgba[offset + channel] = background[channel] }
                rgba[offset + 3] = 255
            }
        }
        var rgb = Data(count: width * height * 3)
        rgb.withUnsafeMutableBytes { output in
            guard let bytes = output.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for pixel in 0..<(width * height) { for channel in 0..<3 { bytes[pixel * 3 + channel] = rgba[pixel * 4 + channel] } }
        }
        var properties: [String: PDFNativeValue] = ["Type": .name("XObject"), "Subtype": .name("Image"), "Width": .integer(width), "Height": .integer(height), "ColorSpace": .name("DeviceRGB"), "BitsPerComponent": .integer(8)]
        var interpolation: CGPDFBoolean = 0
        if CGPDFDictionaryGetBoolean(dictionary, "Interpolate", &interpolation) { properties["Interpolate"] = .boolean(interpolation != 0) }
        image.replacement = try graph.appendStream(data: rgb, dictionary: properties)
    }

    private static func decode(_ stream: CGPDFStreamRef, dictionary: CGPDFDictionaryRef) throws -> CGImage {
        for key in ["SMask", "Mask", "Alternates", "OPI", "SMaskInData"] {
            var object: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(dictionary, key, &object) { throw PDFNativeTextError.unsupported("This source image has a mask or alternate representation that scan editing cannot preserve.") }
        }
        var isMask: CGPDFBoolean = 0
        if CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &isMask), isMask != 0 { throw PDFNativeTextError.unsupported("Image masks cannot be edited as paper scans.") }
        let colorSpace = try space(dictionary)
        guard nativeStreamExpansionIsBounded(stream) else { throw PDFNativeTextError.unsupported("The scan image is compressed more than once, which can't be decoded safely.") }
        var format = CGPDFDataFormat.raw
        guard let bytes = CGPDFStreamCopyData(stream, &format) else { throw PDFNativeTextError.cannotWrite }
        if format == .jpegEncoded || format == .JPEG2000 {
            guard nativeArray(dictionary, "Decode") == nil,
                  let source = CGImageSourceCreateWithData(bytes, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw PDFNativeTextError.unsupported("The encoded scan cannot be decoded without changing its color interpretation.")
            }
            return image
        }
        guard format == .raw, nativeArray(dictionary, "Decode") == nil,
              let w = nativeNumber(dictionary, "Width"), let h = nativeNumber(dictionary, "Height"),
              w >= 1, h >= 1, w <= 32_768, h <= 32_768,
              let bits = nativeNumber(dictionary, "BitsPerComponent"), bits == 8 || (bits == 1 && colorSpace.numberOfComponents == 1) else {
            throw PDFNativeTextError.unsupported("The scan's raw pixel encoding is not supported by this editor.")
        }
        let width = Int(w), height = Int(h), depth = Int(bits), components = colorSpace.numberOfComponents
        let rowBytes = (width * components * depth + 7) / 8
        guard width * height <= 80_000_000, CFDataGetLength(bytes) == rowBytes * height,
              let provider = CGDataProvider(data: bytes), let image = CGImage(width: width, height: height, bitsPerComponent: depth,
                bitsPerPixel: depth * components, bytesPerRow: rowBytes, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw PDFNativeTextError.unsupported("The decoded scan pixels do not match the declared image dimensions.") }
        return image
    }

    private static func space(_ dictionary: CGPDFDictionaryRef) throws -> CGColorSpace {
        if let name = nativeName(dictionary, "ColorSpace") {
            if name == "DeviceRGB" { return CGColorSpaceCreateDeviceRGB() }
            if name == "DeviceGray" { return CGColorSpaceCreateDeviceGray() }
        }
        if let array = nativeArray(dictionary, "ColorSpace") {
            var name: UnsafePointer<CChar>?, profile: CGPDFStreamRef?
            if CGPDFArrayGetName(array, 0, &name), let name, String(cString: name) == "ICCBased",
               CGPDFArrayGetStream(array, 1, &profile), let profile,
               let space = CGColorSpace(iccData: try nativeDecodedStream(profile) as CFData), [1, 3].contains(space.numberOfComponents) { return space }
        }
        throw PDFNativeTextError.unsupported("Scan pixel editing supports RGB and grayscale images with device or ICC color spaces.")
    }
}
