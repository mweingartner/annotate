import Foundation
import PDFKit
import Testing
@testable import AnnotateCore

@Suite("Document assistant indexing and evidence")
@MainActor
struct AssistantIndexTests {
    @Test("Unicode chunking preserves the entire source and a bounded UTF-8 budget")
    func unicodeChunks() {
        let original = String(repeating: "Résumé café 中文 👩🏽‍🔬 e\u{301}\n", count: 100)
        let chunks = DocumentAssistantIndex.chunks(original, pageNumber: 9, byteLimit: 93)
        #expect(chunks.map(\.text).joined() == original)
        #expect(chunks.allSatisfy { $0.text.utf8.count <= 93 })
        #expect(chunks.allSatisfy { $0.pageNumber == 9 })
        #expect(Set(chunks.map(\.id)).count == chunks.count)
    }

    @Test("Question retrieval sees late pages and accented source text")
    func latePageRetrieval() {
        let sources = (1...300).map { page in
            DocumentAssistantSource(pageNumber: page, text: page == 300 ? "The résumé belongs to Dr. Mendel, who discovered the cobalt sentinel." : "General introductory material.")
        }
        let index = DocumentAssistantIndex(sources: sources, pageCount: 300, pagesWithText: 300)
        #expect(index.retrieve("Who discovered the cobalt sentinel?").first?.pageNumber == 300)
        #expect(index.retrieve("resume").first?.pageNumber == 300)
        #expect(index.retrieve("xylophone").isEmpty)
    }

    @Test("Batches cover every source exactly once and account for citation headers")
    func completeBatches() {
        let sources = (1...70).flatMap { page in
            DocumentAssistantIndex.chunks(String(repeating: "Specific page evidence. ", count: 80), pageNumber: page)
        }
        let batches = DocumentAssistantIndex.batches(sources)
        #expect(batches.count > 1)
        #expect(batches.flatMap { $0 } == sources)
        #expect(batches.allSatisfy { DocumentAssistantIndex.evidenceText($0).utf8.count <= DocumentAssistantIndex.contextByteLimit })
    }

    @Test("Preparation reads all pages and discloses image-only pages")
    func mixedPDF() async throws {
        let document = SamplePDF.make()
        document.insert(PDFPage(), at: document.pageCount)
        let index = try await DocumentAssistantIndex.extract(from: document)
        #expect(index.pageCount == 5)
        #expect(index.pagesWithText == 4)
        #expect(index.coverageDescription.contains("1 pages have no selectable text"))
        for number in 1...4 { #expect(index.sources.contains { $0.pageNumber == number }) }
    }

    @Test("Locked and copy-restricted PDFs cannot be used by the assistant")
    func restrictions() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-restricted-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(SamplePDF.make().write(to: url, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "reader", .accessPermissionsOption: 0]))
        let document = try #require(PDFDocument(url: url))
        await #expect(throws: DocumentAssistantError.copyingRestricted) { try await DocumentAssistantIndex.extract(from: document) }
        #expect(document.unlock(withPassword: "reader"))
        #expect(!document.allowsCopying)
        await #expect(throws: DocumentAssistantError.copyingRestricted) { try await DocumentAssistantIndex.extract(from: document) }
    }

    @Test("Cancelled extraction returns no partial snapshot")
    func cancelExtraction() async {
        let task = Task { try await DocumentAssistantIndex.extract(from: SamplePDF.make()) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled extraction unexpectedly succeeded") }
        catch { #expect(error is CancellationError) }
    }
}
