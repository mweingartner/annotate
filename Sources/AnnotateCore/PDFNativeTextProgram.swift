import CoreGraphics
import Foundation

struct PDFNativeInsertion {
    let target: PDFNativeTextProgram
    let after: Int
    let transform: CGAffineTransform
    let reference: PDFNativeValue
}

final class PDFNativeImagePlacement {
    let stream: CGPDFStreamRef
    let transform: CGAffineTransform
    var replacement: PDFNativeValue?
    init(stream: CGPDFStreamRef, transform: CGAffineTransform) { self.stream = stream; self.transform = transform }
    var bounds: CGRect { CGRect(x: 0, y: 0, width: 1, height: 1).applying(transform) }
}

final class PDFNativeGlyphPlacement {
    let glyph: PDFNativeGlyph
    let bounds: CGRect
    let compensation: Double
    let clipping: Bool
    let invisible: Bool
    let fontBaseName: String
    let fontSize: Double
    let fillColor: CGColor?
    /// The pen position on the baseline where this glyph is drawn, in page space.
    let origin: CGPoint
    /// How far the pen moves after this glyph (its width plus character and word
    /// spacing), in page space.
    let advance: Double
    /// Character spacing (Tc) in page-space points.
    let characterSpacing: Double
    /// Whether the glyph is set upright on a horizontal baseline (no rotation or skew).
    let upright: Bool
    var selected = false
    init(glyph: PDFNativeGlyph, bounds: CGRect, compensation: Double, clipping: Bool, invisible: Bool, fontBaseName: String, fontSize: Double,
         fillColor: CGColor?, origin: CGPoint = .zero, advance: Double = 0, characterSpacing: Double = 0, upright: Bool = false) {
        self.glyph = glyph; self.bounds = bounds; self.compensation = compensation; self.clipping = clipping; self.invisible = invisible
        self.fontBaseName = fontBaseName; self.fontSize = fontSize
        self.fillColor = fillColor
        self.origin = origin; self.advance = advance; self.characterSpacing = characterSpacing; self.upright = upright
    }
}

final class PDFNativeTextProgram {
    struct State {
        var ctm = CGAffineTransform.identity
        var matrix = CGAffineTransform.identity
        var lineMatrix = CGAffineTransform.identity
        var font: PDFNativeFont?
        var fontSize = 0.0
        var characterSpace = 0.0
        var wordSpace = 0.0
        var horizontalScale = 1.0
        var leading = 0.0
        var rise = 0.0
        var renderingMode = 0
        var fillColor: CGColor? = CGColor(gray: 0, alpha: 1)
        var fillColorSpace: CGColorSpace? = CGColorSpaceCreateDeviceGray()
        var fillAlpha = 1.0
        mutating func advance(_ width: Double) { matrix = CGAffineTransform(translationX: width, y: 0).concatenating(matrix) }
        mutating func nextLine(_ x: Double = 0, _ y: Double? = nil) {
            lineMatrix = CGAffineTransform(translationX: x, y: y ?? -leading).concatenating(lineMatrix); matrix = lineMatrix
        }
    }
    enum Piece { case glyph(PDFNativeGlyphPlacement), adjustment(Double) }
    let data: Data
    let operations: [PDFNativeOperation]
    let resources: CGPDFDictionaryRef?
    let sourceStream: CGPDFStreamRef?
    var shows: [Int: [Piece]] = [:]
    var forms: [Int: PDFNativeTextProgram] = [:]
    var images: [Int: PDFNativeImagePlacement] = [:]
    var glyphs: [PDFNativeGlyphPlacement] = []
    /// Font descriptor flags by base name, for choosing a like substitute.
    var fontFlags: [String: Int] = [:]
    /// Page-space bounds of each form XObject's box, by the index of its Do operator.
    var formBounds: [Int: CGRect] = [:]
    var markedActualText = false
    private var textEnds: [Int: (Int, CGAffineTransform)] = [:]
    var endState: State

    init(data: Data, resources: CGPDFDictionaryRef?, state initial: State = State(), sourceStream: CGPDFStreamRef? = nil,
         ancestors: Set<UInt> = [], depth: Int = 0) throws {
        guard depth < 24 else { throw PDFNativeTextError.unsupported("The page's nested form depth exceeds the editing limit.") }
        self.data = data; self.resources = resources; self.sourceStream = sourceStream
        var lexer = PDFNativeLexer(data)
        operations = try lexer.operations()
        var state = initial, stack: [State] = [], activeTextShows: [Int]? = nil
        for (index, operation) in operations.enumerated() {
            let args = operation.operands
            func number(_ offset: Int) throws -> Double {
                guard args.indices.contains(offset), let value = args[offset].number else { throw PDFNativeTextError.malformed("Invalid operand for \(operation.name).") }; return value
            }
            switch operation.name {
            case "q": stack.append(state)
            case "Q": guard let prior = stack.popLast() else { throw PDFNativeTextError.malformed("Unbalanced graphics state.") }; state = prior
            case "cm": state.ctm = try CGAffineTransform(a: number(0), b: number(1), c: number(2), d: number(3), tx: number(4), ty: number(5)).concatenating(state.ctm)
            case "g": state.fillColorSpace = CGColorSpaceCreateDeviceGray(); state.fillColor = try CGColor(gray: number(0), alpha: 1)
            case "rg": state.fillColorSpace = CGColorSpaceCreateDeviceRGB(); state.fillColor = try CGColor(red: number(0), green: number(1), blue: number(2), alpha: 1)
            case "k": state.fillColorSpace = CGColorSpaceCreateDeviceCMYK(); state.fillColor = try CGColor(colorSpace: CGColorSpaceCreateDeviceCMYK(), components: [number(0), number(1), number(2), number(3), 1])
            case "cs":
                state.fillColorSpace = args.first?.name.flatMap { Self.colorSpace(name: $0, resources: resources) }
                state.fillColor = nil
            case "sc", "scn":
                if let space = state.fillColorSpace, args.count == space.numberOfComponents {
                    state.fillColor = try CGColor(colorSpace: space, components: (0..<args.count).map { CGFloat(try number($0)) } + [1])
                } else { state.fillColor = nil }
            case "BT":
                guard activeTextShows == nil else { throw PDFNativeTextError.malformed("Nested text objects cannot be edited safely.") }
                activeTextShows = []; state.matrix = .identity; state.lineMatrix = .identity
            case "ET":
                guard let active = activeTextShows else { throw PDFNativeTextError.malformed("A text object ends without a beginning.") }
                for show in active { textEnds[show] = (index, state.ctm) }
                activeTextShows = nil
            case "Tf":
                guard let name = args.first?.name, let resources, let fonts = nativeDictionary(resources, "Font"), let font = nativeDictionary(fonts, name) else { throw PDFNativeTextError.unsupported("The PDF references a missing font resource.") }
                state.font = try PDFNativeFont(font); state.fontSize = try number(1)
                if let loaded = state.font { fontFlags[loaded.baseName] = loaded.flags }
            case "Tc": state.characterSpace = try number(0)
            case "Tw": state.wordSpace = try number(0)
            case "Tz": state.horizontalScale = try number(0) / 100
            case "TL": state.leading = try number(0)
            case "Ts": state.rise = try number(0)
            case "Tr":
                let mode = try number(0)
                guard (0...7).contains(mode) else { throw PDFNativeTextError.malformed("Invalid text rendering mode.") }
                state.renderingMode = Int(mode)
            case "Tm": state.matrix = try CGAffineTransform(a: number(0), b: number(1), c: number(2), d: number(3), tx: number(4), ty: number(5)); state.lineMatrix = state.matrix
            case "Td": state.nextLine(try number(0), try number(1))
            case "TD": state.leading = -(try number(1)); state.nextLine(try number(0), try number(1))
            case "T*": state.nextLine()
            case "Tj", "TJ", "'", "\"":
                guard activeTextShows != nil else { throw PDFNativeTextError.malformed("Text is painted outside a text object.") }
                activeTextShows?.append(index)
                if operation.name == "\"" { state.wordSpace = try number(0); state.characterSpace = try number(1) }
                if operation.name == "'" || operation.name == "\"" { state.nextLine() }
                guard let font = state.font else { throw PDFNativeTextError.unsupported("Text appears without a source font.") }
                let values: [PDFNativeToken]
                if operation.name == "TJ" { guard let array = args.first?.array else { throw PDFNativeTextError.malformed("Invalid TJ array.") }; values = array }
                else { guard let text = args.last?.bytes else { throw PDFNativeTextError.malformed("Invalid text-show string.") }; values = [.bytes(text)] }
                var pieces: [Piece] = []
                for value in values {
                    if let amount = value.number {
                        state.advance(-amount / 1000 * state.fontSize * state.horizontalScale); pieces.append(.adjustment(amount))
                    } else if let bytes = value.bytes {
                        for glyph in try font.glyphs(bytes) {
                            let spacing = state.characterSpace + (glyph.wordSpace ? state.wordSpace : 0)
                            let advance = (glyph.width / 1000 * state.fontSize + spacing) * state.horizontalScale
                            let transform = CGAffineTransform(scaleX: state.fontSize * state.horizontalScale, y: state.fontSize)
                                .concatenating(CGAffineTransform(translationX: 0, y: state.rise))
                                .concatenating(state.matrix).concatenating(state.ctm)
                            let bounds = CGRect(x: 0, y: font.descent / 1000, width: max(0.001, glyph.width / 1000), height: max(0.001, (font.ascent - font.descent) / 1000)).applying(transform)
                            let compensation = -(glyph.width + (state.fontSize == 0 ? 0 : spacing / state.fontSize * 1000))
                            guard [bounds.minX, bounds.minY, bounds.width, bounds.height, advance, compensation].allSatisfy(\.isFinite) else { throw PDFNativeTextError.malformed("The text transform contains invalid coordinates.") }
                            // The pen's page-space position and movement, for matching an edit's layout.
                            let pen = state.matrix.concatenating(state.ctm)
                            let penScale = hypot(pen.a, pen.b)
                            let upright = abs(pen.b) < 0.0001 && abs(pen.c) < 0.0001 && pen.a > 0 && pen.d > 0
                            let placement = PDFNativeGlyphPlacement(glyph: glyph, bounds: bounds,
                                compensation: compensation, clipping: state.renderingMode >= 4, invisible: state.renderingMode == 3 || state.fillAlpha == 0,
                                fontBaseName: font.baseName, fontSize: hypot(transform.c, transform.d), fillColor: state.fillColor?.copy(alpha: state.fillAlpha),
                                origin: CGPoint(x: 0, y: state.rise).applying(pen), advance: advance * penScale,
                                characterSpacing: state.characterSpace * state.horizontalScale * penScale, upright: upright)
                            pieces.append(.glyph(placement)); glyphs.append(placement); state.advance(advance)
                            guard glyphs.count <= 250_000 else { throw PDFNativeTextError.unsupported("This page exceeds the safe glyph-editing limit.") }
                        }
                    } else { throw PDFNativeTextError.malformed("TJ contains an invalid element.") }
                }
                shows[index] = pieces
            case "Do":
                guard let name = args.first?.name, let resources, let objects = nativeDictionary(resources, "XObject"), let stream = nativeStream(objects, name), let dictionary = CGPDFStreamGetDictionary(stream) else { continue }
                if nativeName(dictionary, "Subtype") == "Image" { images[index] = PDFNativeImagePlacement(stream: stream, transform: state.ctm); continue }
                guard nativeName(dictionary, "Subtype") == "Form" else { continue }
                let identity = UInt(bitPattern: stream.rawValue)
                guard !ancestors.contains(identity) else { throw PDFNativeTextError.unsupported("The page contains recursively referenced form content.") }
                var nestedState = state
                if let matrix = nativeArray(dictionary, "Matrix"), CGPDFArrayGetCount(matrix) == 6 {
                    let values = (0..<6).compactMap { nativeArrayNumber(matrix, $0) }
                    if values.count == 6 { nestedState.ctm = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5]).concatenating(state.ctm) }
                }
                let nested = try PDFNativeTextProgram(data: nativeDecodedStream(stream), resources: nativeDictionary(dictionary, "Resources") ?? resources,
                    state: nestedState, sourceStream: stream, ancestors: ancestors.union([identity]), depth: depth + 1)
                if let box = nativeArray(dictionary, "BBox"), CGPDFArrayGetCount(box) == 4 {
                    let values = (0..<4).compactMap { nativeArrayNumber(box, $0) }
                    if values.count == 4, values.allSatisfy(\.isFinite) {
                        let rect = CGRect(x: min(values[0], values[2]), y: min(values[1], values[3]),
                                          width: abs(values[2] - values[0]), height: abs(values[3] - values[1]))
                        formBounds[index] = rect.applying(nestedState.ctm)
                    }
                }
                forms[index] = nested; glyphs.append(contentsOf: nested.glyphs)
                fontFlags.merge(nested.fontFlags) { current, _ in current }
                guard glyphs.count <= 250_000 else { throw PDFNativeTextError.unsupported("This page exceeds the safe glyph-editing limit.") }
            case "BDC":
                if args.contains(where: { if case .dictionary(let value) = $0 { return value["ActualText"] != nil }; return false }) { markedActualText = true }
                if let propertyName = args.last?.name, let resources, let properties = nativeDictionary(resources, "Properties"), let property = nativeDictionary(properties, propertyName) {
                    var value: CGPDFObjectRef?; if CGPDFDictionaryGetObject(property, "ActualText", &value) { markedActualText = true }
                }
            case "gs":
                if let name = args.first?.name, let resources, let states = nativeDictionary(resources, "ExtGState"), let dictionary = nativeDictionary(states, name), let alpha = nativeNumber(dictionary, "ca") { state.fillAlpha = min(1, max(0, alpha)) }
                if let name = args.first?.name, let resources, let states = nativeDictionary(resources, "ExtGState"), let dictionary = nativeDictionary(states, name), let fontArray = nativeArray(dictionary, "Font") {
                    var dictionary: CGPDFDictionaryRef?
                    if CGPDFArrayGetDictionary(fontArray, 0, &dictionary), let dictionary { state.font = try PDFNativeFont(dictionary) }
                    if let size = nativeArrayNumber(fontArray, 1) { state.fontSize = size }
                }
            default: break
            }
        }
        guard stack.isEmpty, activeTextShows == nil else { throw PDFNativeTextError.malformed("Unbalanced saved graphics or text state.") }
        endState = state
    }

    private static func colorSpace(name: String, resources: CGPDFDictionaryRef?) -> CGColorSpace? {
        switch name {
        case "DeviceGray": return CGColorSpaceCreateDeviceGray()
        case "DeviceRGB": return CGColorSpaceCreateDeviceRGB()
        case "DeviceCMYK": return CGColorSpaceCreateDeviceCMYK()
        default: break
        }
        guard let resources, let spaces = nativeDictionary(resources, "ColorSpace") else { return nil }
        if let alias = nativeName(spaces, name), alias != name {
            switch alias { case "DeviceGray": return CGColorSpaceCreateDeviceGray(); case "DeviceRGB": return CGColorSpaceCreateDeviceRGB(); case "DeviceCMYK": return CGColorSpaceCreateDeviceCMYK(); default: return nil }
        }
        if let array = nativeArray(spaces, name) {
            var kind: UnsafePointer<CChar>?, profile: CGPDFStreamRef?
            if CGPDFArrayGetName(array, 0, &kind), let kind, String(cString: kind) == "ICCBased", CGPDFArrayGetStream(array, 1, &profile), let profile,
               let data = try? nativeDecodedStream(profile) { return CGColorSpace(iccData: data as CFData) }
        }
        return nil
    }

    var hasChanges: Bool { glyphs.contains(where: \.selected) || images.values.contains(where: { $0.replacement != nil }) || forms.values.contains(where: \.hasChanges) }
    var allImages: [PDFNativeImagePlacement] { Array(images.values) + forms.values.flatMap(\.allImages) }

    func insertion(reference: PDFNativeValue) throws -> PDFNativeInsertion {
        for index in operations.indices {
            if shows[index]?.contains(where: { if case .glyph(let glyph) = $0 { glyph.selected } else { false } }) == true,
               let (end, transform) = textEnds[index] {
                let determinant = transform.a * transform.d - transform.b * transform.c
                guard determinant.isFinite, abs(determinant) > 0.000000001 else { throw PDFNativeTextError.unsupported("The source text has a singular placement transform.") }
                return PDFNativeInsertion(target: self, after: end, transform: transform.inverted(), reference: reference)
            }
            if let form = forms[index], form.glyphs.contains(where: \.selected) { return try form.insertion(reference: reference) }
        }
        throw PDFNativeTextError.sourceMismatch
    }

    @MainActor func rewritten(using graph: PDFNativeObjectGraph, insertion: PDFNativeInsertion? = nil) throws -> (Data, [String: PDFNativeValue]) {
        var replacements: [Int: String] = [:]
        var resourceValues: [String: PDFNativeValue] = [:]
        if let resources, case .dictionary(let values) = try graph.resolved(graph.importDictionary(resources)) { resourceValues = values }
        if let insertion, insertion.target === self {
            var objects: [String: PDFNativeValue] = [:]
            if let existing = resourceValues["XObject"], case .dictionary(let values) = try graph.resolved(existing) { objects = values }
            var name = "AnnotateReplacementText"
            while objects[name] != nil { name += "x" }
            objects[name] = insertion.reference; resourceValues["XObject"] = .dictionary(objects)
            let matrix = insertion.transform
            let values = [matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty].map { nativePDFNumber($0) }.joined(separator: " ")
            replacements[insertion.after] = "ET\nq \(values) cm /\(name) Do Q\n"
        }
        for (index, image) in images {
            guard let reference = image.replacement else { continue }
            var objects: [String: PDFNativeValue] = [:]
            if let existing = resourceValues["XObject"], case .dictionary(let values) = try graph.resolved(existing) { objects = values }
            var name = "AnnotateEditedScan\(index)"
            while objects[name] != nil { name += "x" }
            objects[name] = reference
            if let oldName = operations[index].operands.first?.name,
               !operations.enumerated().contains(where: { other, operation in operation.name == "Do" && operation.operands.first?.name == oldName && images[other]?.replacement == nil }) {
                objects.removeValue(forKey: oldName)
            }
            resourceValues["XObject"] = .dictionary(objects); replacements[index] = "/\(name) Do"
        }
        for (index, pieces) in shows where pieces.contains(where: { if case .glyph(let glyph) = $0 { return glyph.selected }; return false }) {
            var tokens: [String] = [], buffer: [UInt8] = []
            func flush() { if !buffer.isEmpty { tokens.append(nativePDFHex(buffer)); buffer = [] } }
            for piece in pieces {
                switch piece {
                case .glyph(let placement):
                    if placement.selected { flush(); tokens.append(nativePDFNumber(placement.compensation)) }
                    else { buffer.append(contentsOf: placement.glyph.bytes) }
                case .adjustment(let adjustment): flush(); tokens.append(nativePDFNumber(adjustment))
                }
            }
            flush()
            let operation = operations[index]
            var prefix = ""
            if operation.name == "'" { prefix = "T* " }
            if operation.name == "\"" { prefix = "\(nativePDFNumber(operation.operands[0].number ?? 0)) Tw \(nativePDFNumber(operation.operands[1].number ?? 0)) Tc T* " }
            replacements[index] = prefix + "[" + tokens.joined(separator: " ") + "] TJ"
        }
        for (index, form) in forms where form.hasChanges {
            let (data, resources) = try form.rewritten(using: graph, insertion: insertion)
            guard let stream = form.sourceStream, case .stream(var dictionary, _) = try graph.resolved(graph.importStream(stream)) else { throw PDFNativeTextError.malformed("The source form could not be cloned.") }
            dictionary["Resources"] = .dictionary(resources)
            dictionary.removeValue(forKey: "Filter"); dictionary.removeValue(forKey: "DecodeParms"); dictionary.removeValue(forKey: "Length")
            let reference = try graph.appendStream(data: data, dictionary: dictionary)
            var objects: [String: PDFNativeValue] = [:]
            if let existing = resourceValues["XObject"], case .dictionary(let values) = try graph.resolved(existing) { objects = values }
            var name = "AnnotateEditedForm\(index)"
            while objects[name] != nil { name += "x" }
            objects[name] = reference
            if let oldName = operations[index].operands.first?.name,
               !operations.enumerated().contains(where: { otherIndex, operation in
                   operation.name == "Do" && operation.operands.first?.name == oldName && !(forms[otherIndex]?.hasChanges ?? false)
               }) { objects.removeValue(forKey: oldName) }
            resourceValues["XObject"] = .dictionary(objects)
            replacements[index] = "/\(name) Do"
        }
        let source = Array(data)
        var output = Data(), cursor = 0
        for (index, operation) in operations.enumerated() {
            guard let replacement = replacements[index] else { continue }
            output.append(contentsOf: source[cursor..<operation.range.lowerBound]); output.append(Data(replacement.utf8)); cursor = operation.range.upperBound
        }
        output.append(contentsOf: source[cursor...])
        return (output, resourceValues)
    }
}
