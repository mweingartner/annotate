import Foundation

/// Small ZIP writer for Open Packaging Convention documents. Entries are stored without compression;
/// PDF page images are already encoded. No shell process, temporary file, or third-party library is used.
enum PDFOfficeZIP {
    static let maximumBytes = 256 * 1_024 * 1_024
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? 0xEDB88320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }

    static func archive(_ entries: [(String, Data)]) throws -> Data {
        guard entries.count <= 65_535, Set(entries.map(\.0)).count == entries.count else { throw PDFConversionError.failed }
        var output = Data(), directory = Data()
        for (name, data) in entries {
            let filename = Data(name.utf8)
            guard !name.isEmpty, !name.hasPrefix("/"), !name.split(separator: "/").contains(".."), filename.count <= 65_535,
                  data.count <= maximumBytes, output.count + directory.count + data.count + filename.count * 2 + 100 <= maximumBytes else {
                throw PDFConversionError.inputTooLarge
            }
            let checksum = crc32(data), size = UInt32(data.count), offset = UInt32(output.count)
            output.appendLE(UInt32(0x04034B50))
            output.appendLE(UInt16(20)); output.appendLE(UInt16(0x0800)); output.appendLE(UInt16(0))
            output.appendLE(UInt16(0)); output.appendLE(UInt16(33))
            output.appendLE(checksum); output.appendLE(size); output.appendLE(size)
            output.appendLE(UInt16(filename.count)); output.appendLE(UInt16(0))
            output.append(filename); output.append(data)
            directory.appendLE(UInt32(0x02014B50))
            directory.appendLE(UInt16(20)); directory.appendLE(UInt16(20)); directory.appendLE(UInt16(0x0800)); directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0)); directory.appendLE(UInt16(33))
            directory.appendLE(checksum); directory.appendLE(size); directory.appendLE(size)
            directory.appendLE(UInt16(filename.count)); directory.appendLE(UInt16(0)); directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0)); directory.appendLE(UInt16(0)); directory.appendLE(UInt32(0)); directory.appendLE(offset)
            directory.append(filename)
        }
        let start = UInt32(output.count)
        output.append(directory)
        output.appendLE(UInt32(0x06054B50)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0))
        output.appendLE(UInt16(entries.count)); output.appendLE(UInt16(entries.count))
        output.appendLE(UInt32(directory.count)); output.appendLE(start); output.appendLE(UInt16(0))
        return output
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
