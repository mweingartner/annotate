import Foundation

/// PDF lexical values. String bytes remain encoded bytes; Unicode decoding belongs to the font.
indirect enum PDFNativeToken {
    case number(Double), name(String), bytes([UInt8]), array([PDFNativeToken]), dictionary([String: PDFNativeToken]), word(String)
    var number: Double? { if case .number(let value) = self { value } else { nil } }
    var name: String? { if case .name(let value) = self { value } else { nil } }
    var bytes: [UInt8]? { if case .bytes(let value) = self { value } else { nil } }
    var array: [PDFNativeToken]? { if case .array(let value) = self { value } else { nil } }
}

struct PDFNativeOperation {
    var operands: [PDFNativeToken]
    let name: String
    let range: Range<Int>
}

struct PDFNativeLexer {
    let bytes: [UInt8]
    var index = 0
    init(_ data: Data) { bytes = Array(data) }
    init(bytes: [UInt8]) { self.bytes = bytes }
    static func whitespace(_ byte: UInt8) -> Bool { [0, 9, 10, 12, 13, 32].contains(byte) }
    static func delimiter(_ byte: UInt8) -> Bool { whitespace(byte) || [40, 41, 60, 62, 91, 93, 123, 125, 47, 37].contains(byte) }
    mutating func skip() {
        while index < bytes.count {
            if Self.whitespace(bytes[index]) { index += 1 }
            else if bytes[index] == 37 { while index < bytes.count, bytes[index] != 10, bytes[index] != 13 { index += 1 } }
            else { break }
        }
    }
    mutating func next(depth: Int = 0) throws -> PDFNativeToken? {
        guard depth < 80 else { throw PDFNativeTextError.unsupported("The content nesting exceeds the safe parsing limit.") }
        skip(); guard index < bytes.count else { return nil }
        let byte = bytes[index]; index += 1
        if byte == 40 {
            var result: [UInt8] = [], nesting = 1
            while index < bytes.count {
                let value = bytes[index]; index += 1
                if value == 92 {
                    guard index < bytes.count else { break }
                    let escaped = bytes[index]; index += 1
                    if escaped >= 48, escaped <= 55 {
                        var number = Int(escaped - 48)
                        for _ in 0..<2 where index < bytes.count && bytes[index] >= 48 && bytes[index] <= 55 {
                            number = number * 8 + Int(bytes[index] - 48); index += 1
                        }
                        result.append(UInt8(number & 255))
                    } else if escaped == 13 { if index < bytes.count, bytes[index] == 10 { index += 1 } }
                    else if escaped == 10 { }
                    else { result.append([UInt8(110): UInt8(10), 114: 13, 116: 9, 98: 8, 102: 12][escaped] ?? escaped) }
                } else if value == 40 { nesting += 1; result.append(value) }
                else if value == 41 { nesting -= 1; if nesting == 0 { return .bytes(result) }; result.append(value) }
                else if value == 13 { result.append(10); if index < bytes.count, bytes[index] == 10 { index += 1 } }
                else { result.append(value) }
            }
            throw PDFNativeTextError.malformed("Unterminated literal string.")
        }
        if byte == 60 {
            if index < bytes.count, bytes[index] == 60 {
                index += 1; var dictionary: [String: PDFNativeToken] = [:]
                while true {
                    skip()
                    if index + 1 < bytes.count, bytes[index] == 62, bytes[index + 1] == 62 { index += 2; return .dictionary(dictionary) }
                    guard case .name(let key)? = try next(depth: depth + 1), let value = try next(depth: depth + 1) else { throw PDFNativeTextError.malformed("Invalid inline dictionary.") }
                    dictionary[key] = value
                }
            }
            var digits: [UInt8] = []
            while index < bytes.count, bytes[index] != 62 {
                let digit = bytes[index]; index += 1
                if Self.whitespace(digit) { continue }
                guard Self.hex(digit) != nil else { throw PDFNativeTextError.malformed("Invalid hexadecimal string.") }
                digits.append(digit)
            }
            guard index < bytes.count else { throw PDFNativeTextError.malformed("Unterminated hexadecimal string.") }
            index += 1; if digits.count % 2 == 1 { digits.append(48) }
            return .bytes(stride(from: 0, to: digits.count, by: 2).map { Self.hex(digits[$0])! * 16 + Self.hex(digits[$0 + 1])! })
        }
        if byte == 91 {
            var values: [PDFNativeToken] = []
            while true {
                skip(); guard index < bytes.count else { throw PDFNativeTextError.malformed("Unterminated array.") }
                if bytes[index] == 93 { index += 1; return .array(values) }
                guard let value = try next(depth: depth + 1) else { throw PDFNativeTextError.malformed("Invalid array.") }
                values.append(value)
            }
        }
        if byte == 47 {
            var name: [UInt8] = []
            while index < bytes.count, !Self.delimiter(bytes[index]) {
                if bytes[index] == 35, index + 2 < bytes.count, let high = Self.hex(bytes[index + 1]), let low = Self.hex(bytes[index + 2]) { name.append(high * 16 + low); index += 3 }
                else { name.append(bytes[index]); index += 1 }
            }
            return .name(String(decoding: name, as: UTF8.self))
        }
        let start = index - 1
        while index < bytes.count, !Self.delimiter(bytes[index]) { index += 1 }
        let word = String(decoding: bytes[start..<index], as: UTF8.self)
        if let number = Double(word), number.isFinite { return .number(number) }
        return .word(word)
    }
    mutating func operations() throws -> [PDFNativeOperation] {
        var result: [PDFNativeOperation] = [], operands: [PDFNativeToken] = []
        var start = 0
        while true {
            skip(); if operands.isEmpty { start = index }
            guard let value = try next() else { break }
            if case .word(let name) = value, !["true", "false", "null"].contains(name) {
                if name == "BI" { throw PDFNativeTextError.unsupported("This page uses inline images in its text content stream.") }
                result.append(PDFNativeOperation(operands: operands, name: name, range: start..<index)); operands = []
                guard result.count <= 250_000 else { throw PDFNativeTextError.unsupported("This page exceeds the safe content-operation limit.") }
            } else { operands.append(value) }
        }
        guard operands.isEmpty else { throw PDFNativeTextError.malformed("Content ends with unused operands.") }
        return result
    }
    static func hex(_ byte: UInt8) -> UInt8? {
        switch byte { case 48...57: byte - 48; case 65...70: byte - 55; case 97...102: byte - 87; default: nil }
    }
}

private let nativeNumberLocale = Locale(identifier: "en_US_POSIX")
func nativePDFNumber(_ value: Double) -> String {
    guard value.isFinite else { return "0" }
    // Trailing zeros, and then a bare decimal point, are dropped: "12.50000000" is "12.5".
    var text = String(format: "%.8f", locale: nativeNumberLocale, value)
    while text.last == "0" { text.removeLast() }
    if text.last == "." { text.removeLast() }
    return text
}
func nativePDFHex(_ bytes: [UInt8]) -> String { "<" + bytes.map { String(format: "%02X", $0) }.joined() + ">" }
