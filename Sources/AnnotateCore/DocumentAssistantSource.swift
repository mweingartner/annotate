import Foundation

/// Verbatim PDF text. Page numbers are one-based; they never come from model output.
public struct DocumentAssistantSource: Identifiable, Equatable, Sendable {
    public let pageNumber: Int
    public let passageNumber: Int
    public let text: String

    public var id: String { "\(pageNumber):\(passageNumber)" }
    public var label: String { "Page \(pageNumber) · passage \(passageNumber)" }

    public init(pageNumber: Int, passageNumber: Int = 1, text: String) {
        self.pageNumber = pageNumber
        self.passageNumber = passageNumber
        self.text = text
    }
}
