import AnnotateCore

enum MarkerPresentation {
    /// Line regions can repeat pages and span nonconsecutive pages.
    static func pageLabel(regions: [PageRegion]) -> String {
        let pages = Set(regions.map { $0.pageIndex + 1 }).sorted()
        guard let first = pages.first else { return "No page" }
        guard pages.count > 1 else { return "Page \(first)" }
        var ranges: [String] = []
        var start = first, end = first
        for page in pages.dropFirst() {
            if page == end + 1 { end = page }
            else {
                ranges.append(start == end ? "\(start)" : "\(start)–\(end)")
                start = page
                end = page
            }
        }
        ranges.append(start == end ? "\(start)" : "\(start)–\(end)")
        return "Pages " + ranges.joined(separator: ", ")
    }
}
