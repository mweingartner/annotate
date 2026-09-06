import AnnotateCore
import Foundation

enum AssistantInteraction {
    static func actionTitle(operation: DocumentAssistantOperation, provider: DocumentAssistantProvider) -> String {
        if operation == .evidence { return "Find sources" }
        if provider.requiresAPIKey { return "Review before sending…" }
        switch operation {
        case .ask: return "Ask"
        case .summarize: return "Summarize"
        case .keyDetails: return "Find key details"
        case .explain: return "Explain selection"
        case .translate: return "Translate selection"
        case .evidence: return "Find sources"
        }
    }

    static func canSubmit(operation: DocumentAssistantOperation, question: String, hasDocument: Bool, isBusy: Bool) -> Bool {
        hasDocument && !isBusy && (!operation.needsQuestion || !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
