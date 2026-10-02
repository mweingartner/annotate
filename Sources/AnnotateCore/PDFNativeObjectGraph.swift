import CoreGraphics
import Foundation

indirect enum PDFNativeValue {
    case null
    case boolean(Bool)
    case integer(Int)
    case number(Double)
    case name(String)
    case string(Data)
    case array([PDFNativeValue])
    case dictionary([String: PDFNativeValue])
    case reference(Int)
    case stream(dictionary: [String: PDFNativeValue], data: Data)
}

enum PDFNativeGraphError: LocalizedError {
    case malformed, resourceLimit, unsupportedStream, encrypted
    var errorDescription: String? {
        switch self {
        case .malformed: "The PDF contains an object that cannot be safely rewritten."
        case .resourceLimit: "This PDF exceeds the native editor's object or memory limits."
        case .unsupportedStream: "This PDF uses a stream encoding that the native editor cannot preserve."
        case .encrypted: "Native content editing cannot preserve this PDF's encryption. Use an explicitly unencrypted working copy."
        }
    }
}

/// Imports Apple's resolved PDF object graph, including compressed xref/object streams.
/// Only objects reachable from the rewritten catalog and information dictionary are emitted.
/// Replaced, now-unreachable content streams never remain as hidden bytes in the new file.
@MainActor
final class PDFNativeObjectGraph {
    private var objects: [Int: PDFNativeValue] = [:]
    private var dictionaries: [UInt: Int] = [:]
    private var arrays: [UInt: Int] = [:]
    private var streams: [UInt: Int] = [:]
    private var retainedDocuments: [CGPDFDocument] = []
    private var nextID = 1
    private var depth = 0
    private var importedBytes = 0
    private var itemCount = 0
    private(set) var rootID = 0
    private var info: PDFNativeValue?

    private let maximumObjects = 200_000
    private let maximumBytes = 1_024 * 1_024 * 1_024
    private let maximumItems = 4_000_000

    init(document: CGPDFDocument) throws {
        guard !document.isEncrypted else { throw PDFNativeGraphError.encrypted }
        retainedDocuments = [document]
        guard let catalog = document.catalog else { throw PDFNativeGraphError.malformed }
        guard case .reference(let root) = try importDictionary(catalog) else { throw PDFNativeGraphError.malformed }
        rootID = root
        if let originalInfo = document.info { info = try importDictionary(originalInfo) }
    }

    func retain(_ document: CGPDFDocument) { retainedDocuments.append(document) }

    subscript(id: Int) -> PDFNativeValue? {
        get { objects[id] }
        set { objects[id] = newValue }
    }

    func objectID(for dictionary: CGPDFDictionaryRef) -> Int? { dictionaries[UInt(bitPattern: dictionary.rawValue)] }

    func append(_ value: PDFNativeValue) throws -> PDFNativeValue {
        guard nextID <= maximumObjects else { throw PDFNativeGraphError.resourceLimit }
        let id = nextID
        nextID += 1
        objects[id] = value
        return .reference(id)
    }

    func appendStream(data: Data, dictionary: [String: PDFNativeValue] = [:]) throws -> PDFNativeValue {
        try countBytes(data.count)
        return try append(.stream(dictionary: dictionary, data: data))
    }

    func resolved(_ value: PDFNativeValue) throws -> PDFNativeValue {
        var current = value
        var visited = Set<Int>()
        while case .reference(let id) = current {
            guard visited.insert(id).inserted, let next = objects[id] else { throw PDFNativeGraphError.malformed }
            current = next
        }
        return current
    }

    func importObject(_ object: CGPDFObjectRef) throws -> PDFNativeValue {
        itemCount += 1
        guard itemCount <= maximumItems else { throw PDFNativeGraphError.resourceLimit }
        switch CGPDFObjectGetType(object) {
        case .null: return .null
        case .boolean:
            var value: CGPDFBoolean = 0
            guard CGPDFObjectGetValue(object, .boolean, &value) else { throw PDFNativeGraphError.malformed }
            return .boolean(value != 0)
        case .integer:
            var value: CGPDFInteger = 0
            guard CGPDFObjectGetValue(object, .integer, &value) else { throw PDFNativeGraphError.malformed }
            return .integer(value)
        case .real:
            var value: CGPDFReal = 0
            guard CGPDFObjectGetValue(object, .real, &value), value.isFinite else { throw PDFNativeGraphError.malformed }
            return .number(value)
        case .name:
            var value: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, .name, &value), let value else { throw PDFNativeGraphError.malformed }
            return .name(Self.byteString(value))
        case .string:
            var value: CGPDFStringRef?
            guard CGPDFObjectGetValue(object, .string, &value), let value else { throw PDFNativeGraphError.malformed }
            let length = CGPDFStringGetLength(value)
            try countBytes(length)
            guard length > 0 else { return .string(Data()) }
            guard let bytes = CGPDFStringGetBytePtr(value) else { throw PDFNativeGraphError.malformed }
            return .string(Data(bytes: bytes, count: length))
        case .array:
            var value: CGPDFArrayRef?
            guard CGPDFObjectGetValue(object, .array, &value), let value else { throw PDFNativeGraphError.malformed }
            return try importArray(value)
        case .dictionary:
            var value: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &value), let value else { throw PDFNativeGraphError.malformed }
            return try importDictionary(value)
        case .stream:
            var value: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &value), let value else { throw PDFNativeGraphError.malformed }
            return try importStream(value)
        @unknown default: throw PDFNativeGraphError.malformed
        }
    }

    func importDictionary(_ dictionary: CGPDFDictionaryRef) throws -> PDFNativeValue {
        let key = UInt(bitPattern: dictionary.rawValue)
        if let id = dictionaries[key] { return .reference(id) }
        guard case .reference(let id) = try append(.null) else { throw PDFNativeGraphError.malformed }
        dictionaries[key] = id
        objects[id] = try .dictionary(importEntries(dictionary))
        return .reference(id)
    }

    private func importArray(_ array: CGPDFArrayRef) throws -> PDFNativeValue {
        let key = UInt(bitPattern: array.rawValue)
        if let id = arrays[key] { return .reference(id) }
        guard case .reference(let id) = try append(.null) else { throw PDFNativeGraphError.malformed }
        arrays[key] = id
        try enter()
        defer { depth -= 1 }
        let count = CGPDFArrayGetCount(array)
        guard count <= maximumItems else { throw PDFNativeGraphError.resourceLimit }
        var values: [PDFNativeValue] = []
        values.reserveCapacity(count)
        for index in 0..<count {
            var object: CGPDFObjectRef?
            guard CGPDFArrayGetObject(array, index, &object), let object else { throw PDFNativeGraphError.malformed }
            values.append(try importObject(object))
        }
        objects[id] = .array(values)
        return .reference(id)
    }

    func importStream(_ stream: CGPDFStreamRef) throws -> PDFNativeValue {
        let key = UInt(bitPattern: stream.rawValue)
        if let id = streams[key] { return .reference(id) }
        guard let original = CGPDFStreamGetDictionary(stream) else { throw PDFNativeGraphError.malformed }
        guard case .reference(let id) = try append(.null) else { throw PDFNativeGraphError.malformed }
        streams[key] = id
        var dictionary = try importEntries(original)
        guard dictionary["F"] == nil, nativeStreamExpansionIsBounded(stream) else { throw PDFNativeGraphError.unsupportedStream }
        var format = CGPDFDataFormat.raw
        guard let copied = CGPDFStreamCopyData(stream, &format) else { throw PDFNativeGraphError.unsupportedStream }
        let bytes = copied as Data
        try countBytes(bytes.count)
        let originalFilter = dictionary["Filter"]
        let originalParameters = dictionary["DecodeParms"]
        dictionary.removeValue(forKey: "Length")
        dictionary.removeValue(forKey: "Filter")
        dictionary.removeValue(forKey: "DecodeParms")
        switch format {
        case .raw: break
        case .jpegEncoded:
            dictionary["Filter"] = .name("DCTDecode")
            dictionary["DecodeParms"] = try retainedParameters(for: "DCTDecode", filter: originalFilter, parameters: originalParameters)
        case .JPEG2000:
            dictionary["Filter"] = .name("JPXDecode")
            dictionary["DecodeParms"] = try retainedParameters(for: "JPXDecode", filter: originalFilter, parameters: originalParameters)
        @unknown default: throw PDFNativeGraphError.unsupportedStream
        }
        objects[id] = .stream(dictionary: dictionary, data: bytes)
        return .reference(id)
    }

    private func retainedParameters(for filterName: String, filter: PDFNativeValue?, parameters: PDFNativeValue?) throws -> PDFNativeValue? {
        guard let filter, let parameters else { return nil }
        switch try resolved(filter) {
        case .name(let name): return name == filterName ? parameters : nil
        case .array(let filters):
            guard case .array(let values) = try resolved(parameters), values.count == filters.count else { return nil }
            for (index, item) in filters.enumerated() {
                if case .name(let name) = try resolved(item), name == filterName { return values[index] }
            }
            return nil
        default: return nil
        }
    }

    private func importEntries(_ dictionary: CGPDFDictionaryRef) throws -> [String: PDFNativeValue] {
        try enter()
        defer { depth -= 1 }
        guard CGPDFDictionaryGetCount(dictionary) <= maximumItems else { throw PDFNativeGraphError.resourceLimit }
        var entries: [String: PDFNativeValue] = [:]
        var failure: Error?
        CGPDFDictionaryApplyBlock(dictionary, { key, object, _ in
            do { entries[Self.byteString(key)] = try self.importObject(object); return true }
            catch { failure = error; return false }
        }, nil)
        if let failure { throw failure }
        return entries
    }

    private func enter() throws {
        guard depth < 256 else { throw PDFNativeGraphError.resourceLimit }
        depth += 1
    }

    private func countBytes(_ count: Int) throws {
        guard count >= 0, count <= maximumBytes - importedBytes else { throw PDFNativeGraphError.resourceLimit }
        importedBytes += count
    }

    private static func byteString(_ pointer: UnsafePointer<CChar>) -> String {
        let bytes = Data(bytes: pointer, count: strlen(pointer))
        return String(data: bytes, encoding: .isoLatin1) ?? String(decoding: bytes, as: UTF8.self)
    }

    func write() throws -> Data {
        var reachable = Set<Int>()
        try visit(.reference(rootID), into: &reachable, depth: 0)
        if let info { try visit(info, into: &reachable, depth: 0) }
        let identifiers = reachable.sorted()
        // Compact IDs avoid huge sparse xref tables after replacing many streams.
        let mapping = Dictionary(uniqueKeysWithValues: identifiers.enumerated().map { ($0.element, $0.offset + 1) })
        var output = Data("%PDF-1.7\n".utf8)
        output.append(contentsOf: [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        var offsets: [Int] = [0]
        for originalID in identifiers {
            guard let value = objects[originalID], let id = mapping[originalID] else { throw PDFNativeGraphError.malformed }
            offsets.append(output.count)
            output.append(Data("\(id) 0 obj\n".utf8))
            try encode(value, into: &output, mapping: mapping, depth: 0)
            output.append(Data("\nendobj\n".utf8))
            guard output.count <= maximumBytes else { throw PDFNativeGraphError.resourceLimit }
        }
        let xref = output.count
        output.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        // %ld: a Swift Int is 64 bits, and %d would read only 32 of them.
        for offset in offsets.dropFirst() { output.append(Data(String(format: "%010ld 00000 n \n", offset).utf8)) }
        var trailer: [String: PDFNativeValue] = ["Size": .integer(offsets.count), "Root": .reference(rootID)]
        if let info { trailer["Info"] = info }
        output.append(Data("trailer\n".utf8))
        try encode(.dictionary(trailer), into: &output, mapping: mapping, depth: 0)
        output.append(Data("\nstartxref\n\(xref)\n%%EOF\n".utf8))
        guard output.count <= maximumBytes else { throw PDFNativeGraphError.resourceLimit }
        return output
    }

    private func visit(_ value: PDFNativeValue, into found: inout Set<Int>, depth: Int) throws {
        guard depth <= 256 else { throw PDFNativeGraphError.resourceLimit }
        switch value {
        case .reference(let id):
            guard found.insert(id).inserted else { return }
            guard let object = objects[id] else { throw PDFNativeGraphError.malformed }
            try visit(object, into: &found, depth: depth + 1)
        case .array(let values): for item in values { try visit(item, into: &found, depth: depth + 1) }
        case .dictionary(let dictionary), .stream(let dictionary, _):
            for (key, item) in dictionary where key != "Length" || !isStream(value) {
                try visit(item, into: &found, depth: depth + 1)
            }
        default: break
        }
    }

    private func isStream(_ value: PDFNativeValue) -> Bool { if case .stream = value { true } else { false } }

    private func encode(_ value: PDFNativeValue, into output: inout Data, mapping: [Int: Int], depth: Int) throws {
        guard depth <= 256 else { throw PDFNativeGraphError.resourceLimit }
        switch value {
        case .null: output.append(Data("null".utf8))
        case .boolean(let value): output.append(Data((value ? "true" : "false").utf8))
        case .integer(let value): output.append(Data(String(value).utf8))
        case .number(let value): output.append(Data(try Self.decimal(value).utf8))
        case .name(let name): output.append(Data(("/" + Self.escapedName(name)).utf8))
        case .string(let data):
            output.append(0x3C)
            let hex = Array("0123456789ABCDEF".utf8)
            for byte in data { output.append(hex[Int(byte >> 4)]); output.append(hex[Int(byte & 15)]) }
            output.append(0x3E)
        case .reference(let id):
            guard let remapped = mapping[id] else { throw PDFNativeGraphError.malformed }
            output.append(Data("\(remapped) 0 R".utf8))
        case .array(let values):
            output.append(0x5B)
            for item in values { try encode(item, into: &output, mapping: mapping, depth: depth + 1); output.append(0x20) }
            output.append(0x5D)
        case .dictionary(let values):
            output.append(Data("<<\n".utf8))
            for key in values.keys.sorted() {
                guard let item = values[key] else { continue }
                output.append(Data(("/" + Self.escapedName(key) + " ").utf8))
                try encode(item, into: &output, mapping: mapping, depth: depth + 1)
                output.append(0x0A)
            }
            output.append(Data(">>".utf8))
        case .stream(var dictionary, let data):
            dictionary["Length"] = .integer(data.count)
            try encode(.dictionary(dictionary), into: &output, mapping: mapping, depth: depth + 1)
            output.append(Data("\nstream\n".utf8)); output.append(data); output.append(Data("\nendstream".utf8))
        }
        guard output.count <= maximumBytes else { throw PDFNativeGraphError.resourceLimit }
    }

    private static func escapedName(_ name: String) -> String {
        let bytes = name.data(using: .isoLatin1) ?? Data(name.utf8)
        let hex = Array("0123456789ABCDEF".utf8)
        var output: [UInt8] = []
        for byte in bytes {
            if (33...126).contains(byte), ![UInt8(35), 37, 40, 41, 47, 60, 62, 91, 93, 123, 125].contains(byte) { output.append(byte) }
            else { output += [35, hex[Int(byte >> 4)], hex[Int(byte & 15)]] }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func decimal(_ value: Double) throws -> String {
        guard value.isFinite else { throw PDFNativeGraphError.malformed }
        let raw = String(value)
        guard let separator = raw.firstIndex(of: "e") ?? raw.firstIndex(of: "E") else { return raw }
        let mantissa = String(raw[..<separator])
        guard let exponent = Int(raw[raw.index(after: separator)...]) else { throw PDFNativeGraphError.malformed }
        let sign = mantissa.hasPrefix("-") ? "-" : ""
        let unsigned = mantissa.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        let parts = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        let digits = parts.joined()
        let point = (parts.first?.count ?? 0) + exponent
        if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + digits }
        if point >= digits.count { return sign + digits + String(repeating: "0", count: point - digits.count) }
        let index = digits.index(digits.startIndex, offsetBy: point)
        return sign + digits[..<index] + "." + digits[index...]
    }
}
