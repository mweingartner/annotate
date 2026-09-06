import AnnotateCore
import SwiftUI

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
    @FocusState private var questionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if operation.needsQuestion {
                TextField(operation == .evidence ? "Find a word, name, or topic…" : hasAnswers ? "Ask a follow-up question…" : "What would you like to know?", text: $question, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(3...6).padding(12)
                    .background(.background, in: .rect(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).stroke(.separator) }
                    .accessibilityLabel("Document question")
                    .accessibilityIdentifier("assistant.question")
                    .focused($questionFocused)
                    .disabled(isBusy)
                    .onSubmit { if canSubmit { submit(operation) } }
            } else {
                Label(operation.rawValue, systemImage: "text.cursor").font(.headline)
                Text("Select the passage in your PDF, then continue here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if operation == .translate {
                TextField("Translate into", text: $language).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Translation language").disabled(isBusy)
            }
            HStack {
                Button(AssistantInteraction.actionTitle(operation: operation, provider: provider),
                       systemImage: operation == .evidence ? "magnifyingglass" : provider.requiresAPIKey ? "arrow.right" : "sparkles") { submit(operation) }
                    .buttonStyle(.borderedProminent).disabled(!canSubmit)
                    .accessibilityIdentifier("assistant.prepare")
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
                HStack(spacing: 8) {
                    Button("Summarize", systemImage: "text.alignleft") { submit(.summarize) }
                    Button("Key details", systemImage: "list.bullet") { submit(.keyDetails) }
                }
                .buttonStyle(.bordered).controlSize(.small).disabled(isBusy || !hasDocument)
            }
            if operation == .evidence {
                Text("Searches original passages on this Mac. No model or API key is needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { questionFocused = operation.needsQuestion }
        .onChange(of: operation) { _, task in questionFocused = task.needsQuestion }
        .onChange(of: isBusy) { _, busy in
            if !busy, !provider.requiresAPIKey { questionFocused = operation.needsQuestion }
        }
    }

    private var canSubmit: Bool {
        AssistantInteraction.canSubmit(operation: operation, question: question, hasDocument: hasDocument, isBusy: isBusy)
    }
}
