import Foundation
import Testing
@testable import AnnotateCore

@Suite("Opt-in local assistant runtime")
@MainActor
struct AssistantLocalSmokeTests {
    @Test("Downloaded Ollama model generates a source-grounded answer",
          .enabled(if: ProcessInfo.processInfo.environment["ANNOTATE_LOCAL_AI_SMOKE"] == "1"))
    func ollamaRuntime() async throws {
        let name = ProcessInfo.processInfo.environment["ANNOTATE_LOCAL_AI_MODEL"] ?? "granite4.1:8b"
        let client = DocumentAssistantAPIClient(provider: .ollama, model: name)
        let answer = try await client.generate(instructions: DocumentAssistantRequest.instructions,
            prompt: "What is the project's codename? Answer in one sentence with a page citation.\nPDF EVIDENCE\n[Page 2] The project's codename is Cedar Compass.\nEND PDF EVIDENCE", maximumResponseTokens: 256)
        #expect(answer.localizedCaseInsensitiveContains("Cedar Compass"))
        #expect(answer.contains("2"))
    }
}
