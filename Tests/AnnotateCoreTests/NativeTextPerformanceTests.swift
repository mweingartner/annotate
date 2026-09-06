import AppKit
import PDFKit
import Testing
@testable import AnnotateCore

@Suite("Native text editing representative document measurements", .serialized)
@MainActor
struct NativeTextPerformanceTests {
    @Test("Native replacement measures ordinary and long documents", arguments: [4, 100])
    func measuredReplacement(pageCount: Int) throws {
        let sample = SamplePDF.make(), source = PDFDocument()
        for index in 0..<pageCount { source.insert(try #require(sample.page(at: index % sample.pageCount)?.copy() as? PDFPage), at: index) }
        let sourceBytes = try #require(source.dataRepresentation())
        let selection = try #require(source.findString("attention", withOptions: []).first), page = try #require(source.page(at: 0))
        let region = PageRegion(pageIndex: 0, bounds: selection.bounds(for: page).insetBy(dx: 0, dy: -4))
        let start = ContinuousClock.now
        let result = try PDFNativeTextEditor.replace(in: source, region: region, originalText: "attention", replacement: NSAttributedString(string: "FOCUS", attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        let duration = start.duration(to: .now).components
        let milliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        print("NATIVE_REPLACE_MEASUREMENT pages=\(pageCount) inputBytes=\(sourceBytes.count) milliseconds=\(Int(milliseconds.rounded()))")
        #expect(result.pageCount == pageCount)
        #expect(result.findString("FOCUS", withOptions: []).count == 1)
    }
}
