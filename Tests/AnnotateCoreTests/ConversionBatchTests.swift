import Foundation
import PDFKit
import Testing
@testable import AnnotateCore

@Suite("Batch conversion safety", .serialized)
@MainActor
struct ConversionBatchTests {
    @Test("Every input has an independent result and existing files remain byte-identical")
    func individualFailuresAndCollision() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AnnotateBatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "report.pdf")
        try #require(Fixtures.document().dataRepresentation()).write(to: input)
        let badInput = directory.appending(path: "corrupt.pdf")
        try Data("not a PDF".utf8).write(to: badInput)
        let existing = directory.appending(path: "report.txt")
        let sentinel = Data("Do not replace my existing file".utf8)
        try sentinel.write(to: existing)
        let results = await PDFConversionBatch.run(inputs: [badInput, input], outputDirectory: directory, operation: .convert(.text))
        #expect(results.count == 2)
        #expect(!results[0].succeeded)
        #expect(results[1].succeeded)
        #expect(results[1].output?.lastPathComponent == "report-2.txt")
        #expect(try Data(contentsOf: existing) == sentinel)
        #expect(try String(contentsOf: #require(results[1].output), encoding: .utf8).contains("attention"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".annotate-") })
    }

    @Test("Image batches create ordered page files inside a uniquely named result folder")
    func pageFolders() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AnnotateImages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try Fixtures.document()
        let first = try await PDFConversionBatch.export(document: document, format: .png, name: "report", to: directory, scale: 1)
        let second = try await PDFConversionBatch.export(document: document, format: .png, name: "report", to: directory, scale: 1)
        #expect(first != second)
        #expect(try FileManager.default.contentsOfDirectory(atPath: first.path).sorted() == ["Page-0001.png", "Page-0002.png", "Page-0003.png", "Page-0004.png"])
        #expect(second.lastPathComponent == "report-png-2")
    }

    @Test("Cancellation after the last rendered page publishes no output and removes staging files")
    func finalPageCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AnnotateCancelled-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try Fixtures.document()
        let operation = Task { @MainActor in
            try await PDFConversionBatch.export(document: document, format: .png, name: "cancelled", to: directory, scale: 1) { done, total in
                if done == total { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            _ = try await operation.value
            Issue.record("Cancelled export unexpectedly published an output folder")
        } catch is CancellationError { }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
