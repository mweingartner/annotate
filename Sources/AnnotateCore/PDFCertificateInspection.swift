import CoreGraphics
import Foundation

@MainActor
enum PDFCertificateInspection {
    struct Entry { let name: String; let dictionary: CGPDFDictionaryRef? }

    static func entries(in document: CGPDFDocument) throws -> [Entry] {
        guard let catalog = document.catalog else { throw PDFCertificateError.invalidPDF }
        var result: [Entry] = [], visited: Set<UInt> = [], signatures: Set<UInt> = []
        func append(_ value: CGPDFDictionaryRef?, name: String) {
            if let value, !signatures.insert(UInt(bitPattern: value.rawValue)).inserted { return }
            result.append(Entry(name: name, dictionary: value))
        }
        func walk(_ field: CGPDFDictionaryRef, type: String?, name: String, depth: Int) throws {
            guard depth < 64, visited.count < 10_000 else { throw PDFCertificateError.malformedSignature }
            guard visited.insert(UInt(bitPattern: field.rawValue)).inserted else { return }
            let fieldType = nativeName(field, "FT") ?? type
            let component = text(field, key: "T") ?? ""
            let fieldName = name.isEmpty ? component : component.isEmpty ? name : name + "." + component
            var value: CGPDFObjectRef?
            if fieldType == "Sig", CGPDFDictionaryGetObject(field, "V", &value), let value,
               CGPDFObjectGetType(value) != .null {
                append(nativeDictionary(field, "V"), name: fieldName.isEmpty ? "Signature" : fieldName)
            }
            if let kids = nativeArray(field, "Kids") {
                for index in 0..<CGPDFArrayGetCount(kids) {
                    var child: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(kids, index, &child), let child else { throw PDFCertificateError.malformedSignature }
                    try walk(child, type: fieldType, name: fieldName, depth: depth + 1)
                }
            }
        }
        if let form = nativeDictionary(catalog, "AcroForm"), let fields = nativeArray(form, "Fields") {
            for index in 0..<CGPDFArrayGetCount(fields) {
                var field: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(fields, index, &field), let field else { throw PDFCertificateError.malformedSignature }
                try walk(field, type: nil, name: "", depth: 0)
            }
        }
        if let permissions = nativeDictionary(catalog, "Perms") {
            for key in ["DocMDP", "UR", "UR3"] {
                if let signature = nativeDictionary(permissions, key) { append(signature, name: key) }
            }
        }
        return result
    }

    static func signedContent(_ dictionary: CGPDFDictionaryRef, data: Data) throws -> (content: Data, envelope: Data, coversWholeFile: Bool) {
        guard let array = nativeArray(dictionary, "ByteRange"), CGPDFArrayGetCount(array) == 4,
              let encoded = bytes(dictionary, key: "Contents"), encoded.count <= 1_048_576 else { throw PDFCertificateError.invalidByteRange }
        var range: [Int] = []
        for index in 0..<4 {
            var value = CGPDFInteger(0)
            guard CGPDFArrayGetInteger(array, index, &value), value >= 0 else { throw PDFCertificateError.invalidByteRange }
            range.append(value)
        }
        guard range[0] == 0, range[1] > 0, range[1] < range[2], range[2] <= data.count,
              range[3] <= data.count - range[2] else { throw PDFCertificateError.invalidByteRange }
        let gap = data.subdata(in: range[1]..<range[2])
        guard gap.first == 0x3C, gap.last == 0x3E,
              try decodeHex(gap.dropFirst().dropLast()) == encoded else { throw PDFCertificateError.invalidContents }
        var content = data.subdata(in: 0..<range[1])
        content.append(data.subdata(in: range[2]..<(range[2] + range[3])))
        return (content, try derEnvelope(encoded), range[2] + range[3] == data.count)
    }

    static func text(_ dictionary: CGPDFDictionaryRef, key: String) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, key, &value), let value else { return nil }
        return CGPDFStringCopyTextString(value) as String?
    }
    private static func bytes(_ dictionary: CGPDFDictionaryRef, key: String) -> Data? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, key, &value), let value, let bytes = CGPDFStringGetBytePtr(value) else { return nil }
        return Data(bytes: bytes, count: CGPDFStringGetLength(value))
    }
    private static func decodeHex(_ data: Data.SubSequence) throws -> Data {
        var result = Data(), high: UInt8?
        for byte in data {
            if [0, 9, 10, 12, 13, 32].contains(byte) { continue }
            let value: UInt8
            switch byte {
            case 48...57: value = byte - 48
            case 65...70: value = byte - 55
            case 97...102: value = byte - 87
            default: throw PDFCertificateError.invalidContents
            }
            if let first = high { result.append(first << 4 | value); high = nil }
            else { high = value }
        }
        if let high { result.append(high << 4) }
        return result
    }
    private static func derEnvelope(_ data: Data) throws -> Data {
        guard data.count >= 2, data[0] == 0x30 else { throw PDFCertificateError.invalidEnvelope }
        var offset = 2, length = Int(data[1])
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...4).contains(count), data.count >= count + 2 else { throw PDFCertificateError.invalidEnvelope }
            length = 0
            for index in 0..<count { length = (length << 8) | Int(data[2 + index]) }
            offset += count
        }
        guard length > 0, length <= data.count - offset,
              data.dropFirst(offset + length).allSatisfy({ $0 == 0 }) else { throw PDFCertificateError.invalidEnvelope }
        return data.prefix(offset + length)
    }
}
