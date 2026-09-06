import AppKit
import CoreGraphics
import PDFKit
import Testing
@testable import AnnotateCore

@Suite("Native PDF object graph", .serialized)
@MainActor
struct NativeObjectGraphTests {
    @Test("Resolved stream graph roundtrips page text, geometry, annotations and form values")
    func roundTrip() throws {
        let source = SamplePDF.make()
        let first = try #require(source.page(at: 0))
        first.rotation = 90
        first.setBounds(CGRect(x: 20, y: 30, width: 500, height: 650), for: .cropBox)
        try PDFFormEditor.create(in: source, region: PageRegion(pageIndex: 1, bounds: CGRect(x: 50, y: 70, width: 200, height: 24)), name: "PreservedField", kind: .text)
        try PDFFormEditor.fill(in: source, field: #require(PDFFormEditor.fields(in: source).first), value: "Graph roundtrip 735")
        let data = try #require(source.dataRepresentation())
        let provider = try #require(CGDataProvider(data: data as CFData))
        let original = try #require(CGPDFDocument(provider))
        let graph = try PDFNativeObjectGraph(document: original)
        let output = try graph.write()
        let reopened = try #require(PDFDocument(data: output))
        #expect(reopened.pageCount == source.pageCount)
        #expect(reopened.string == source.string)
        #expect(reopened.page(at: 0)?.rotation == 90)
        #expect(reopened.page(at: 0)?.bounds(for: .cropBox) == first.bounds(for: .cropBox))
        #expect(PDFFormEditor.fields(in: reopened).first?.value == "Graph roundtrip 735")
        for index in 0..<source.pageCount {
            let before = try #require(source.page(at: index))
            let after = try #require(reopened.page(at: index))
            let originalImage = try PDFConversion.renderedImage(page: before, scale: 1)
            let newImage = try PDFConversion.renderedImage(page: after, scale: 1)
            #expect(originalImage.width == newImage.width && originalImage.height == newImage.height)
            #expect(originalImage.dataProvider?.data == newImage.dataProvider?.data)
        }
    }

    @Test("Unreachable old streams are omitted while surviving pages retain their content")
    func reachability() throws {
        let source = SamplePDF.make()
        let data = try #require(source.dataRepresentation())
        let provider = try #require(CGDataProvider(data: data as CFData))
        let original = try #require(CGPDFDocument(provider))
        let graph = try PDFNativeObjectGraph(document: original)
        _ = try graph.appendStream(data: Data("UNREACHABLE_SOURCE_SENTINEL_775".utf8))
        let first = try #require(original.page(at: 1))
        let dictionary = try #require(first.dictionary)
        let id = try #require(graph.objectID(for: dictionary))
        guard case .dictionary(var entries) = graph[id] else { Issue.record("Page dictionary missing"); return }
        entries["Contents"] = try graph.appendStream(data: Data())
        graph[id] = .dictionary(entries)
        let output = try graph.write()
        #expect(output.range(of: Data("UNREACHABLE_SOURCE_SENTINEL_775".utf8)) == nil)
        let reopened = try #require(PDFDocument(data: output))
        let emptiedText = reopened.page(at: 0)?.string ?? ""
        #expect(emptiedText.isEmpty)
        #expect(reopened.page(at: 1)?.string == source.page(at: 1)?.string)
    }
}
