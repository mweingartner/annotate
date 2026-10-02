import AppKit
import Foundation
import PDFKit
import Testing
@testable import AnnotateCore

/// Each size and work limit tried exactly at its value and one past it, so a limit that
/// moves without its checks (or a `<` that should be `<=`) is caught. Limits with a name are
/// referenced by it; the rest are spelled out beside a note of where they are enforced.
@Suite("Resource limits: exactly at the limit, and one past")
@MainActor
struct ResourceLimitBoundaryTests {
    private static let mebibyte = 1_048_576

    // MARK: Markers

    /// The marker's own metadata string, as stored on its first highlight.
    private func payload(of marker: PDFMarker, in document: PDFDocument) throws -> (PDFAnnotation, String) {
        let annotations = (0..<document.pageCount).flatMap { document.page(at: $0)?.annotations ?? [] }
        let carrier = try #require(annotations.first {
            $0.value(forAnnotationKey: MarkerCodec.identifierKey) as? String == marker.id.uuidString
                && $0.value(forAnnotationKey: MarkerCodec.metadataKey) is String
        })
        return (carrier, try #require(carrier.value(forAnnotationKey: MarkerCodec.metadataKey) as? String))
    }

    private func isMetadataTooLarge(_ error: any Error) -> Bool {
        if case .metadataTooLarge? = error as? AnnotateError { return true }
        return false
    }

    /// MarkerCodec.validate: quote, note and question are each limited to 1 MiB of UTF-8.
    @Test("A marker's quote, note and question each hold exactly 1 MiB of UTF-8, not one byte more",
          arguments: ["quote", "note", "question"])
    func markerFieldLimit(field: String) throws {
        let document = try Fixtures.document()
        let original = try Fixtures.marker(in: document)
        try MarkerCodec.apply(original, to: document)
        func with(_ text: String) -> PDFMarker {
            var marker = original
            switch field {
            case "quote": marker.quote = text
            case "note": marker.note = text
            default: marker.question = text
            }
            return marker
        }
        // Multi-byte text counts bytes, not characters: 524,288 two-byte "é" fill the limit.
        let full = String(repeating: "é", count: Self.mebibyte / 2)
        #expect(full.utf8.count == Self.mebibyte)
        let atLimit = with(full)
        try MarkerCodec.apply(atLimit, to: document)
        #expect(MarkerCodec.markers(in: document) == [atLimit], "Written and read back whole")
        #expect { try MarkerCodec.apply(with(full + "a"), to: document) } throws: { isMetadataTooLarge($0) }
        #expect(MarkerCodec.markers(in: document) == [atLimit], "The refused change leaves the saved marker alone")
    }

    @Test("A payload of exactly the metadata limit is written and read; one byte more is refused and skipped")
    func markerPayloadLimit() throws {
        let document = try Fixtures.document()
        var marker = try Fixtures.marker(in: document, note: "", question: "")
        marker.quote = String(repeating: "q", count: Self.mebibyte)
        try MarkerCodec.apply(marker, to: document)
        let base = try payload(of: marker, in: document).1.utf8.count
        // ASCII letters encode as themselves in JSON, so the note can top the payload up exactly.
        let room = MarkerCodec.maximumMetadataBytes - base
        #expect(room > 0 && room <= Self.mebibyte)
        marker.note = String(repeating: "n", count: room)
        try MarkerCodec.apply(marker, to: document)
        let (carrier, stored) = try payload(of: marker, in: document)
        #expect(stored.utf8.count == MarkerCodec.maximumMetadataBytes)
        #expect(MarkerCodec.markers(in: document) == [marker])
        // The writer refuses one byte more…
        var over = marker
        over.note += "n"
        #expect { try MarkerCodec.apply(over, to: document) } throws: { isMetadataTooLarge($0) }
        #expect(MarkerCodec.markers(in: document) == [marker])
        // …and the reader skips a payload one byte over that some other writer stored.
        let oversized = stored.replacingOccurrences(of: "\"note\":\"n", with: "\"note\":\"nn")
        #expect(oversized.utf8.count == MarkerCodec.maximumMetadataBytes + 1)
        carrier.setValue(oversized, forAnnotationKey: MarkerCodec.metadataKey)
        #expect(MarkerCodec.markers(in: document).isEmpty)
    }

    /// MarkerCodec.validate: at most 20,000 regions.
    @Test("A marker may cover exactly 20,000 regions, not one more")
    func markerRegionLimit() throws {
        let document = try Fixtures.document()
        let original = try Fixtures.marker(in: document)
        let region = try #require(original.regions.first)
        var marker = original
        marker.regions = Array(repeating: region, count: 20_000)
        try MarkerCodec.validate(marker, in: document)
        marker.regions.append(region)
        #expect {
            try MarkerCodec.validate(marker, in: document)
        } throws: { error in
            guard case .invalidMarker(let reason)? = error as? AnnotateError else { return false }
            return reason.contains("shorter selection")
        }
    }

    @Test("Reading stops exactly when the decoded-metadata budget is spent, counting every payload it reads")
    func markerDecodedBudget() throws {
        for extra in [0, 1] {
            let document = try Fixtures.document()
            let marker = try Fixtures.marker(in: document)
            let page = try #require(document.page(at: marker.regions[0].pageIndex))
            // Payloads that are read and counted but aren't markers come first on the page…
            let probe = try Fixtures.document()
            try MarkerCodec.apply(marker, to: probe)
            let size = try payload(of: marker, in: probe).1.utf8.count
            var junk = MarkerCodec.maximumDecodedMetadataBytes - size + extra
            while junk > 0 {
                let chunk = min(junk, MarkerCodec.maximumMetadataBytes)
                let annotation = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 10, height: 10), forType: .square, withProperties: nil)
                annotation.setValue(MarkerCodec.ownerValue, forAnnotationKey: MarkerCodec.ownerKey)
                annotation.setValue(UUID().uuidString, forAnnotationKey: MarkerCodec.identifierKey)
                annotation.setValue(String(repeating: "x", count: chunk), forAnnotationKey: MarkerCodec.metadataKey)
                page.addAnnotation(annotation)
                junk -= chunk
            }
            // …then the real marker, which lands exactly on the budget, or one byte past it.
            try MarkerCodec.apply(marker, to: document)
            #expect(MarkerCodec.markers(in: document) == (extra == 0 ? [marker] : []), "\(extra) byte(s) over")
        }
    }

    @Test("Reading keeps at most the marker limit: every marker of a document at the limit, and drops the one past it")
    func markerCountLimit() throws {
        let document = PDFDocument()
        let page = PDFPage()
        document.insert(page, at: 0)
        let template = PDFMarker(categories: [.important], color: MarkerColor(red: 1, green: 0.8, blue: 0), icon: "star.fill",
                                 quote: "q", note: "", question: "",
                                 regions: [PageRegion(pageIndex: 0, bounds: CGRect(x: 72, y: 72, width: 40, height: 12))],
                                 createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try MarkerCodec.apply(template, to: document)
        let stored = try payload(of: template, in: document).1
        page.annotations.forEach(page.removeAnnotation)
        var ids: [UUID] = []
        for _ in 0...MarkerCodec.maximumMarkers {
            let id = UUID()
            ids.append(id)
            let annotation = PDFAnnotation(bounds: CGRect(x: 72, y: 72, width: 40, height: 12), forType: .highlight, withProperties: nil)
            annotation.setValue(MarkerCodec.ownerValue, forAnnotationKey: MarkerCodec.ownerKey)
            annotation.setValue(id.uuidString, forAnnotationKey: MarkerCodec.identifierKey)
            annotation.setValue(stored.replacingOccurrences(of: template.id.uuidString, with: id.uuidString), forAnnotationKey: MarkerCodec.metadataKey)
            page.addAnnotation(annotation)
        }
        let past = MarkerCodec.markers(in: document)
        #expect(past.count == MarkerCodec.maximumMarkers)
        #expect(Set(past.map(\.id)) == Set(ids.dropLast()), "The first ones on the page are kept")
        page.removeAnnotation(try #require(page.annotations.last))
        #expect(MarkerCodec.markers(in: document).count == MarkerCodec.maximumMarkers)
    }

    // MARK: Assistant

    /// A page whose extracted text is fixed, without laying out megabytes of PDF text.
    private final class FixedTextPage: PDFPage {
        private let text: String
        init(text: String) { self.text = text; super.init() }
        override var attributedString: NSAttributedString? { NSAttributedString(string: text) }
    }

    private func isDocumentTooLarge(_ error: any Error) -> Bool { error as? DocumentAssistantError == .documentTooLarge }

    @Test("The assistant reads a document of exactly the page limit; one page more is refused before reading")
    func assistantPageLimit() async throws {
        let document = PDFDocument()
        for index in 0..<DocumentAssistantIndex.maximumPageCount { document.insert(PDFPage(), at: index) }
        var read = 0
        // Blank pages: every one is read, and only then is the document found to have no text.
        await #expect(throws: DocumentAssistantError.noText) {
            _ = try await DocumentAssistantIndex.extract(from: document) { done, _ in read = done }
        }
        #expect(read == DocumentAssistantIndex.maximumPageCount)
        document.insert(PDFPage(), at: document.pageCount)
        read = 0
        await #expect(throws: DocumentAssistantError.documentTooLarge) {
            _ = try await DocumentAssistantIndex.extract(from: document) { done, _ in read = done }
        }
        #expect(read == 0)
    }

    @Test("The assistant's text budget covers the whole document: exactly the limit is read, one byte more is refused")
    func assistantByteLimit() async throws {
        let limit = DocumentAssistantIndex.maximumDocumentBytes
        // Spread over two pages, so the budget must be summed, not checked per page. Spaces
        // keep the snapshot from chunking megabytes; the count is what's under test.
        for (extra, expected) in [(0, DocumentAssistantError.noText), (1, .documentTooLarge)] {
            let document = PDFDocument()
            document.insert(FixedTextPage(text: String(repeating: " ", count: limit / 2)), at: 0)
            document.insert(FixedTextPage(text: String(repeating: " ", count: limit - limit / 2 + extra)), at: 1)
            await #expect(throws: expected, "\(extra) byte(s) over") { _ = try await DocumentAssistantIndex.extract(from: document) }
        }
    }

    // MARK: Certificates

    private func isInvalidEnvelope(_ error: any Error) -> Bool {
        if case .invalidEnvelope? = error as? PDFCertificateError { return true }
        return false
    }

    /// DER for a SEQUENCE holding one OCTET STRING, `total` bytes in all (3-byte lengths).
    private func sequenceOfOctets(total: Int) -> Data {
        let inner = total - 10, outer = total - 5
        func length(_ value: Int) -> [UInt8] { [0x83, UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        let header: [UInt8] = [0x30] + length(outer) + [0x04] + length(inner)
        return Data(header + [UInt8](repeating: 0xAB, count: inner))
    }

    /// PDFCertificateDER.encode: envelopes up to 2 MiB.
    @Test("A signature envelope of exactly 2 MiB is canonicalized; one byte more is refused")
    func envelopeSizeLimit() throws {
        let limit = 2 * Self.mebibyte
        let atLimit = sequenceOfOctets(total: limit)
        #expect(atLimit.count == limit)
        #expect(try PDFCertificateDER.encode(atLimit) == atLimit, "Already canonical DER comes back unchanged")
        let over = sequenceOfOctets(total: limit + 1)
        #expect(over.count == limit + 1)
        #expect { try PDFCertificateDER.encode(over) } throws: { isInvalidEnvelope($0) }
    }

    /// PDFCertificateDER.encode: at most 20,000 elements, the outer SEQUENCE included.
    @Test("A signature envelope of exactly 20,000 elements is canonicalized; one more is refused")
    func envelopeNodeLimit() throws {
        func sequence(nulls count: Int) -> Data {
            let body: [UInt8] = Array(repeating: [UInt8(0x05), UInt8(0x00)], count: count).flatMap { $0 }
            let header: [UInt8] = [0x30, 0x82, UInt8(body.count >> 8), UInt8(body.count & 0xFF)]
            return Data(header + body)
        }
        let atLimit = sequence(nulls: 19_999)
        #expect(try PDFCertificateDER.encode(atLimit) == atLimit)
        #expect { try PDFCertificateDER.encode(sequence(nulls: 20_000)) } throws: { isInvalidEnvelope($0) }
    }

    // MARK: Conversion

    private func isInputTooLarge(_ error: any Error) -> Bool {
        if case .inputTooLarge? = error as? PDFConversionError { return true }
        return false
    }

    private func isInvalidPage(_ error: any Error) -> Bool {
        if case .invalidPage? = error as? PDFConversionError { return true }
        return false
    }

    @Test("An input file of exactly the conversion limit is opened; one byte more is refused unread")
    func conversionInputLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "annotate-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Sparse files: a gigabyte that takes no disk space and is never read.
        func file(size: Int) throws -> URL {
            let url = directory.appending(path: "input-\(size).png")
            #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(size))
            try handle.close()
            return url
        }
        // At the limit it gets past the size check to the image decoder, which finds no image.
        #expect {
            _ = try PDFConversion.importDocument(from: try file(size: PDFConversion.maximumInputBytes))
        } throws: { error in
            guard case .unsupportedInput? = error as? PDFConversionError else { return false }
            return true
        }
        #expect { _ = try PDFConversion.importDocument(from: try file(size: PDFConversion.maximumInputBytes + 1)) } throws: { isInputTooLarge($0) }
    }

    private func page(width: Double, height: Double) -> (PDFDocument, PDFPage) {
        let document = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: width, height: height), for: .mediaBox)
        document.insert(page, at: 0)
        return (document, page)
    }

    /// PDFConversion.renderedImage: 32,768 pixels a side, 64,000,000 in all.
    @Test("Page images render exactly 32,768 pixels wide; one pixel more, or more than 64 million pixels, is refused")
    func renderedImageLimits() throws {
        let (document, atLimit) = page(width: 16_384, height: 1)
        let image = try PDFConversion.renderedImage(page: atLimit, scale: 2)
        #expect(image.width == 32_768)
        #expect(image.height == 2)
        let (_, wider) = page(width: 16_384.5, height: 1)
        #expect { _ = try PDFConversion.renderedImage(page: wider, scale: 2) } throws: { isInvalidPage($0) }
        // 8,000 × 8,001 pixels: each side well within 32,768, the area 8,000 past the limit.
        let (_, larger) = page(width: 4_000, height: 4_000.5)
        #expect { _ = try PDFConversion.renderedImage(page: larger, scale: 2) } throws: { isInvalidPage($0) }
        withExtendedLifetime(document) {}
    }

    private func isContentTooLarge(_ error: any Error) -> Bool {
        if case .tooLarge? = error as? PDFContentError { return true }
        return false
    }

    /// PDFContentEditor.raster: 32,768 pixels a side, 80,000,000 in all.
    @Test("Area rasters are made exactly 32,768 pixels wide; one more, or more than 80 million pixels, is refused")
    func rasterLimits() throws {
        let (document, atLimit) = page(width: 32_768, height: 1)
        let (image, _) = try PDFContentEditor.raster(atLimit, erase: [], fill: .white, scale: 1)
        #expect(image.width == 32_768)
        let (_, wider) = page(width: 32_769, height: 1)
        #expect { _ = try PDFContentEditor.raster(wider, erase: [], fill: .white, scale: 1) } throws: { isContentTooLarge($0) }
        let (_, larger) = page(width: 8_000, height: 10_001)
        #expect { _ = try PDFContentEditor.raster(larger, erase: [], fill: .white, scale: 1) } throws: { isContentTooLarge($0) }
        withExtendedLifetime(document) {}
    }

    /// PDFOfficeExporter: spreadsheets up to 20,000 pages, presentations up to 2,000.
    @Test("Office exports take documents of exactly their page limits; one page more is refused before any work")
    func officePageLimits() throws {
        let document = PDFDocument()
        for index in 0..<2_000 { document.insert(PDFPage(), at: index) }
        // One page past the presentation limit is refused before any slide is drawn. (At the
        // limit it would draw two thousand slides, too slow to check here.)
        document.insert(PDFPage(), at: document.pageCount)
        #expect { _ = try PDFOfficeExporter.presentation(document) } throws: { isInputTooLarge($0) }
        while document.pageCount < 20_000 { document.insert(PDFPage(), at: document.pageCount) }
        // Exactly the spreadsheet limit: every page is read; blank pages have no text cells.
        #expect {
            _ = try PDFOfficeExporter.spreadsheet(document)
        } throws: { error in
            guard case .noText? = error as? PDFConversionError else { return false }
            return true
        }
        document.insert(PDFPage(), at: document.pageCount)
        #expect { _ = try PDFOfficeExporter.spreadsheet(document) } throws: { isInputTooLarge($0) }
    }
}
