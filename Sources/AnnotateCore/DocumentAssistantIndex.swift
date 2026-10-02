import Foundation
import PDFKit

/// A bounded, complete text snapshot. The budget applies to the entire PDF, never a prefix.
public struct DocumentAssistantIndex: Sendable {
    public static let maximumDocumentBytes = 16_000_000
    public static let maximumPageCount = 20_000
    public static let passageByteLimit = 1_400
    public static let contextByteLimit = 5_600

    public let sources: [DocumentAssistantSource]
    public let pageCount: Int
    public let pagesWithText: Int

    public init(sources: [DocumentAssistantSource], pageCount: Int, pagesWithText: Int) {
        self.sources = sources
        self.pageCount = pageCount
        self.pagesWithText = pagesWithText
    }

    @MainActor
    public static func extract(from document: PDFDocument,
                               progress: (Int, Int) -> Void = { _, _ in }) async throws -> Self {
        guard !document.isLocked, document.allowsCopying else { throw DocumentAssistantError.copyingRestricted }
        guard document.pageCount <= maximumPageCount else { throw DocumentAssistantError.documentTooLarge }
        var sources: [DocumentAssistantSource] = []
        var byteCount = 0
        var pagesWithText = 0
        let pageCount = document.pageCount
        for pageIndex in 0..<pageCount {
            try Task.checkCancellation()
            guard !document.isLocked, document.allowsCopying else { throw DocumentAssistantError.copyingRestricted }
            guard let page = document.page(at: pageIndex) else { throw AnnotateError.invalidPage(pageIndex) }
            let text = try PDFPageText.attributedText(from: page).string
            byteCount += text.utf8.count
            guard byteCount <= maximumDocumentBytes else { throw DocumentAssistantError.documentTooLarge }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pagesWithText += 1
                sources += chunks(text, pageNumber: pageIndex + 1)
            }
            progress(pageIndex + 1, pageCount)
            await Task.yield()
        }
        guard !sources.isEmpty else { throw DocumentAssistantError.noText }
        return Self(sources: sources, pageCount: pageCount, pagesWithText: pagesWithText)
    }

    /// Splits at Unicode scalar boundaries, preserving every scalar in order, including whitespace.
    public static func chunks(_ text: String, pageNumber: Int,
                              byteLimit: Int = passageByteLimit) -> [DocumentAssistantSource] {
        let limit = max(4, byteLimit)
        var result: [DocumentAssistantSource] = []
        var current = ""
        var count = 0
        for scalar in text.unicodeScalars {
            let size = scalar.utf8.count
            if count + size > limit, !current.isEmpty {
                // Prefer a word boundary so ordinary search terms are never cut in half.
                if let space = current.lastIndex(where: \.isWhitespace), space != current.startIndex {
                    let split = current.index(after: space)
                    result.append(.init(pageNumber: pageNumber, passageNumber: result.count + 1, text: String(current[..<split])))
                    current = String(current[split...])
                    count = current.utf8.count
                } else {
                    result.append(.init(pageNumber: pageNumber, passageNumber: result.count + 1, text: current))
                    current = ""
                    count = 0
                }
            }
            current.unicodeScalars.append(scalar)
            count += size
        }
        if !current.isEmpty {
            result.append(.init(pageNumber: pageNumber, passageNumber: result.count + 1, text: current))
        }
        return result
    }

    /// Scores every passage, including the final page. The result is a disclosed retrieval subset.
    public func retrieve(_ question: String, byteLimit: Int = contextByteLimit) -> [DocumentAssistantSource] {
        let normalized = Self.normalize(question)
        let terms = Self.terms(normalized)
        guard !terms.isEmpty else { return [] }
        let ranked = sources.enumerated().compactMap { offset, source -> (Int, Double)? in
            let text = Self.normalize(source.text)
            let words = Set(Self.terms(text))
            let matches = terms.reduce(0) { $0 + (words.contains($1) || text.contains($1) ? 1 : 0) }
            guard matches > 0 else { return nil }
            let phraseBonus = normalized.count >= 3 && text.contains(normalized) ? Double(terms.count + 2) : 0
            return (offset, Double(matches) + phraseBonus)
        }.sorted { left, right in
            left.1 == right.1 ? left.0 < right.0 : left.1 > right.1
        }
        var picked: [DocumentAssistantSource] = []
        var used = 0
        for (offset, _) in ranked {
            let source = sources[offset]
            let bytes = Self.evidenceText([source]).utf8.count + 2
            if used + bytes <= byteLimit {
                picked.append(source)
                used += bytes
            }
        }
        return picked
    }

    public static func evidenceText(_ sources: [DocumentAssistantSource]) -> String {
        sources.map { "[Page \($0.pageNumber), passage \($0.passageNumber)]\n\($0.text)" }.joined(separator: "\n\n")
    }

    public static func batches(_ sources: [DocumentAssistantSource],
                               byteLimit: Int = contextByteLimit) -> [[DocumentAssistantSource]] {
        var batches: [[DocumentAssistantSource]] = []
        var current: [DocumentAssistantSource] = []
        var count = 0
        for source in sources {
            let bytes = evidenceText([source]).utf8.count + 2
            if count + bytes > byteLimit, !current.isEmpty {
                batches.append(current)
                current = []
                count = 0
            }
            current.append(source)
            count += bytes
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    public var coverageDescription: String {
        let missing = pageCount - pagesWithText
        return "Read all \(pageCount) pages; \(pagesWithText) contain selectable text or visible text boxes/form values."
            + (missing > 0 ? " \(missing) pages have no selectable text and need OCR before their content can be included." : "")
            + " " + PDFPageText.orderingDescription
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func terms(_ text: String) -> [String] {
        let stopWords: Set<String> = ["a", "an", "and", "are", "as", "at", "be", "by", "can", "do", "does", "for", "from", "how", "i", "in", "is", "it", "of", "on", "or", "the", "their", "this", "to", "was", "what", "when", "where", "which", "who", "why", "with", "would"]
        let all = text.components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }
        let meaningful = all.filter { !stopWords.contains($0) }
        return Array(Set(meaningful.isEmpty ? all : meaningful)).sorted()
    }
}
