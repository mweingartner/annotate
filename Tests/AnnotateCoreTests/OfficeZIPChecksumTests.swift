import AppKit
import Foundation
import PDFKit
import Testing
@testable import AnnotateCore

/// The ZIP checksum moved from a byte-at-a-time table loop to zlib. These tests hold zlib to
/// the old loop on any input and check the archives still validate with the system unzip.
@Suite("Office ZIP checksum and archive validity", .serialized)
@MainActor
struct OfficeZIPChecksumTests {
    /// The checksum as the writer computed it before: the reflected CRC-32 table loop.
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? 0xEDB88320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }
    private func reference(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = Self.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }

    @Test("Known CRC-32 vectors, including empty input", arguments: [
        ("", UInt32(0)), ("a", 0xE8B7BE43), ("abc", 0x352441C2), ("123456789", 0xCBF43926),
        ("The quick brown fox jumps over the lazy dog", 0x414FA339)
    ])
    func vectors(_ text: String, _ expected: UInt32) {
        #expect(PDFOfficeZIP.crc32(Data(text.utf8)) == expected)
    }

    @Test("Thirty-two zero bytes and thirty-two 0xFF bytes")
    func fixedPatterns() {
        #expect(PDFOfficeZIP.crc32(Data(repeating: 0, count: 32)) == 0x190A55AD)
        #expect(PDFOfficeZIP.crc32(Data(repeating: 0xFF, count: 32)) == 0xFF6CAB0B)
    }

    @Test("zlib matches the old table loop on random inputs of every small length and a few large ones", arguments: Array(UInt64(1)...UInt64(4)))
    func matchesReference(seed: UInt64) {
        var random = BulkRandom(seed: seed)
        var lengths = Array(0...300)
        lengths += [1_023, 1_024, 1_025, 65_535, 65_536, 65_537, Int.random(in: 100_000...2_000_000, using: &random)]
        for length in lengths {
            var bytes = [UInt8](repeating: 0, count: length)
            for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: random.next()) }
            let data = Data(bytes)
            let got = PDFOfficeZIP.crc32(data), want = reference(data)
            #expect(got == want, "seed \(seed) length \(length): \(String(got, radix: 16)) vs \(String(want, radix: 16))")
            if got != want { return }
        }
    }

    @Test("A slice is checksummed as its own bytes, wherever it starts in its parent")
    func slices() {
        var random = BulkRandom(seed: 99)
        let parent = Data((0..<4_096).map { _ in UInt8(truncatingIfNeeded: random.next()) })
        for (start, end) in [(0, 0), (1, 1), (7, 8), (13, 4_000), (4_095, 4_096), (2_048, 4_096)] {
            let slice = parent[start..<end]
            #expect(slice.startIndex == start)
            #expect(PDFOfficeZIP.crc32(slice) == reference(Data(slice)), "\(start)..<\(end)")
            #expect(PDFOfficeZIP.crc32(slice) == PDFOfficeZIP.crc32(Data(Array(slice))))
        }
    }

    @Test("Changing any single bit changes the checksum")
    func singleBitSensitivity() {
        var random = BulkRandom(seed: 7)
        let original = Data((0..<257).map { _ in UInt8(truncatingIfNeeded: random.next()) })
        let checksum = PDFOfficeZIP.crc32(original)
        for _ in 0..<200 {
            var flipped = original
            let index = Int.random(in: 0..<flipped.count, using: &random)
            flipped[index] ^= UInt8(1) << UInt8.random(in: 0..<8, using: &random)
            #expect(PDFOfficeZIP.crc32(flipped) != checksum)
        }
    }

    /// `/usr/bin/unzip -t` on the archive: every entry's stored checksum and length must check out.
    private func unzipTest(_ archive: Data, name: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zip-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(name)
        try archive.write(to: file)
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-t", file.path]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(name): \(output)")
        return output
    }

    @Test("PowerPoint and Excel exports pass the system unzip's integrity test")
    func systemUnzipValidates() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip") else { return }
        let document = try Fixtures.document()
        let presentation = try PDFConversion.exportData(document: document, format: .pptx)
        let pptx = try unzipTest(presentation, name: "deck.pptx")
        #expect(pptx.contains("No errors detected"), "\(pptx)")
        #expect(pptx.contains("ppt/media/page4.png"))
        let text = try PDFConversion.textDocument(NSAttributedString(string: "Name  Value\nÉmilie  日本語\n", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        let spreadsheet = try PDFConversion.exportData(document: text, format: .xlsx)
        let xlsx = try unzipTest(spreadsheet, name: "sheet.xlsx")
        #expect(xlsx.contains("No errors detected"), "\(xlsx)")
        // An archive of empty, small and large entries.
        var random = BulkRandom(seed: 5)
        let large = Data((0..<300_000).map { _ in UInt8(truncatingIfNeeded: random.next()) })
        let mixed = try PDFOfficeZIP.archive([("empty.bin", Data()), ("one.txt", Data("x".utf8)), ("dir/large.bin", large)])
        let output = try unzipTest(mixed, name: "mixed.zip")
        #expect(output.contains("No errors detected"), "\(output)")
    }

    @Test("Exporting a presentation page by page renders every page, and twice gives the same images")
    func presentationDeterministic() throws {
        let document = try Fixtures.document()
        let first = try PDFOfficeExporter.presentation(document), second = try PDFOfficeExporter.presentation(document)
        #expect(first.count > 100_000)
        // Page images are rendered fresh in each page's pool; the same document gives the same bytes.
        #expect(first == second)
    }
}
