import Foundation

public enum PDFPageRange {
    /// Human page numbers, such as "1, 3-5". Empty or "all" selects every page.
    public static func parse(_ text: String, pageCount: Int) throws -> IndexSet {
        guard pageCount > 0 else { throw AnnotateError.emptyDocument }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if clean.isEmpty || clean == "all" { return IndexSet(integersIn: 0..<pageCount) }
        var result = IndexSet()
        for token in clean.split(separator: ",", omittingEmptySubsequences: false) {
            let pieces = token.replacing("–", with: "-").split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard (1...2).contains(pieces.count), let start = Int(pieces[0]), (1...pageCount).contains(start) else {
                throw PDFPageOperationError.invalidOrder
            }
            let end: Int
            if pieces.count == 2 {
                guard let last = Int(pieces[1]), last >= start, last <= pageCount else { throw PDFPageOperationError.invalidOrder }
                end = last
            } else { end = start }
            result.insert(integersIn: (start - 1)..<end)
        }
        return result
    }
}
