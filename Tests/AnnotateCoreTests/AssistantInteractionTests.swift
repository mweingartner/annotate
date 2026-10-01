import Foundation
import Testing
@testable import AnnotateCore

@Suite("Assistant direct local and reviewed cloud interactions")
@MainActor
struct AssistantInteractionTests {
    @MainActor
    final class Model: DocumentAssistantGenerating {
        let provider: DocumentAssistantProvider
        var unavailabilityReason: String?
        init(_ provider: DocumentAssistantProvider) { self.provider = provider }
        var calls = 0
        func generate(instructions: String, prompt: String, maximumResponseTokens: Int) async throws -> String {
            calls += 1
            return "Read with attention. [Page 1]"
        }
    }

    @Test("One local action reads evidence and answers", arguments: [DocumentAssistantProvider.ollama, .apple])
    func localAction(provider: DocumentAssistantProvider) async {
        let controller = DocumentAssistantController(), model = Model(provider)
        let document = SamplePDF.make()
        await controller.submit(document: document, operation: .ask, question: "attention", provider: provider, localModel: model).value
        #expect(model.calls == 1)
        #expect(controller.answers.count == 1)
        #expect(controller.answers.first?.sources.isEmpty == false)
        #expect(controller.prepared == nil)
        #expect(!controller.isBusy)
    }

    @Test("Cloud actions always stop for review without invoking a supplied model", arguments: [DocumentAssistantProvider.openAI, .claude])
    func remoteReview(provider: DocumentAssistantProvider) async throws {
        let controller = DocumentAssistantController(), model = Model(provider)
        let document = SamplePDF.make()
        await controller.submit(document: document, operation: .summarize, provider: provider, localModel: model).value
        let prepared = try #require(controller.prepared)
        #expect(prepared.requestCount > 0)
        #expect(model.calls == 0)
        #expect(controller.answers.isEmpty)
        await controller.generate(using: model, providerName: provider.label).value
        #expect(model.calls == prepared.requestCount)
        #expect(controller.answers.count == 1)
    }

    @Test("Stopping a local action during preparation prevents automatic generation")
    func cancelledLocalAction() async {
        let controller = DocumentAssistantController(), model = Model(.ollama)
        let document = SamplePDF.make()
        let work = controller.submit(document: document, operation: .summarize, provider: .ollama, localModel: model)
        controller.cancel()
        await work.value
        #expect(model.calls == 0)
        #expect(controller.answers.isEmpty)
        #expect(controller.prepared == nil)
    }

    @Test("Unavailable local AI retains readable sources and evidence search needs no model")
    func localRecovery() async {
        let controller = DocumentAssistantController(), model = Model(.ollama)
        let document = SamplePDF.make()
        model.unavailabilityReason = "Start your local model."
        await controller.submit(document: document, operation: .ask, question: "attention", provider: .ollama, localModel: model).value
        #expect(controller.errorMessage == "Start your local model.")
        #expect(controller.prepared?.sources.isEmpty == false)
        #expect(model.calls == 0)
        await controller.submit(document: document, operation: .evidence, question: "attention", provider: .openAI).value
        #expect(controller.answers.last?.isGenerated == false)
        #expect(controller.errorMessage == nil)
    }
}
