import AnnotateCore
import PDFKit
import SwiftUI

struct AssistantPanel: View {
    @Bindable var model: ReaderModel
    @State private var assistant = DocumentAssistantController()
    @State private var settings = DocumentAssistantPreferences()
    @State private var operation: DocumentAssistantOperation = .ask
    @State private var question = ""
    @State private var language = "English"
    @State private var settingsExpanded = false
    @State private var submittedQuestion: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Ask your PDF").font(.title2.bold())
                Text("Understand this document, with sources you can open.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            providerBar
            if settingsExpanded {
                AssistantProviderSettings(settings: settings)
                    .padding(12)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
                    .disabled(assistant.isBusy)
            }
            AssistantComposer(operation: operation, question: $question, language: $language,
                              provider: settings.provider, hasAnswers: !assistant.answers.isEmpty,
                              hasDocument: model.pdfDocument != nil, isBusy: assistant.isBusy,
                              chooseTask: chooseTask, submit: submit)
            if assistant.isBusy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(assistant.progress).font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Stop", action: cancel).controlSize(.small)
                        .accessibilityIdentifier("assistant.cancel")
                }
                .accessibilityElement(children: .contain)
            }
            if let error = assistant.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .accessibilityIdentifier("assistant.error")
                    HStack {
                        Button("AI settings") { settingsExpanded = true }
                        if operation.needsQuestion, !question.isEmpty {
                            Button("Find sources instead") { submit(.evidence) }
                        }
                    }
                    .controlSize(.small)
                }
            }
            if let request = assistant.prepared, !assistant.isBusy {
                AssistantRequestReview(request: request, provider: settings.provider, modelName: settings.modelName,
                                       generate: generate, goToPage: model.goToPage)
            }
            if let latest = assistant.answers.last {
                Divider()
                AssistantAnswerCard(answer: latest, goToPage: model.goToPage)
                if assistant.answers.count > 1 {
                    DisclosureGroup("Earlier answers (\(assistant.answers.count - 1))") {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(assistant.answers.dropLast().reversed()) { answer in
                                AssistantAnswerCard(answer: answer, goToPage: model.goToPage)
                            }
                        }.padding(.top, 10)
                    }
                }
                HStack {
                    Text("This document only").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear conversation", action: reset).controlSize(.small).disabled(assistant.isBusy)
                }
                if assistant.removedAnswerCount > 0 {
                    Text("Keeping the latest 12 answers; \(assistant.removedAnswerCount) older answers were cleared.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { assistant.selectProvider(settings.provider); settings.refreshStatus() }
        .onChange(of: model.pdfDocument.map(ObjectIdentifier.init)) { _, _ in reset() }
        .onChange(of: model.documentRevision) { _, _ in reset() }
        .onChange(of: settings.fingerprint) { _, _ in assistant.cancel() }
        .onChange(of: settings.provider) { _, provider in assistant.selectProvider(provider); settings.refreshStatus() }
        .onChange(of: question) { _, _ in assistant.cancel() }
        .onChange(of: language) { _, _ in assistant.cancel() }
        .onChange(of: assistant.answers.last?.id) { _, answerID in
            if answerID != nil, let submittedQuestion, question == submittedQuestion { question = "" }
            submittedQuestion = nil
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { settings.refreshStatus() } }
        .onDisappear(perform: cancel)
    }

    private var providerBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(DocumentAssistantProvider.allCases) { provider in Text(provider.label).tag(provider) }
                }
                .labelsHidden()
                .accessibilityLabel("AI provider")
                .accessibilityIdentifier("assistant.provider")
                .disabled(assistant.isBusy)
                Spacer(minLength: 0)
                Button("Settings", systemImage: "slider.horizontal.3") { settingsExpanded.toggle() }
                    .labelStyle(.iconOnly)
                    .help("Choose a model or configure an API key")
                    .accessibilityIdentifier("assistant.settings")
            }
            Label(settings.provider.requiresAPIKey ? "Cloud · review before sending" : "Local · stays on this Mac",
                  systemImage: settings.provider.requiresAPIKey ? "cloud" : "desktopcomputer")
                .font(.caption).foregroundStyle(.secondary)
            if settings.provider.requiresAPIKey && !settings.hasSavedAPIKey {
                Button("Add \(settings.provider.label) key…") { settingsExpanded = true }
                    .font(.caption).buttonStyle(.link)
            } else {
                Button(settings.modelName) { settingsExpanded = true }
                    .font(.caption).buttonStyle(.link).lineLimit(1)
                    .help("Change model")
            }
        }
    }

    private func chooseTask(_ task: DocumentAssistantOperation) {
        assistant.cancel()
        operation = task
    }

    private func submit(_ task: DocumentAssistantOperation) {
        guard let document = model.pdfDocument else { return }
        do {
            let selection = task.needsSelection ? try model.assistantSelection() : []
            let localModel = settings.provider.requiresAPIKey || task == .evidence ? nil : try settings.makeGenerator()
            submittedQuestion = task.needsQuestion ? question : nil
            assistant.submit(document: document, revision: model.documentRevision, operation: task,
                             question: question, selectedSources: selection, language: language,
                             provider: settings.provider, localModel: localModel, modelName: settings.modelName)
            settingsExpanded = false
        } catch { assistant.report(error); settingsExpanded = true }
    }

    private func generate() {
        do {
            let generator = try settings.makeGenerator()
            assistant.generate(using: generator, providerName: settings.provider.label + " · " + settings.modelName)
        } catch { assistant.report(error); settingsExpanded = true }
    }
    private func cancel() { assistant.cancel() }
    private func reset() { assistant.reset(); question = "" }
}
