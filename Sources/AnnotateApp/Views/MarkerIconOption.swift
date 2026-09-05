struct MarkerIconOption: Identifiable {
    let name: String
    let symbol: String
    var id: String { symbol }

    static let all: [Self] = [
        .init(name: "Bookmark", symbol: "bookmark.fill"),
        .init(name: "Star", symbol: "star.fill"),
        .init(name: "Flag", symbol: "flag.fill"),
        .init(name: "Important", symbol: "exclamationmark"),
        .init(name: "Question", symbol: "questionmark"),
        .init(name: "Idea", symbol: "lightbulb.fill"),
        .init(name: "Complete", symbol: "checkmark"),
        .init(name: "Revisit", symbol: "arrow.clockwise")
    ]
}
