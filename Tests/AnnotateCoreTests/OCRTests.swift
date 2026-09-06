import AppKit
import PDFKit
import Testing
@testable import AnnotateCore

@Suite("Whole document OCR", .serialized)
@MainActor
struct OCRTests {
    @Test("Generated scanned pages gain searchable text with matching crop and rotation geometry", arguments: [0, 90, 180, 270])
    func searchableScans(rotation: Int) async throws {
        let document = try scannedDocument(rotation: rotation)
        let scannedText = document.page(at: 0)?.string ?? ""
        #expect(scannedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        var completedPages: [Int] = []
        let result = try await PDFOCR.recognize(document: document, options: PDFOCROptions(languages: ["en-US"])) { done, _ in
            completedPages.append(done)
        }
        let reopened = try #require(PDFDocument(data: result.data))
        #expect(result.recognizedPageCount == 2)
        #expect(result.retainedTextPageCount == 0)
        #expect(result.recognizedLineCount >= 2)
        #expect(completedPages.last == 2)
        #expect(reopened.pageCount == 2)
        #expect(result.text.localizedCaseInsensitiveContains("Rotation sentinel"))
        let matches = reopened.findString("Rotation sentinel", withOptions: .caseInsensitive)
        #expect(matches.count == 2)
        for index in 0..<2 {
            let sourcePage = try #require(document.page(at: index))
            let outputPage = try #require(reopened.page(at: index))
            let sourceRed = try Fixtures.redBounds(in: sourcePage)
            let outputRed = try Fixtures.redBounds(in: outputPage)
            #expect(abs(sourceRed.midX - outputRed.midX) <= 2)
            #expect(abs(sourceRed.midY - outputRed.midY) <= 2)
            #expect(outputPage.rotation == 0)
            let expectedSize = try PDFConversion.displayedSize(of: sourcePage)
            #expect(outputPage.bounds(for: .cropBox).size == expectedSize)
            let match = try #require(matches.first { $0.pages.contains(outputPage) })
            let selection = match.bounds(for: outputPage)
            #expect(selection.width > 0 && selection.height > 0)
            #expect(outputPage.bounds(for: .cropBox).intersects(selection))
            // The source text occupies x≈100…205, y≈253…270; the crop origin is (50,80).
            // Verify the invisible layer moved with /Rotate, not just the visible raster.
            let expectedCenter: CGPoint = switch rotation {
            case 90: CGPoint(x: 180, y: 177)
            case 180: CGPoint(x: 177, y: 160)
            case 270: CGPoint(x: 160, y: 103)
            default: CGPoint(x: 103, y: 180)
            }
            #expect(abs(selection.midX - expectedCenter.x) < 25)
            #expect(abs(selection.midY - expectedCenter.y) < 25)
        }
    }

    @Test("Existing text pages retain their vector text without duplicate OCR words")
    func existingTextPreserved() async throws {
        let document = try Fixtures.document()
        let before = document.findString("attention", withOptions: .caseInsensitive).count
        let result = try await PDFOCR.recognize(document: document)
        let output = try #require(PDFDocument(data: result.data))
        #expect(result.recognizedPageCount == 0)
        #expect(result.retainedTextPageCount == 4)
        #expect(output.findString("attention", withOptions: .caseInsensitive).count == before)
    }

    @Test("Recognizing every page replaces the old text layer and unsupported languages fail")
    func forceRecognitionAndLanguageValidation() async throws {
        let source = try Fixtures.geometryDocument(rotation: 0, crop: CGRect(x: 0, y: 0, width: 400, height: 500))
        let result = try await PDFOCR.recognize(document: source, options: PDFOCROptions(languages: ["en-US"], recognizeEveryPage: true))
        let output = try #require(PDFDocument(data: result.data))
        #expect(result.recognizedPageCount == 1)
        #expect(output.findString("Rotation sentinel", withOptions: .caseInsensitive).count == 1)
        await #expect(throws: (any Error).self) {
            _ = try await PDFOCR.recognize(document: source, options: PDFOCROptions(languages: ["invalid-language"], recognizeEveryPage: true))
        }
    }

    private func scannedDocument(rotation: Int) throws -> PDFDocument {
        let source = try Fixtures.geometryDocument(rotation: 0, crop: CGRect(x: 0, y: 0, width: 400, height: 500))
        let raster = try PDFConversion.renderedImage(page: #require(source.page(at: 0)), scale: 2)
        let document = PDFDocument()
        for index in 0..<2 {
            let page = try #require(PDFPage(image: NSImage(cgImage: raster, size: CGSize(width: 400, height: 500))))
            page.setBounds(CGRect(x: 50, y: 80, width: 280, height: 340), for: .cropBox)
            page.rotation = rotation
            document.insert(page, at: index)
        }
        return try Fixtures.reopen(document)
    }
}
