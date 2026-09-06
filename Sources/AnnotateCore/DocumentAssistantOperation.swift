import Foundation

public enum DocumentAssistantOperation: String, CaseIterable, Identifiable, Sendable {
    case ask = "Ask the document"
    case summarize = "Summarize document"
    case keyDetails = "Find key details"
    case explain = "Explain selection"
    case translate = "Translate selection"
    case evidence = "Find source passages"

    public var id: String { rawValue }
    public var needsSelection: Bool { self == .explain || self == .translate }
    public var needsQuestion: Bool { self == .ask || self == .evidence }
    public var coversWholeDocument: Bool { self == .summarize || self == .keyDetails }
}
