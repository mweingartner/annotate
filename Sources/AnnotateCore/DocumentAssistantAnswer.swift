import Foundation

public struct DocumentAssistantAnswer: Identifiable, Sendable {
    public let id = UUID()
    public let title: String
    public let content: String
    public let coverage: String
    public let sources: [DocumentAssistantSource]
    public let isGenerated: Bool
    public let generatedBy: String?

    public init(title: String, content: String, coverage: String, sources: [DocumentAssistantSource],
                isGenerated: Bool, generatedBy: String? = nil) {
        self.title = title; self.content = content; self.coverage = coverage
        self.sources = sources; self.isGenerated = isGenerated; self.generatedBy = generatedBy
    }
}
