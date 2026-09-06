import AppKit
import PDFKit
import Testing
@testable import AnnotateCore

@Suite("Native Excel and PowerPoint export", .serialized)
@MainActor
struct OfficeExportTests {
    @Test("Excel ZIP entries have valid CRCs and XML, one worksheet per page, and Unicode text")
    func spreadsheet() throws {
        let document = try PDFConversion.textDocument(NSAttributedString(string: "Name  Value\nÉmilie  日本語\n=1+1  00123\nA & B < C\n", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        let data = try PDFConversion.exportData(document: document, format: .xlsx)
        let entries = try unzipStored(data)
        try validateXML(entries)
        let sheetData = try #require(entries["xl/worksheets/sheet1.xml"])
        let sheet = try #require(String(data: sheetData, encoding: .utf8))
        #expect(sheet.contains("Émilie"))
        #expect(sheet.precomposedStringWithCompatibilityMapping.contains("日本語"))
        #expect(sheet.contains("=1+1"))
        #expect(sheet.contains("00123"))
        #expect(sheet.contains("&amp;"))
        #expect(sheet.contains("&lt;"))
        #expect(!sheet.contains("<f>"))
        #expect(sheet.contains("t=\"inlineStr\""))
        #expect(entries["xl/workbook.xml"] != nil)
        #expect(entries["xl/_rels/workbook.xml.rels"] != nil)
    }

    @Test("Presentation keeps page count and packages real PNG page images with valid relationships")
    func presentation() throws {
        let document = try Fixtures.document()
        let data = try PDFConversion.exportData(document: document, format: .pptx)
        let entries = try unzipStored(data)
        try validateXML(entries)
        #expect(entries.keys.count { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") } == document.pageCount)
        #expect(entries.keys.count { $0.hasPrefix("ppt/media/") } == document.pageCount)
        for page in 1...document.pageCount {
            let png = try #require(entries["ppt/media/page\(page).png"])
            #expect(png.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]))
            let image = try #require(NSBitmapImageRep(data: png))
            #expect(image.pixelsWide == 1224)
            #expect(image.pixelsHigh == 1584)
            let relationshipData = try #require(entries["ppt/slides/_rels/slide\(page).xml.rels"])
            let relationships = try #require(String(data: relationshipData, encoding: .utf8))
            #expect(relationships.contains("../media/page\(page).png"))
        }
        #expect(entries["ppt/theme/theme1.xml"] != nil)
        #expect(entries["ppt/slideMasters/slideMaster1.xml"] != nil)
    }

    @Test("PowerPoint page images respect rotated crop dimensions")
    func rotatedPresentation() throws {
        let document = try Fixtures.geometryDocument(rotation: 90, crop: CGRect(x: 50, y: 70, width: 300, height: 350))
        let entries = try unzipStored(PDFOfficeExporter.presentation(document))
        let imageData = try #require(entries["ppt/media/page1.png"])
        let image = try #require(NSBitmapImageRep(data: imageData))
        #expect(image.pixelsWide == 700)
        #expect(image.pixelsHigh == 600)
    }

    @Test("Office export rejects empty or unrecognized text documents appropriately")
    func invalidSources() throws {
        #expect(throws: (any Error).self) { try PDFOfficeExporter.presentation(PDFDocument()) }
        #expect(throws: (any Error).self) { try PDFOfficeExporter.spreadsheet(PDFDocument()) }
        let image = NSImage(size: CGSize(width: 100, height: 100), flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true }
        let scan = PDFDocument()
        scan.insert(try #require(PDFPage(image: image)), at: 0)
        #expect(throws: (any Error).self) { try PDFOfficeExporter.spreadsheet(scan) }
        #expect(try !PDFOfficeExporter.presentation(scan).isEmpty)
    }

    @Test("ZIP writer rejects duplicate or traversing paths and matches the CRC32 reference vector")
    func zipValidation() throws {
        #expect(PDFOfficeZIP.crc32(Data("123456789".utf8)) == 0xCBF43926)
        #expect(throws: (any Error).self) { try PDFOfficeZIP.archive([("a", Data()), ("a", Data())]) }
        #expect(throws: (any Error).self) { try PDFOfficeZIP.archive([("../escape", Data())]) }
        let entries = try unzipStored(PDFOfficeZIP.archive([("é.txt", Data("Unicode payload".utf8))]))
        #expect(entries["é.txt"] == Data("Unicode payload".utf8))
    }

    private func validateXML(_ entries: [String: Data]) throws {
        for (name, data) in entries where name.hasSuffix(".xml") || name.hasSuffix(".rels") {
            let parser = XMLParser(data: data)
            #expect(parser.parse(), "Invalid XML part: \(name): \(parser.parserError?.localizedDescription ?? "")")
        }
    }

    /// Independent local-header reader verifies saved CRC, byte lengths, path boundaries and EOCD.
    private func unzipStored(_ data: Data) throws -> [String: Data] {
        let bytes = Array(data)
        func number(_ index: Int, _ length: Int) throws -> UInt32 {
            guard index >= 0, index + length <= bytes.count else { throw PDFConversionError.failed }
            return (0..<length).reduce(UInt32(0)) { $0 | UInt32(bytes[index + $1]) << ($1 * 8) }
        }
        var index = 0, result: [String: Data] = [:]
        while try number(index, 4) == 0x04034B50 {
            #expect(try number(index + 8, 2) == 0)
            let crc = try number(index + 14, 4)
            let size = Int(try number(index + 18, 4))
            let nameSize = Int(try number(index + 26, 2)), extraSize = Int(try number(index + 28, 2))
            let contentStart = index + 30 + nameSize + extraSize
            guard contentStart + size <= bytes.count else { throw PDFConversionError.failed }
            let name = String(decoding: bytes[(index + 30)..<(index + 30 + nameSize)], as: UTF8.self)
            let content = Data(bytes[contentStart..<(contentStart + size)])
            #expect(PDFOfficeZIP.crc32(content) == crc)
            #expect(result[name] == nil)
            result[name] = content
            index = contentStart + size
        }
        #expect(try number(index, 4) == 0x02014B50)
        #expect(try number(bytes.count - 22, 4) == 0x06054B50)
        #expect(try Int(number(bytes.count - 12, 2)) == result.count)
        return result
    }
}
