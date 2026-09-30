/// The icons a marker can wear. Filled SF Symbols read best at pin size; each has a
/// plain-text stand-in in the saved file (MarkerCodec) for other PDF readers.
/// Markers saved with an older icon keep it: any SF Symbol name still draws.
struct MarkerIconOption: Identifiable {
    let name: String
    let symbol: String
    var id: String { symbol }

    static let all: [Self] = [
        .init(name: "Star", symbol: "star.fill"),
        .init(name: "Bookmark", symbol: "bookmark.fill"),
        .init(name: "Flag", symbol: "flag.fill"),
        .init(name: "Pin", symbol: "pin.fill"),
        .init(name: "Important", symbol: "exclamationmark"),
        .init(name: "Question", symbol: "questionmark"),
        .init(name: "Idea", symbol: "lightbulb.max.fill"),
        .init(name: "Insight", symbol: "sparkles"),
        .init(name: "Quote", symbol: "quote.opening"),
        .init(name: "Favourite", symbol: "heart.fill"),
        .init(name: "Done", symbol: "checkmark"),
        .init(name: "Revisit", symbol: "arrow.trianglehead.clockwise")
    ]
}
