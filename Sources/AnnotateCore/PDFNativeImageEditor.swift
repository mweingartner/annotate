import CoreGraphics
import CryptoKit
import Foundation
import PDFKit

public struct PDFNativeImage: Identifiable, Equatable {
    public let id: String
    public let pageIndex: Int
    public let bounds: CGRect
    public let pixelSize: CGSize
    public let canTransform: Bool
    public let unsupportedReason: String?
    fileprivate let fingerprint: Data
}

public enum PDFNativeImageError: LocalizedError, Equatable {
    case permission, invalidImage, staleSelection, invalidBounds, cannotWrite
    case unsupported(String)
    public var errorDescription: String? {
        switch self {
        case .permission: "This PDF does not permit changing or copying its original images."
        case .invalidImage: "The selected image or replacement pixels are invalid."
        case .staleSelection: "The source image changed. Select it again before applying this edit."
        case .invalidBounds: "Keep the image within the page and use a positive, finite width and height."
        case .cannotWrite: "The image edit could not be written and reopened."
        case .unsupported(let reason): reason
        }
    }
}

/// Edits individual image Do invocations in original PDF content. Shared image and
/// Form resources are copied only along the changed invocation's resource path.
@MainActor
public enum PDFNativeImageEditor {
    public static func images(in document: PDFDocument, pageIndex: Int) throws -> [PDFNativeImage] {
        let context = try Context(document, pageIndex: pageIndex)
        return try context.program.allImages.map { try descriptor($0, pageIndex: pageIndex, graph: context.graph, budget: context.hashBudget) }
    }

    /// A preview of the image's page area, including any artwork overlapping it.
    public static func preview(in document: PDFDocument, image: PDFNativeImage, maximumDimension: Double = 320) throws -> CGImage {
        let context = try Context(document, pageIndex: image.pageIndex)
        _ = try checkedNode(image, context: context)
        let bounds = image.bounds
        guard maximumDimension.isFinite, (16...2048).contains(maximumDimension), bounds.width > 0, bounds.height > 0 else { throw PDFNativeImageError.invalidImage }
        let scale = maximumDimension / max(bounds.width, bounds.height)
        let width = max(1, Int(ceil(bounds.width * scale))), height = max(1, Int(ceil(bounds.height * scale)))
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PDFNativeImageError.invalidImage }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.scaleBy(x: scale, y: scale); bitmap.translateBy(x: -bounds.minX, y: -bounds.minY)
        bitmap.drawPDFPage(context.page)
        guard let result = bitmap.makeImage() else { throw PDFNativeImageError.invalidImage }
        return result
    }

    public static func update(in document: PDFDocument, image: PDFNativeImage, bounds: CGRect? = nil,
                              replacement: CGImage? = nil) throws -> PDFDocument {
        let context = try Context(document, pageIndex: image.pageIndex)
        let node = try checkedNode(image, context: context)
        let destination = bounds ?? image.bounds
        guard MarkerCodec.finite(destination), destination.width > 0, destination.height > 0 else { throw PDFNativeImageError.invalidBounds }
        let moving = destination != image.bounds
        if moving {
            guard destination.width >= 1, destination.height >= 1, let page = document.page(at: image.pageIndex),
                  page.bounds(for: .cropBox).contains(destination) else { throw PDFNativeImageError.invalidBounds }
            guard node.transformReason == nil else { throw PDFNativeImageError.unsupported(node.transformReason!) }
            guard node.formClips.allSatisfy({ $0.insetBy(dx: -0.001, dy: -0.001).contains(destination) }) else {
                throw PDFNativeImageError.unsupported("The image is inside a clipped PDF form. Keep its new bounds inside that form.")
            }
        }
        let reference = try replacement.map { try replacementStream($0, graph: context.graph) } ?? context.graph.importStream(node.stream)
        var adjustment: CGAffineTransform?
        if moving {
            // Page transform S maps the old image rectangle to the requested one.
            // At this Do the existing CTM is M. Inject M^-1 S M in PDF order,
            // so the resulting image placement is S M and neighbors keep M.
            let pageChange = CGAffineTransform(translationX: -image.bounds.minX, y: -image.bounds.minY)
                .concatenating(CGAffineTransform(scaleX: destination.width / image.bounds.width, y: destination.height / image.bounds.height))
                .concatenating(CGAffineTransform(translationX: destination.minX, y: destination.minY))
            adjustment = node.transform.concatenating(pageChange).concatenating(node.transform.inverted())
        }
        return try context.write(path: node.path, edit: .draw(reference, adjustment), original: document)
    }

    public static func remove(in document: PDFDocument, image: PDFNativeImage) throws -> PDFDocument {
        let context = try Context(document, pageIndex: image.pageIndex)
        let node = try checkedNode(image, context: context)
        return try context.write(path: node.path, edit: .remove, original: document)
    }

    private static func descriptor(_ node: ImageNode, pageIndex: Int, graph: PDFNativeObjectGraph, budget: HashBudget) throws -> PDFNativeImage {
        PDFNativeImage(id: "\(pageIndex):" + node.path.map(String.init).joined(separator: "."), pageIndex: pageIndex,
                       bounds: node.bounds, pixelSize: node.pixelSize, canTransform: node.transformReason == nil,
                       unsupportedReason: node.transformReason, fingerprint: try fingerprint(node, graph: graph, budget: budget))
    }

    private static func checkedNode(_ image: PDFNativeImage, context: Context) throws -> ImageNode {
        guard let node = context.program.allImages.first(where: { "\(image.pageIndex):" + $0.path.map(String.init).joined(separator: ".") == image.id }),
              try fingerprint(node, graph: context.graph, budget: context.hashBudget) == image.fingerprint else { throw PDFNativeImageError.staleSelection }
        return node
    }

    private static func fingerprint(_ node: ImageNode, graph: PDFNativeObjectGraph, budget: HashBudget) throws -> Data {
        var hash = SHA256()
        try budget.consume(bytes: node.content.count)
        hash.update(data: node.content)
        hash.update(data: Data([node.transform.a, node.transform.b, node.transform.c, node.transform.d, node.transform.tx, node.transform.ty].map(nativePDFNumber).joined(separator: " ").utf8))
        var references: [Int: Int] = [:]
        func append(_ value: PDFNativeValue, depth: Int = 0) throws {
            guard depth < 48 else { throw PDFNativeImageError.unsupported("The image resource contains an unsupported cycle or nesting depth.") }
            try budget.consume(bytes: 0)
            func tag(_ string: String) throws { let bytes = Data(string.utf8); try budget.consume(bytes: bytes.count); hash.update(data: bytes) }
            switch value {
            case .null: try tag("null;")
            case .boolean(let value): try tag(value ? "true;" : "false;")
            case .integer(let value): try tag("i\(value);")
            case .number(let value): try tag("n\(nativePDFNumber(value));")
            case .name(let value): try tag("name\(value.utf8.count):\(value);")
            case .string(let bytes): try tag("string\(bytes.count):"); try budget.consume(bytes: bytes.count); hash.update(data: bytes)
            case .array(let values): try tag("["); for item in values { try append(item, depth: depth + 1) }; try tag("]")
            case .dictionary(let values):
                try tag("<<"); for key in values.keys.sorted() { try tag("\(key.utf8.count):\(key)"); try append(values[key]!, depth: depth + 1) }; try tag(">>")
            case .stream(let dictionary, let data): try append(.dictionary(dictionary), depth: depth + 1); try tag("stream\(data.count):"); try budget.consume(bytes: data.count); hash.update(data: data)
            case .reference(let id):
                if let known = references[id] { try tag("ref\(known);") }
                else { references[id] = references.count; try tag("object\(references[id]!){"); try append(graph.resolved(value), depth: depth + 1); try tag("}") }
            }
        }
        try append(graph.importStream(node.stream))
        return Data(hash.finalize())
    }

    private final class HashBudget {
        var nodes = 0, bytes = 0
        func consume(bytes count: Int) throws {
            nodes += 1
            guard nodes <= 100_000, count <= 256 * 1_024 * 1_024 - bytes else { throw PDFNativeImageError.unsupported("The image resources exceed the safe fingerprinting limit.") }
            bytes += count
        }
    }

    private final class ProgramBudget {
        var instances = 0, operations = 0, bytes = 0, images = 0
        func begin(bytes count: Int) throws {
            instances += 1
            guard instances <= 2_000, count <= 128 * 1_024 * 1_024 - bytes else { throw PDFNativeImageError.unsupported("The page exceeds the safe image/form expansion limit.") }
            bytes += count
        }
        func add(operations count: Int) throws {
            operations += count
            guard operations <= 250_000 else { throw PDFNativeImageError.unsupported("The page exceeds the safe image operation limit.") }
        }
        func image() throws {
            images += 1
            guard images <= 2_000 else { throw PDFNativeImageError.unsupported("The page exceeds the safe image count limit.") }
        }
    }

    private static func replacementStream(_ image: CGImage, graph: PDFNativeObjectGraph) throws -> PDFNativeValue {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 16_384, height <= 16_384, width * height <= 40_000_000 else { throw PDFNativeImageError.invalidImage }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setBlendMode(.copy); context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        guard drawn else { throw PDFNativeImageError.invalidImage }
        var rgb = Data(count: width * height * 3), alpha = Data(count: width * height), hasAlpha = false
        rgb.withUnsafeMutableBytes { rgbBuffer in
            alpha.withUnsafeMutableBytes { alphaBuffer in
                let colors = rgbBuffer.bindMemory(to: UInt8.self), masks = alphaBuffer.bindMemory(to: UInt8.self)
                for pixel in 0..<(width * height) {
                    let opacity = Int(rgba[pixel * 4 + 3]); masks[pixel] = UInt8(opacity); hasAlpha = hasAlpha || opacity != 255
                    for channel in 0..<3 { colors[pixel * 3 + channel] = opacity == 0 ? 0 : UInt8(min(255, (Int(rgba[pixel * 4 + channel]) * 255 + opacity / 2) / opacity)) }
                }
            }
        }
        var properties: [String: PDFNativeValue] = ["Type": .name("XObject"), "Subtype": .name("Image"), "Width": .integer(width), "Height": .integer(height), "ColorSpace": .name("DeviceRGB"), "BitsPerComponent": .integer(8)]
        if hasAlpha {
            properties["SMask"] = try graph.appendStream(data: alpha, dictionary: ["Type": .name("XObject"), "Subtype": .name("Image"), "Width": .integer(width), "Height": .integer(height), "ColorSpace": .name("DeviceGray"), "BitsPerComponent": .integer(8)])
        }
        return try graph.appendStream(data: rgb, dictionary: properties)
    }

    @MainActor private struct Context {
        let pageIndex: Int
        let page: CGPDFPage
        let graph: PDFNativeObjectGraph
        let program: ImageProgram
        let pageID: Int
        let hashBudget = HashBudget()
        init(_ document: PDFDocument, pageIndex: Int) throws {
            guard !document.isLocked, document.allowsCopying, document.allowsDocumentChanges else { throw PDFNativeImageError.permission }
            guard !document.isEncrypted else { throw PDFNativeImageError.unsupported("Native image editing cannot preserve this PDF's encryption. Use an explicitly unencrypted working copy.") }
            guard pageIndex >= 0, pageIndex < document.pageCount, let data = document.dataRepresentation(), let provider = CGDataProvider(data: data as CFData),
                  let source = CGPDFDocument(provider), let page = source.page(at: pageIndex + 1), let dictionary = page.dictionary else { throw PDFNativeImageError.invalidImage }
            let graph = try PDFNativeObjectGraph(document: source)
            guard let pageID = graph.objectID(for: dictionary) else { throw PDFNativeImageError.cannotWrite }
            self.pageIndex = pageIndex; self.page = page; self.graph = graph; self.pageID = pageID
            program = try ImageProgram(data: content(dictionary), resources: PDFNativeTextEditor.inheritedResources(dictionary))
        }
        func write(path: [Int], edit: ImageEdit, original: PDFDocument) throws -> PDFDocument {
            let (data, resources) = try program.rewritten(path: path, edit: edit, graph: graph)
            guard case .dictionary(var values)? = graph[pageID] else { throw PDFNativeImageError.cannotWrite }
            values["Contents"] = try graph.appendStream(data: data, dictionary: [:]); values["Resources"] = .dictionary(resources)
            graph[pageID] = .dictionary(values)
            guard let result = PDFDocument(data: try graph.write()), result.pageCount == original.pageCount,
                  result.page(at: pageIndex)?.rotation == original.page(at: pageIndex)?.rotation,
                  result.page(at: pageIndex)?.bounds(for: .cropBox) == original.page(at: pageIndex)?.bounds(for: .cropBox) else { throw PDFNativeImageError.cannotWrite }
            return result
        }
    }

    private static func content(_ dictionary: CGPDFDictionaryRef) throws -> Data {
        if let stream = nativeStream(dictionary, "Contents") { return try nativeDecodedStream(stream) }
        guard let array = nativeArray(dictionary, "Contents") else { return Data() }
        var result = Data()
        for index in 0..<CGPDFArrayGetCount(array) {
            var stream: CGPDFStreamRef?
            guard CGPDFArrayGetStream(array, index, &stream), let stream else { throw PDFNativeImageError.cannotWrite }
            result.append(try nativeDecodedStream(stream)); result.append(10)
        }
        return result
    }

    private enum ImageEdit { case remove, draw(PDFNativeValue, CGAffineTransform?) }
    private struct ImageNode {
        let path: [Int]
        let stream: CGPDFStreamRef
        let transform: CGAffineTransform
        let pixelSize: CGSize
        let customClip: Bool
        let formClips: [CGRect]
        let content: Data
        var bounds: CGRect { CGRect(x: 0, y: 0, width: 1, height: 1).applying(transform) }
        var transformReason: String? {
            let determinant = transform.a * transform.d - transform.b * transform.c
            guard determinant.isFinite, abs(determinant) > 0.000000001 else { return "The source image has a singular transform and cannot be moved or resized." }
            let aligned = (abs(transform.b) < 0.000001 && abs(transform.c) < 0.000001) || (abs(transform.a) < 0.000001 && abs(transform.d) < 0.000001)
            if !aligned { return "This image uses a skewed or oblique transform. Replace or delete it at its existing position." }
            if customClip { return "This image is constrained by a custom clipping path. Replace or delete it at its existing position." }
            return nil
        }
    }

    @MainActor private final class ImageProgram {
        let data: Data
        let resources: CGPDFDictionaryRef?
        let stream: CGPDFStreamRef?
        let operations: [PDFNativeOperation]
        var images: [Int: ImageNode] = [:]
        var forms: [Int: ImageProgram] = [:]
        var allImages: [ImageNode] { operations.indices.flatMap { index in images[index].map { [$0] } ?? forms[index]?.allImages ?? [] } }

        init(data: Data, resources: CGPDFDictionaryRef?, stream: CGPDFStreamRef? = nil, path: [Int] = [], budget: ProgramBudget = ProgramBudget(),
             transform: CGAffineTransform = .identity, customClip: Bool = false, formClips: [CGRect] = [], ancestors: Set<UInt> = []) throws {
            guard path.count < 24, data.count <= 64 * 1_024 * 1_024 else { throw PDFNativeImageError.unsupported("The image content exceeds safe editing limits.") }
            try budget.begin(bytes: data.count)
            self.data = data; self.resources = resources; self.stream = stream
            var lexer = PDFNativeLexer(data)
            do { operations = try lexer.operations() }
            catch { throw PDFNativeImageError.unsupported("This page's content cannot be parsed for image editing. Inline images and malformed content are not supported.") }
            try budget.add(operations: operations.count)
            var matrix = transform, clipped = customClip, stack: [(CGAffineTransform, Bool)] = []
            for (index, operation) in operations.enumerated() {
                switch operation.name {
                case "q": stack.append((matrix, clipped))
                case "Q": guard let prior = stack.popLast() else { throw PDFNativeImageError.unsupported("The PDF has unbalanced graphics state.") }; (matrix, clipped) = prior
                case "cm": matrix = try Self.matrix(operation.operands).concatenating(matrix)
                case "W", "W*": clipped = true
                case "Tr": if let mode = operation.operands.first?.number, mode >= 4 { clipped = true }
                case "Do":
                    guard let name = operation.operands.first?.name, let resources, let objects = nativeDictionary(resources, "XObject"), let child = nativeStream(objects, name), let dictionary = CGPDFStreamGetDictionary(child) else { throw PDFNativeImageError.unsupported("The PDF references a missing image or form resource.") }
                    if nativeName(dictionary, "Subtype") == "Image" {
                        try budget.image()
                        guard let width = nativeNumber(dictionary, "Width"), let height = nativeNumber(dictionary, "Height"), width > 0, height > 0,
                              MarkerCodec.finite(CGRect(x: 0, y: 0, width: 1, height: 1).applying(matrix)) else { throw PDFNativeImageError.invalidImage }
                        images[index] = ImageNode(path: path + [index], stream: child, transform: matrix, pixelSize: CGSize(width: width, height: height), customClip: clipped, formClips: formClips, content: data)
                    } else if nativeName(dictionary, "Subtype") == "Form" {
                        let key = UInt(bitPattern: child.rawValue)
                        guard !ancestors.contains(key) else { throw PDFNativeImageError.unsupported("A recursive PDF form cannot be edited safely.") }
                        var next = matrix
                        if let array = nativeArray(dictionary, "Matrix") { next = try Self.arrayMatrix(array).concatenating(matrix) }
                        var clips = formClips
                        if let box = nativeArray(dictionary, "BBox") {
                            let values = try Self.numbers(box, count: 4)
                            clips.append(CGRect(x: values[0], y: values[1], width: values[2] - values[0], height: values[3] - values[1]).applying(next))
                        }
                        forms[index] = try ImageProgram(data: nativeDecodedStream(child), resources: nativeDictionary(dictionary, "Resources") ?? resources,
                                                       stream: child, path: path + [index], budget: budget, transform: next, customClip: clipped, formClips: clips, ancestors: ancestors.union([key]))
                    }
                default: break
                }
            }
            guard stack.isEmpty else { throw PDFNativeImageError.unsupported("The PDF has unbalanced graphics state.") }
        }

        @MainActor func rewritten(path: [Int], edit: ImageEdit, graph: PDFNativeObjectGraph) throws -> (Data, [String: PDFNativeValue]) {
            guard let index = path.first, operations.indices.contains(index), let oldName = operations[index].operands.first?.name else { throw PDFNativeImageError.staleSelection }
            var values: [String: PDFNativeValue] = [:]
            if let resources, case .dictionary(let imported) = try graph.resolved(graph.importDictionary(resources)) { values = imported }
            var objects: [String: PDFNativeValue] = [:]
            if let existing = values["XObject"], case .dictionary(let imported) = try graph.resolved(existing) { objects = imported }
            var replacement = ""
            var reference: PDFNativeValue?, adjustment: CGAffineTransform?
            if path.count > 1 {
                guard let form = forms[index], let stream = form.stream,
                      case .stream(var dictionary, _) = try graph.resolved(graph.importStream(stream)) else { throw PDFNativeImageError.staleSelection }
                let (bytes, resources) = try form.rewritten(path: Array(path.dropFirst()), edit: edit, graph: graph)
                dictionary["Resources"] = .dictionary(resources); dictionary.removeValue(forKey: "Filter"); dictionary.removeValue(forKey: "DecodeParms"); dictionary.removeValue(forKey: "Length")
                reference = try graph.appendStream(data: bytes, dictionary: dictionary)
            } else {
                guard images[index] != nil else { throw PDFNativeImageError.staleSelection }
                if case .draw(let newReference, let newAdjustment) = edit { reference = newReference; adjustment = newAdjustment }
            }
            if let reference {
                var name = "AnnotateEditedImage\(index)"
                while objects[name] != nil { name += "x" }
                objects[name] = reference
                replacement = "/\(name) Do"
                if let matrix = adjustment {
                    replacement = "q " + [matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty].map(nativePDFNumber).joined(separator: " ") + " cm " + replacement + " Q"
                }
            }
            // A Form without its own Resources can still resolve names from this
            // dictionary. Keep a name used by such an unchanged descendant.
            let inheritedUse = forms.contains { other, form in
                guard other != index, let stream = form.stream, let dictionary = CGPDFStreamGetDictionary(stream), nativeDictionary(dictionary, "Resources") == nil else { return false }
                return form.usesInheritedName(oldName)
            }
            if !inheritedUse, !operations.enumerated().contains(where: { other, operation in other != index && operation.name == "Do" && operation.operands.first?.name == oldName }) { objects.removeValue(forKey: oldName) }
            values["XObject"] = .dictionary(objects)
            let operation = operations[index], bytes = Array(data)
            var result = Data(bytes[..<operation.range.lowerBound]); result.append(Data(replacement.utf8)); result.append(contentsOf: bytes[operation.range.upperBound...])
            return (result, values)
        }

        private static func matrix(_ operands: [PDFNativeToken]) throws -> CGAffineTransform {
            let values = operands.compactMap(\.number)
            guard values.count == 6 else { throw PDFNativeImageError.unsupported("The image has a malformed transformation.") }
            return CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
        }
        private static func numbers(_ array: CGPDFArrayRef, count: Int) throws -> [Double] {
            guard CGPDFArrayGetCount(array) == count else { throw PDFNativeImageError.invalidImage }
            return try (0..<count).map { index in var number: CGPDFReal = 0; guard CGPDFArrayGetNumber(array, index, &number), number.isFinite else { throw PDFNativeImageError.invalidImage }; return number }
        }
        private static func arrayMatrix(_ array: CGPDFArrayRef) throws -> CGAffineTransform {
            try matrix(numbers(array, count: 6).map(PDFNativeToken.number))
        }
        private func usesInheritedName(_ name: String) -> Bool {
            operations.contains { $0.name == "Do" && $0.operands.first?.name == name } || forms.values.contains { form in
                guard let stream = form.stream, let dictionary = CGPDFStreamGetDictionary(stream), nativeDictionary(dictionary, "Resources") == nil else { return false }
                return form.usesInheritedName(name)
            }
        }
    }
}
