import AnnotateCore
import Atrium
import SwiftUI

/// The question field (or selection prompt) and the actions that start a request.
struct AssistantComposer: View {
    let operation: DocumentAssistantOperation
    @Binding var question: String
    @Binding var language: String
    let provider: DocumentAssistantProvider
    let hasAnswers: Bool
    let hasDocument: Bool
    let isBusy: Bool
    let chooseTask: (DocumentAssistantOperation) -> Void
    let submit: (DocumentAssistantOperation) -> Void
    /// Whether the submit button is the pane's one prominent action. The panel turns this
    /// off while a prepared request waits for review, so Send is the only primary.
    var isPrimary = true
    @FocusState private var questionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.control) {
            if operation.needsQuestion {
                TextField(operation == .evidence ? "Find a word, name, or topic…" : hasAnswers ? "Ask a follow-up question…" : "What would you like to know?", text: $question, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(3...6).padding(Spacing.control)
                    .background(.background, in: .rect(cornerRadius: Radius.field))
                    .overlay { RoundedRectangle(cornerRadius: Radius.field).strokeBorder(Palette.hairline) }
                    .accessibilityLabel("Document question")
                    .accessibilityIdentifier("assistant.question")
                    .focused($questionFocused)
                    .disabled(isBusy)
                    .onSubmit { if canSubmit { submit(operation) } }
            } else {
                // The section header above already names the task.
                Label("Select the passage in your PDF, then continue here.", systemImage: "text.cursor")
                    .font(Typography.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if operation == .translate {
                TextField("Translate into", text: $language).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Translation language").disabled(isBusy)
            }
            HStack(spacing: Spacing.snug) {
                submitButton
                Spacer(minLength: 0)
                Menu("More actions", systemImage: "ellipsis") {
                    Button("Ask a question") { chooseTask(.ask) }
                    Button("Find sources · no AI needed") { chooseTask(.evidence) }
                    Divider()
                    Button("Explain selected text") { chooseTask(.explain) }
                    Button("Translate selected text") { chooseTask(.translate) }
                }
                .labelStyle(.iconOnly).menuIndicator(.hidden).disabled(isBusy)
                .accessibilityIdentifier("assistant.operation")
            }
            if operation == .ask {
                // Two quick tasks side by side when the column allows, stacked when it doesn't.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.snug) { quickTasks }
                    VStack(alignment: .leading, spacing: Spacing.tight) { quickTasks }
                }
                .buttonStyle(.quiet).disabled(isBusy || !hasDocument)
            }
            if operation == .evidence {
                Text("Searches original passages on this Mac. No model or API key is needed.")
                    .font(Typography.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { questionFocused = operation.needsQuestion }
        .onChange(of: operation) { _, task in questionFocused = task.needsQuestion }
        .onChange(of: isBusy) { _, busy in
            if !busy, !provider.requiresAPIKey { questionFocused = operation.needsQuestion }
        }
    }

    @ViewBuilder
    private var submitButton: some View {
        let button = Button(AssistantInteraction.actionTitle(operation: operation, provider: provider),
                            systemImage: operation == .evidence ? "magnifyingglass" : provider.requiresAPIKey ? "arrow.right" : "sparkles") { submit(operation) }
        Group {
            if isPrimary { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
        }
        .disabled(!canSubmit)
        .accessibilityIdentifier("assistant.prepare")
    }

    @ViewBuilder
    private var quickTasks: some View {
        Button("Summarize", systemImage: "text.alignleft") { submit(.summarize) }
        Button("Key details", systemImage: "list.bullet") { submit(.keyDetails) }
    }

    private var canSubmit: Bool {
        AssistantInteraction.canSubmit(operation: operation, question: question, hasDocument: hasDocument, isBusy: isBusy)
    }
}
