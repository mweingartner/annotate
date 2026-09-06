import AnnotateCore
import Foundation
import Observation

@MainActor @Observable
final class DocumentAssistantPreferences {
    var provider: DocumentAssistantProvider { didSet { defaults.set(provider.rawValue, forKey: "assistant.provider") } }
    var ollamaModel: String { didSet { defaults.set(ollamaModel, forKey: "assistant.ollamaModel") } }
    var openAIModel: String { didSet { defaults.set(openAIModel, forKey: "assistant.openAIModel") } }
    var claudeModel: String { didSet { defaults.set(claudeModel, forKey: "assistant.claudeModel") } }
    var ollamaAddress: String { didSet { defaults.set(ollamaAddress, forKey: "assistant.ollamaAddress") } }
    var claudeWorkspaceID: String { didSet { defaults.set(claudeWorkspaceID, forKey: "assistant.claudeWorkspaceID") } }
    var keyStatus = ""
    var hasSavedAPIKey = false
    var appleAvailability = ""
    var availableOllamaModels: [String] = []
    var ollamaStatus = ""
    var isLoadingModels = false
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        provider = DocumentAssistantProvider(rawValue: defaults.string(forKey: "assistant.provider") ?? "") ?? .ollama
        ollamaModel = defaults.string(forKey: "assistant.ollamaModel") ?? DocumentAssistantProvider.ollama.defaultModel
        openAIModel = defaults.string(forKey: "assistant.openAIModel") ?? DocumentAssistantProvider.openAI.defaultModel
        claudeModel = defaults.string(forKey: "assistant.claudeModel") ?? DocumentAssistantProvider.claude.defaultModel
        ollamaAddress = defaults.string(forKey: "assistant.ollamaAddress") ?? "http://localhost:11434"
        claudeWorkspaceID = defaults.string(forKey: "assistant.claudeWorkspaceID") ?? ""
    }

    var fingerprint: String { "\(provider.rawValue)|\(ollamaModel)|\(openAIModel)|\(claudeModel)|\(ollamaAddress)|\(claudeWorkspaceID)" }
    var modelName: String {
        switch provider {
        case .ollama: ollamaModel
        case .openAI: openAIModel
        case .claude: claudeModel
        case .apple: provider.defaultModel
        }
    }

    func refreshStatus() {
        if provider.requiresAPIKey {
            hasSavedAPIKey = DocumentAssistantKeychain.hasKey(for: provider)
            keyStatus = hasSavedAPIKey ? "API key saved in this Mac's Keychain." : "Add an API key to use this provider."
        } else { keyStatus = ""; hasSavedAPIKey = false }
        appleAvailability = DocumentAssistantLanguageModel().unavailabilityReason ?? "Apple's on-device model is available."
    }

    func saveKey(_ key: String) throws {
        try DocumentAssistantKeychain.save(key, for: provider)
        refreshStatus()
    }

    func removeKey() throws {
        try DocumentAssistantKeychain.delete(for: provider)
        refreshStatus()
    }

    func loadOllamaModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        let address = ollamaAddress
        do {
            let models = try await DocumentAssistantAPIClient.localOllamaModels(baseURL: address)
            guard address == ollamaAddress else { return }
            useDiscoveredModels(models)
        } catch { ollamaStatus = "Could not load local models. Start Ollama and check the address." }
    }

    func useDiscoveredModels(_ models: [String]) {
        availableOllamaModels = models.sorted()
        if !models.contains(ollamaModel), let first = availableOllamaModels.first { ollamaModel = first }
        ollamaStatus = models.isEmpty ? "No downloaded models found. Download a model in Ollama, then refresh." : "\(models.count) models available on this Mac."
    }

    func makeGenerator() throws -> any DocumentAssistantGenerating {
        if provider == .apple { return DocumentAssistantLanguageModel() }
        let key = provider.requiresAPIKey ? try DocumentAssistantKeychain.read(for: provider) : nil
        return DocumentAssistantAPIClient(provider: provider, model: modelName, apiKey: key,
            ollamaBaseURL: ollamaAddress, workspaceID: claudeWorkspaceID)
    }
}
