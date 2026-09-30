import AnnotateCore
import Atrium
import SwiftUI

/// Model choice, connection and API key for the selected assistant provider.
struct AssistantProviderSettings: View {
    @Bindable var settings: DocumentAssistantPreferences
    @State private var apiKeyDraft = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.control) {
            Text("\(settings.provider.label) settings").font(Typography.heading)
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
                HStack(spacing: Spacing.snug) {
                    Button(settings.availableOllamaModels.isEmpty ? "Find installed models" : "Refresh models", systemImage: "arrow.clockwise", action: loadModels)
                        .disabled(settings.isLoadingModels)
                    if settings.isLoadingModels { ProgressView().controlSize(.small) }
                }
                if !settings.ollamaStatus.isEmpty { note(settings.ollamaStatus) }
                note("Start Ollama and download a model there, then find it here.")
                DisclosureGroup("Advanced connection settings") {
                    VStack(alignment: .leading, spacing: Spacing.snug) {
                        TextField("Ollama address", text: $settings.ollamaAddress)
                        TextField("Model name", text: $settings.ollamaModel)
                        note("Only addresses on this Mac are accepted.")
                    }.padding(.top, Spacing.snug)
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
                    TextField("Workspace ID, if required", text: $settings.claudeWorkspaceID).padding(.top, Spacing.snug)
                }
            case .apple:
                note(settings.appleAvailability)
                Button("Check availability", action: settings.refreshStatus)
            }
            DisclosureGroup("Privacy & usage") {
                VStack(alignment: .leading, spacing: Spacing.snug) {
                    note(settings.provider.privacyDescription)
                    if settings.provider.requiresAPIKey {
                        note("A ChatGPT or Claude chat subscription does not include API access. Each request is reviewed before sending.")
                    }
                }
                .padding(.top, Spacing.snug)
            }
            if let errorMessage {
                Label {
                    Text(errorMessage).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.Status.critical)
                }
                .font(Typography.supporting)
            }
        }
        .textFieldStyle(.roundedBorder)
        .onAppear(perform: settings.refreshStatus)
        .onChange(of: settings.provider) { _, _ in providerChanged() }
        .onDisappear { apiKeyDraft = "" }
    }

    private var keyControls: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Label(settings.keyStatus, systemImage: settings.hasSavedAPIKey ? "checkmark.shield" : "key")
                .font(Typography.supporting).foregroundStyle(.secondary)
            SecureField(settings.hasSavedAPIKey ? "Paste a replacement API key" : "Paste your API key", text: $apiKeyDraft)
                .accessibilityLabel("API key").accessibilityIdentifier("assistant.apiKey")
            HStack(spacing: Spacing.snug) {
                Button("Save key", action: saveKey).disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if settings.hasSavedAPIKey { Button("Remove key", role: .destructive, action: removeKey) }
            }
            note("Stored securely in macOS Keychain.")
        }
    }

    /// An explanation under a control: supporting size, secondary, wrapping.
    private func note(_ text: String) -> some View {
        Text(text).font(Typography.supporting).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
