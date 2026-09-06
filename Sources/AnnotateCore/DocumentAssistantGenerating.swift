import Foundation

@MainActor
public protocol DocumentAssistantGenerating: AnyObject {
    /// nil means the system model is available. A reason is shown verbatim in the UI otherwise.
    var unavailabilityReason: String? { get }
    func generate(instructions: String, prompt: String, maximumResponseTokens: Int) async throws -> String
}
