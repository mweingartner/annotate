import AnnotateCore
import AppKit
import PDFKit
import SwiftUI
import Testing
@testable import AnnotateApp

/// Search shows its hits in batches about ten times a second instead of one at a time. These
/// tests hold the batched search to the same hits, in the same order, that a straight scan
/// of the document finds; check that what is shown while searching is always a prefix of the
/// final list; and that a replaced query never leaves a stale hit behind.
@Suite("Search results in batches", .serialized)
@MainActor
struct SearchBatchingTests {
    /// A long document: `pages` pages of paragraphs that mention the term (with and without
    /// an accent) several times each, plus a text box naming it on every fifth page.
    private func longDocument(paragraphs: Int = 260) throws -> PDFDocument {
        let text = (0..<paragraphs).map { index in
            "Paragraph \(index): the lumen reading falls, and LUMEN rises again; Lúmen \(index) is noted here. "
                + (index.isMultiple(of: 37) ? "A zephyr passes. " : "") + "Filler words keep the line long enough to wrap."
        }.joined(separator: "\n")
        let document = try PDFConversion.textDocument(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        let data = try #require(document.dataRepresentation())
        let reopened = try #require(PDFDocument(data: data))
        for index in stride(from: 0, to: reopened.pageCount, by: 5) {
            let page = try #require(reopened.page(at: index))
            let box = PDFAnnotation(bounds: CGRect(x: 60, y: 60, width: 200, height: 24), forType: .freeText, withProperties: nil)
            box.contents = "Lumen box on page \(index + 1)"
            page.addAnnotation(box)
        }
        return reopened
    }

    private struct Found: Equatable, CustomStringConvertible {
        let page: Int, text: String?, area: CGRect
        var description: String { "p\(page) \(text ?? "box") \(area)" }
    }

    /// Every hit a straight scan finds, in order: each page's text matches front to back,
    /// then its visible text boxes in reading order.
    private func scan(_ document: PDFDocument, for term: String) -> [Found] {
        var found: [Found] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if let text = page.string as NSString? {
                var cursor = 0
                while cursor < text.length {
                    let match = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: cursor, length: text.length - cursor))
                    guard match.location != NSNotFound, match.length > 0 else { break }
                    if let selection = page.selection(for: match) { found.append(Found(page: index, text: selection.string, area: selection.bounds(for: page))) }
                    cursor = NSMaxRange(match)
                }
            }
            for addition in (try? PDFPageText.visibleAnnotations(on: page)) ?? [] {
                let text = (addition.label + ": " + addition.text) as NSString
                if text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]).location != NSNotFound {
                    found.append(Found(page: index, text: nil, area: addition.bounds))
                }
            }
        }
        return found
    }

    private func found(_ hits: [SearchHit], in document: PDFDocument) -> [Found] {
        hits.map { hit in
            if let selection = hit.selection, let page = document.page(at: hit.pageIndex) {
                return Found(page: hit.pageIndex, text: selection.string, area: selection.bounds(for: page))
            }
            return Found(page: hit.pageIndex, text: nil, area: hit.bounds ?? .null)
        }
    }

    private func load(_ pdf: PDFDocument) -> AnnotateDocument {
        _ = NSApplication.shared
        let owner = AnnotateDocument()
        owner.model.load(pdf, owner: owner)
        return owner
    }

    /// Polls until the search finishes, returning every distinct list of hit identities shown
    /// on the way. The deadline only catches a search that never ends.
    private func watch(_ model: ReaderModel) async throws -> [[UUID]] {
        var shown: [[UUID]] = []
        let deadline = ContinuousClock.now + .seconds(60)
        while model.isSearching && ContinuousClock.now < deadline {
            let ids = model.searchResults.map(\.id)
            if ids != shown.last { shown.append(ids) }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!model.isSearching, "search should finish")
        return shown
    }

    @Test("A long search lists exactly the hits a straight scan finds, in the same order, and only ever grows")
    func sameHitsSameOrder() async throws {
        // Long enough that scanning spans many batch intervals, even in a release build.
        let pdf = try longDocument(paragraphs: 2_400)
        #expect(pdf.pageCount >= 8)
        let owner = load(pdf), model = owner.model
        let start = ContinuousClock.now
        model.query = "lumen"
        let shown = try await watch(model)
        let elapsed = start.duration(to: .now)
        let expected = scan(pdf, for: "lumen")
        #expect(expected.count > 600)
        #expect(expected.contains { $0.text == nil }, "text boxes are among the hits")
        let got = found(model.searchResults, in: pdf)
        #expect(got.count == expected.count)
        if let first = zip(got, expected).enumerated().first(where: { $0.element.0 != $0.element.1 }) {
            Issue.record("hit \(first.offset) differs: got \(first.element.0), expected \(first.element.1)")
        }
        // Each list shown while searching is a prefix of the final one: batches never reorder,
        // repeat or drop a hit.
        let final = model.searchResults.map(\.id)
        #expect(Set(final).count == final.count)
        for list in shown { #expect(Array(final.prefix(list.count)) == list) }
        let partial = shown.filter { !$0.isEmpty && $0.count < final.count }.count
        print("Search: \(final.count) hits in \(elapsed), \(partial) partial lists shown")
        // A search that takes well over a batch interval shows hits before it ends.
        if elapsed > .milliseconds(800) { #expect(partial > 0, "\(elapsed) without showing any hit") }
        for hit in model.searchResults {
            let snippet = String(hit.snippet.characters)
            #expect(snippet.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains("lumen"))
            #expect(!snippet.contains("\n"))
        }
        owner.close()
    }

    @Test("A query replaced mid-search leaves none of its hits, then or later")
    func replacedMidSearch() async throws {
        let pdf = try longDocument()
        let owner = load(pdf), model = owner.model
        model.query = "lumen"
        let deadline = ContinuousClock.now + .seconds(30)
        while model.searchResults.isEmpty && model.isSearching && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        model.query = "zephyr"
        #expect(model.searchResults.isEmpty, "replacing the query clears the list at once")
        _ = try await watch(model)
        let expected = scan(pdf, for: "zephyr")
        #expect(expected.count >= 5)
        #expect(found(model.searchResults, in: pdf) == expected)
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.searchResults.allSatisfy { $0.selection?.string?.lowercased() == "zephyr" })
        #expect(model.searchResults.count == expected.count)
        owner.close()
    }

    @Test("Clearing a long search mid-way stops it with nothing listed")
    func clearedMidSearch() async throws {
        let pdf = try longDocument()
        let owner = load(pdf), model = owner.model
        model.query = "lumen"
        try await Task.sleep(for: .milliseconds(300))
        model.query = ""
        #expect(model.searchResults.isEmpty && !model.isSearching)
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.searchResults.isEmpty && !model.isSearching)
        owner.close()
    }

    @Test("A term found nowhere in a long document finishes with no hits")
    func noHits() async throws {
        let pdf = try longDocument(paragraphs: 120)
        let owner = load(pdf), model = owner.model
        model.query = "quasar"
        let shown = try await watch(model)
        #expect(model.searchResults.isEmpty)
        #expect(shown.allSatisfy { $0.isEmpty })
        owner.close()
    }

    @Test("A term found on one page only, at the end, is shown when the search finishes")
    func lastPageOnly() async throws {
        let pdf = try longDocument(paragraphs: 120)
        let last = try #require(pdf.page(at: pdf.pageCount - 1))
        let box = PDFAnnotation(bounds: CGRect(x: 80, y: 300, width: 200, height: 24), forType: .freeText, withProperties: nil)
        box.contents = "Omega marker"
        last.addAnnotation(box)
        let owner = load(pdf), model = owner.model
        model.query = "omega"
        _ = try await watch(model)
        #expect(model.searchResults.count == 1)
        #expect(model.searchResults.first?.pageIndex == pdf.pageCount - 1)
        #expect(model.searchResults.first?.bounds == box.bounds)
        owner.close()
    }
}
