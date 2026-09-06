import Foundation
import PDFKit
import Testing
@testable import AnnotateCore

@Suite("Responsive redaction export", .serialized)
@MainActor
struct ContentExportReviewTests {
    @Test("Redaction uses a stable snapshot even if the source changes between page yields")
    func snapshotExport() async throws {
        let source = try Fixtures.document()
        let region = PageRegion(pageIndex: 0, bounds: CGRect(x: 70, y: 200, width: 100, height: 30))
        var completed = 0
        let output = try await PDFContentEditor.redactedData(document: source, regions: [region]) { done, _ in
            completed = done
            if done == 1, source.pageCount == 4 { source.removePage(at: 3) }
        }
        let result = try #require(PDFDocument(data: output))
        #expect(source.pageCount == 3)
        #expect(result.pageCount == 4)
        #expect(completed == 4)
        let text = result.string ?? ""
        #expect(text.isEmpty)
        #expect((0..<result.pageCount).allSatisfy { result.page(at: $0)?.annotations.isEmpty == true })
    }

    @Test("Cancellation produces no export data")
    func cancellation() async throws {
        let source = try Fixtures.document()
        let task = Task { @MainActor in
            try await PDFContentEditor.redactedData(document: source,
                regions: [PageRegion(pageIndex: 0, bounds: CGRect(x: 70, y: 200, width: 100, height: 30))]) { _, _ in }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
