import Foundation
import FoundationModels

/// Explicitly uses the on-device model. It never selects Private Cloud Compute or a remote service.
@MainActor
public final class DocumentAssistantLanguageModel: DocumentAssistantGenerating {
    private let model = SystemLanguageModel.default

    public init() {}

    public var unavailabilityReason: String? {
        switch model.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible):
            "On-device AI is unavailable because this Mac does not support Apple Intelligence. Find source passages still works."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Enable Apple Intelligence in System Settings to use on-device AI. Find source passages works without it."
        case .unavailable(.modelNotReady):
            "Apple's on-device model is not ready. Its download or system preparation may still be in progress. Find source passages still works."
        case .unavailable:
            "Apple's on-device model is unavailable. Find source passages still works."
        }
    }

    public func generate(instructions: String, prompt: String, maximumResponseTokens: Int) async throws -> String {
        if let reason = unavailabilityReason { throw DocumentAssistantError.unavailable(reason) }
        try Task.checkCancellation()
        // 26.4 adds an exact tokenizer. Older versions use the bounded byte budget and
        // surface the framework's context error rather than retrying with discarded text.
        if #available(macOS 26.4, *) {
            let tokens = try await model.tokenCount(for: instructions + "\n" + prompt)
            guard tokens + maximumResponseTokens + 256 <= 4_096 else { throw DocumentAssistantError.contextTooLarge }
        }
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let response = try await session.respond(to: prompt, options: GenerationOptions(
                temperature: 0.2, maximumResponseTokens: maximumResponseTokens))
            try Task.checkCancellation()
            return response.content
        } catch is CancellationError {
            throw CancellationError()
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            throw DocumentAssistantError.contextTooLarge
        } catch {
            throw DocumentAssistantError.generationFailed(error.localizedDescription)
        }
    }
}
