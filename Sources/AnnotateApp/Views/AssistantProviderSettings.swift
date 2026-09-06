import AnnotateCore
import SwiftUI

struct AssistantProviderSettings: View {
    @Bindable var settings: DocumentAssistantPreferences
    @State private var apiKeyDraft = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(settings.provider.label) settings").font(.headline)
            switch settings.provider {
            case .ollama:
                if settings.availableOllamaModels.isEmpty {
                    TextField("Model name", text: $settings.ollamaModel)
                } else {
                    Picker("Model", selection: $settings.ollamaModel) {
                        ForEach(Array(Set(settings.availableOllamaModels + [settings.ollamaModel])).sorted(), id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                }
                HStack {
                    Button(settings.availableOllamaModels.isEmpty ? "Find installed models" : "Refresh models", systemImage: "arrow.clockwise", action: loadModels)
                        .disabled(settings.isLoadingModels)
                    if settings.isLoadingModels { ProgressView().controlSize(.small) }
                }
                if !settings.ollamaStatus.isEmpty { Text(settings.ollamaStatus).font(.caption).foregroundStyle(.secondary) }
                Text("Start Ollama and download a model there, then find it here.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Advanced connection settings") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Ollama address", text: $settings.ollamaAddress)
                        TextField("Model name", text: $settings.ollamaModel)
                        Text("Only addresses on this Mac are accepted.").font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
            case .openAI:
                keyControls
                TextField("Model", text: $settings.openAIModel)
                    .accessibilityLabel("OpenAI model")
            case .claude:
                keyControls
                TextField("Model", text: $settings.claudeModel)
                    .accessibilityLabel("Claude model")
                DisclosureGroup("Advanced") {
                    TextField("Workspace ID, if required", text: $settings.claudeWorkspaceID).padding(.top, 8)
                }
            case .apple:
                Text(settings.appleAvailability).font(.caption).foregroundStyle(.secondary)
                Button("Check availability", action: settings.refreshStatus)
            }
            DisclosureGroup("Privacy & usage") {
                Text(settings.provider.privacyDescription).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                if settings.provider.requiresAPIKey {
                    Text("A ChatGPT or Claude chat subscription does not include API access. Each request is reviewed before sending.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
        }
        .textFieldStyle(.roundedBorder)
        .onAppear(perform: settings.refreshStatus)
        .onChange(of: settings.provider) { _, _ in providerChanged() }
        .onDisappear { apiKeyDraft = "" }
    }

    private var keyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(settings.keyStatus, systemImage: settings.hasSavedAPIKey ? "checkmark.shield" : "key")
                .font(.caption).foregroundStyle(.secondary)
            SecureField(settings.hasSavedAPIKey ? "Paste a replacement API key" : "Paste your API key", text: $apiKeyDraft)
                .accessibilityLabel("API key").accessibilityIdentifier("assistant.apiKey")
            HStack {
                Button("Save key", action: saveKey).disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if settings.hasSavedAPIKey { Button("Remove key", role: .destructive, action: removeKey) }
            }
            .controlSize(.small)
            Text("Stored securely in macOS Keychain.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func providerChanged() { apiKeyDraft = ""; errorMessage = nil; settings.refreshStatus() }
    private func loadModels() { Task { await settings.loadOllamaModels() } }
    private func saveKey() {
        do { try settings.saveKey(apiKeyDraft); apiKeyDraft = ""; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
    private func removeKey() {
        do { try settings.removeKey(); apiKeyDraft = ""; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
}
