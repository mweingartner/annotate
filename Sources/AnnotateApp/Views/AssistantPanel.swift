import AnnotateCore
import Atrium
import PDFKit
import SwiftUI

/// The Assistant inspector: choose where the AI runs, ask or act on a selection, review
/// what will be sent, then read answers with the sources behind them.
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
        VStack(alignment: .leading, spacing: 0) {
            Text("Understand this document, with sources you can open.")
                .font(Typography.supporting).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Spacing.group)
            PageSection("AI provider") {
                providerBar
                if settingsExpanded {
                    AssistantProviderSettings(settings: settings)
                        .disabled(assistant.isBusy)
                        .padding(.top, Spacing.group)
                }
            }
            PageSection(operation.rawValue) {
                VStack(alignment: .leading, spacing: Spacing.control) {
                    AssistantComposer(operation: operation, question: $question, language: $language,
                                      provider: settings.provider, hasAnswers: !assistant.answers.isEmpty,
                                      hasDocument: model.pdfDocument != nil, isBusy: assistant.isBusy,
                                      chooseTask: chooseTask, submit: submit,
                                      isPrimary: !isReviewingRequest)
                    if assistant.isBusy {
                        HStack(spacing: Spacing.snug) {
                            ProgressView().controlSize(.small)
                            Text(assistant.progress)
                                .font(Typography.supporting).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Stop", action: cancel)
                                .buttonStyle(.quiet)
                                .accessibilityIdentifier("assistant.cancel")
                        }
                        .accessibilityElement(children: .contain)
                    }
                    if let error = assistant.errorMessage {
                        VStack(alignment: .leading, spacing: Spacing.snug) {
                            Label {
                                Text(error).fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.Status.critical)
                            }
                            .font(Typography.supporting).textSelection(.enabled)
                            .accessibilityIdentifier("assistant.error")
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: Spacing.snug) { recoveryActions }
                                VStack(alignment: .leading, spacing: Spacing.tight) { recoveryActions }
                            }
                            .buttonStyle(.quiet)
                        }
                    }
                }
            }
            if let request = assistant.prepared, !assistant.isBusy {
                AssistantRequestReview(request: request, provider: settings.provider, modelName: settings.modelName,
                                       generate: generate, goToPage: model.goToPage)
            }
            if let latest = assistant.answers.last {
                // The one raised block in this pane: the answer being read now.
                AssistantAnswerCard(answer: latest, goToPage: model.goToPage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .atriumSurface()
                    .padding(.bottom, Spacing.group)
                if assistant.answers.count > 1 {
                    DisclosureGroup("Earlier answers (\(assistant.answers.count - 1))") {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(assistant.answers.dropLast().reversed()) { answer in
                                Hairline()
                                AssistantAnswerCard(answer: answer, goToPage: model.goToPage)
                                    .padding(.vertical, Spacing.group)
                            }
                        }.padding(.top, Spacing.snug)
                    }
                    .padding(.bottom, Spacing.group)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.snug) {
                        conversationScope
                        Spacer(minLength: Spacing.snug)
                        clearConversation
                    }
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        conversationScope
                        clearConversation
                    }
                }
                if assistant.removedAnswerCount > 0 {
                    Text("Keeping the latest 12 answers; \(assistant.removedAnswerCount) older answers were cleared.")
                        .font(Typography.meta).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Spacing.snug)
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

    @ViewBuilder
    private var recoveryActions: some View {
        Button("AI settings") { settingsExpanded = true }
        if operation.needsQuestion, !question.isEmpty {
            Button("Find sources instead") { submit(.evidence) }
        }
    }

    private var conversationScope: some View {
        Text("This document only").font(Typography.meta).foregroundStyle(.secondary)
    }

    private var clearConversation: some View {
        Button("Clear conversation", action: reset).buttonStyle(.quiet).disabled(assistant.isBusy)
    }

    /// While a prepared request waits for review, sending it is the one primary action.
    private var isReviewingRequest: Bool { assistant.prepared != nil && !assistant.isBusy }

    private var providerBar: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.snug) {
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
                    .buttonStyle(.quiet)
                    .help("Choose a model or configure an API key")
                    .accessibilityIdentifier("assistant.settings")
            }
            Label(settings.provider.requiresAPIKey ? "Cloud · review before sending" : "Local · stays on this Mac",
                  systemImage: settings.provider.requiresAPIKey ? "cloud" : "desktopcomputer")
                .font(Typography.meta).foregroundStyle(.secondary)
            if settings.provider.requiresAPIKey && !settings.hasSavedAPIKey {
                Button("Add \(settings.provider.label) key…") { settingsExpanded = true }
                    .font(Typography.supporting).buttonStyle(.link)
            } else {
                Button(settings.modelName) { settingsExpanded = true }
                    .font(Typography.supporting).buttonStyle(.link).lineLimit(1)
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
