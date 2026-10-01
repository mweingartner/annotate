import Testing
@testable import AnnotateCore

@Suite("Assistant provider context privacy")
@MainActor
struct AssistantPrivacyTests {
    final class Model: DocumentAssistantGenerating {
        let provider: DocumentAssistantProvider
        var unavailabilityReason: String?
        init(_ provider: DocumentAssistantProvider) { self.provider = provider }
        var prompts: [String] = []
        func generate(instructions: String, prompt: String, maximumResponseTokens: Int) async throws -> String {
            prompts.append(prompt)
            return "Attention is discussed on page 1."
        }
    }

    @Test("Switching from local to either cloud provider excludes the prior local question", arguments: [DocumentAssistantProvider.openAI, .claude])
    func localQuestionStaysLocal(provider: DocumentAssistantProvider) async throws {
        let controller = DocumentAssistantController(), local = Model(.ollama), remote = Model(provider)
        let document = SamplePDF.make()
        let privateQuestion = "attention private-local-question-sentinel"
        await controller.submit(document: document, operation: .ask, question: privateQuestion, provider: .ollama, localModel: local).value
        #expect(local.prompts.count == 1)
        await controller.submit(document: document, operation: .ask, question: "attention", provider: provider).value
        let reviewed = try #require(controller.prepared)
        #expect(reviewed.includedPreviousQuestion == nil)
        #expect(!reviewed.prompt(for: reviewed.sources).contains(privateQuestion))
        #expect(remote.prompts.isEmpty)
        #expect(controller.answers.count == 1, "Changing providers preserves visible answer history, not hidden provider context.")
        await controller.generate(using: remote, providerName: provider.label).value
        #expect(remote.prompts.count == 1)
        #expect(remote.prompts.allSatisfy { !$0.contains(privateQuestion) })
    }

    @Test("Same-provider follow-ups expose the exact prior question that will be sent")
    func reviewedFollowUp() async throws {
        let controller = DocumentAssistantController(), model = Model(.openAI), document = SamplePDF.make()
        let firstQuestion = "attention first-reader-question-sentinel"
        await controller.submit(document: document, operation: .ask, question: firstQuestion, provider: .openAI).value
        await controller.generate(using: model, providerName: "OpenAI API").value
        await controller.submit(document: document, operation: .ask, question: "attention", provider: .openAI).value
        let request = try #require(controller.prepared)
        let disclosed = try #require(request.includedPreviousQuestion)
        #expect(disclosed == firstQuestion)
        #expect(request.prompt(for: request.sources).contains("Previous reader question, for follow-up context: " + disclosed))
        #expect(model.prompts.count == 1, "The follow-up must still wait for its own reviewed send.")
        await controller.generate(using: model, providerName: "OpenAI API").value
        #expect(model.prompts.count == 2)
        #expect(model.prompts.last?.contains(disclosed) == true)

        await controller.submit(document: document, operation: .summarize, provider: .openAI).value
        let summary = try #require(controller.prepared)
        #expect(summary.includedPreviousQuestion == nil)
        #expect(!summary.prompt(for: summary.sources).contains(firstQuestion))
    }

    @Test("Changing the selected provider immediately invalidates a pending reviewed send")
    func preparedRequestInvalidated() async throws {
        let controller = DocumentAssistantController(), model = Model(.claude), document = SamplePDF.make()
        await controller.submit(document: document, operation: .ask, question: "attention", provider: .openAI).value
        #expect(controller.prepared != nil)
        controller.selectProvider(.claude)
        #expect(controller.prepared == nil)
        await controller.generate(using: model, providerName: "Claude API").value
        #expect(model.prompts.isEmpty)
    }

    @Test("A request reviewed for one provider is never sent through another", arguments: [
        (DocumentAssistantProvider.openAI, DocumentAssistantProvider.claude), (.claude, .openAI), (.openAI, .ollama), (.claude, .apple)])
    func preparedRequestBoundToProvider(reviewed: DocumentAssistantProvider, other: DocumentAssistantProvider) async throws {
        let controller = DocumentAssistantController(), wrong = Model(other), document = SamplePDF.make()
        await controller.submit(document: document, operation: .ask, question: "attention", provider: reviewed,
                                settingsFingerprint: "settings-a").value
        #expect(try #require(controller.prepared).provider == reviewed)
        await controller.generate(using: wrong, providerName: other.label, settingsFingerprint: "settings-a").value
        #expect(wrong.prompts.isEmpty)
        #expect(controller.errorMessage == DocumentAssistantError.reviewedForAnotherProvider.errorDescription)
        #expect(controller.prepared == nil, "A mismatched request must be reviewed again.")
        #expect(controller.answers.isEmpty)
    }

    @Test("Changed AI settings require a fresh review before sending")
    func preparedRequestBoundToSettings() async throws {
        let controller = DocumentAssistantController(), model = Model(.openAI), document = SamplePDF.make()
        await controller.submit(document: document, operation: .ask, question: "attention", provider: .openAI,
                                settingsFingerprint: "openAI|model-a").value
        #expect(try #require(controller.prepared).settingsFingerprint == "openAI|model-a")
        await controller.generate(using: model, providerName: "OpenAI API", settingsFingerprint: "openAI|model-b").value
        #expect(model.prompts.isEmpty)
        #expect(controller.errorMessage == DocumentAssistantError.reviewedForAnotherProvider.errorDescription)

        await controller.submit(document: document, operation: .ask, question: "attention", provider: .openAI,
                                settingsFingerprint: "openAI|model-b").value
        await controller.generate(using: model, providerName: "OpenAI API", settingsFingerprint: "openAI|model-b").value
        #expect(model.prompts.count == 1)
        #expect(controller.errorMessage == nil)
        #expect(controller.answers.count == 1)
    }

    @Test("A local action never runs through a model for a different provider")
    func localActionBoundToProvider() async {
        let controller = DocumentAssistantController(), wrong = Model(.openAI), document = SamplePDF.make()
        await controller.submit(document: document, operation: .ask, question: "attention", provider: .ollama, localModel: wrong).value
        #expect(wrong.prompts.isEmpty)
        #expect(controller.errorMessage == DocumentAssistantError.reviewedForAnotherProvider.errorDescription)
        #expect(controller.answers.isEmpty)
    }
}
