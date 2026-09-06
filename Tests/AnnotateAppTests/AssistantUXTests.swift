import AnnotateCore
import Foundation
import Testing
@testable import AnnotateApp

@Suite("Assistant composer and setup usability")
@MainActor
struct AssistantUXTests {
    @Test("Composer labels distinguish a direct local action from cloud review")
    func actionLabels() {
        #expect(AssistantInteraction.actionTitle(operation: .ask, provider: .ollama) == "Ask")
        #expect(AssistantInteraction.actionTitle(operation: .ask, provider: .apple) == "Ask")
        #expect(AssistantInteraction.actionTitle(operation: .ask, provider: .openAI).contains("Review"))
        #expect(AssistantInteraction.actionTitle(operation: .summarize, provider: .claude).contains("Review"))
        for provider in DocumentAssistantProvider.allCases {
            #expect(AssistantInteraction.actionTitle(operation: .evidence, provider: provider) == "Find sources")
        }
    }

    @Test("Empty questions and busy requests cannot submit while summaries need no typed prompt")
    func composerReadiness() {
        #expect(!AssistantInteraction.canSubmit(operation: .ask, question: " \n ", hasDocument: true, isBusy: false))
        #expect(!AssistantInteraction.canSubmit(operation: .ask, question: "Who?", hasDocument: true, isBusy: true))
        #expect(!AssistantInteraction.canSubmit(operation: .summarize, question: "", hasDocument: false, isBusy: false))
        #expect(AssistantInteraction.canSubmit(operation: .summarize, question: "", hasDocument: true, isBusy: false))
        #expect(AssistantInteraction.canSubmit(operation: .ask, question: "Who?", hasDocument: true, isBusy: false))
    }

    @Test("Model discovery selects a usable installed model and preserves an existing valid choice")
    func modelDiscovery() throws {
        let name = "assistant-ux-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = DocumentAssistantPreferences(defaults: defaults)
        settings.ollamaModel = "not-installed"
        settings.useDiscoveredModels(["z-model", "a-model"])
        #expect(settings.ollamaModel == "a-model")
        #expect(settings.availableOllamaModels == ["a-model", "z-model"])
        settings.ollamaModel = "z-model"
        settings.useDiscoveredModels(["a-model", "z-model"])
        #expect(settings.ollamaModel == "z-model")
        #expect(DocumentAssistantPreferences(defaults: defaults).ollamaModel == "z-model")
        settings.useDiscoveredModels([])
        #expect(settings.ollamaStatus.contains("No downloaded models"))
    }
}
