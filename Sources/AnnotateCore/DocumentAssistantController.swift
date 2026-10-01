import Foundation
import Observation
import PDFKit

@MainActor @Observable
public final class DocumentAssistantController {
    public private(set) var answers: [DocumentAssistantAnswer] = []
    public private(set) var prepared: DocumentAssistantRequest?
    public private(set) var isBusy = false
    public private(set) var progress = ""
    public private(set) var errorMessage: String?
    public private(set) var removedAnswerCount = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private weak var document: PDFDocument?
    @ObservationIgnored private var documentRevision = 0
    @ObservationIgnored private var previousQuestion = ""
    @ObservationIgnored private var selectedProvider: DocumentAssistantProvider?

    public init() {}

    /// A local Ask action may read evidence and answer immediately. Cloud providers
    /// stop at the reviewed request, even if a caller supplies a generator.
    @discardableResult
    public func submit(document: PDFDocument, revision: Int = 0, operation: DocumentAssistantOperation,
                       question: String = "", selectedSources: [DocumentAssistantSource] = [], language: String = "English",
                       provider: DocumentAssistantProvider, settingsFingerprint: String = "",
                       localModel: (any DocumentAssistantGenerating)? = nil,
                       modelName: String? = nil) -> Task<Void, Never> {
        let preparation = prepare(document: document, revision: revision, operation: operation,
                                  question: question, selectedSources: selectedSources, language: language,
                                  provider: provider, settingsFingerprint: settingsFingerprint)
        guard !provider.requiresAPIKey, operation != .evidence, let localModel else { return preparation }
        let token = generation
        return Task { @MainActor [weak self] in
            await preparation.value
            guard !Task.isCancelled, let self, self.generation == token, self.prepared != nil else { return }
            let name = modelName.map { provider.label + " · " + $0 } ?? provider.label
            await self.generate(using: localModel, providerName: name, settingsFingerprint: settingsFingerprint).value
        }
    }

    /// Preparation is local and does not access API keys or contact any model provider.
    /// The prepared request records the provider and settings it is reviewed for.
    @discardableResult
    public func prepare(document: PDFDocument, revision: Int = 0, operation: DocumentAssistantOperation,
                        question: String = "", selectedSources: [DocumentAssistantSource] = [],
                        language: String = "English", provider: DocumentAssistantProvider,
                        settingsFingerprint: String = "") -> Task<Void, Never> {
        if self.document !== document || documentRevision != revision { reset() }
        selectProvider(provider)
        cancel()
        self.document = document
        documentRevision = revision
        let token = generation
        prepared = nil
        errorMessage = nil
        isBusy = true
        progress = "Reading PDF text…"
        let currentQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let followUpQuestion = previousQuestion
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.isBusy = false; self.progress = "" } }
            do {
                guard !document.isLocked, document.allowsCopying else { throw DocumentAssistantError.copyingRestricted }
                guard currentQuestion.utf8.count <= 1_000, language.utf8.count <= 80,
                      !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw DocumentAssistantError.requestTooLong
                }
                if operation.needsQuestion && currentQuestion.isEmpty { throw DocumentAssistantError.noQuestion }
                let sources: [DocumentAssistantSource]
                let coverage: String
                if operation.needsSelection {
                    guard !selectedSources.isEmpty, selectedSources.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                        throw DocumentAssistantError.noSelection
                    }
                    guard selectedSources.reduce(0, { $0 + $1.text.utf8.count }) <= 4_000 else {
                        throw DocumentAssistantError.requestTooLong
                    }
                    guard selectedSources.allSatisfy({ $0.pageNumber > 0 && $0.pageNumber <= document.pageCount }) else {
                        throw DocumentAssistantError.noSelection
                    }
                    sources = selectedSources
                    coverage = "Uses only the complete selected passage from \(Set(sources.map(\.pageNumber)).count) pages."
                } else {
                    let index = try await DocumentAssistantIndex.extract(from: document) { page, count in
                        if self.generation == token { self.progress = "Reading page \(page) of \(count)…" }
                    }
                    try Task.checkCancellation()
                    if operation.coversWholeDocument {
                        sources = index.sources
                        coverage = index.coverageDescription + " Summarizes every passage in successive sections."
                    } else {
                        let matched = index.retrieve(currentQuestion)
                        sources = matched.isEmpty && !followUpQuestion.isEmpty && operation == .ask
                            ? index.retrieve(followUpQuestion) : matched
                        guard !sources.isEmpty else { throw DocumentAssistantError.noMatches }
                        coverage = index.coverageDescription + " Retrieved \(sources.count) of \(index.sources.count) passages by matching words; the answer uses this subset."
                    }
                }
                try Task.checkCancellation()
                guard self.generation == token, self.document === document else { return }
                let request = DocumentAssistantRequest(provider: provider, settingsFingerprint: settingsFingerprint,
                    operation: operation, question: currentQuestion,
                    previousQuestion: followUpQuestion, language: language, sources: sources, coverage: coverage)
                if operation == .evidence {
                    self.append(.init(title: request.title, content: "Verbatim source passages are listed below. No AI model was used.",
                                      coverage: coverage, sources: sources, isGenerated: false))
                } else { self.prepared = request }
            } catch is CancellationError {
                // A cancelled or superseded request must not update this document's UI.
            } catch {
                if self.generation == token { self.errorMessage = error.localizedDescription }
            }
        }
        task = work
        return work
    }

    /// Cloud generation requires the user to review passages, provider, and request budget.
    /// A request is sent only through the provider, and with the settings, it was reviewed for.
    @discardableResult
    public func generate(using model: any DocumentAssistantGenerating, providerName: String,
                         settingsFingerprint: String = "") -> Task<Void, Never> {
        guard let request = prepared, let document else { return Task {} }
        guard model.provider == request.provider, settingsFingerprint == request.settingsFingerprint else {
            cancel()
            errorMessage = DocumentAssistantError.reviewedForAnotherProvider.localizedDescription
            return Task {}
        }
        cancel(keepPrepared: true)
        let token = generation
        errorMessage = nil
        isBusy = true
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.isBusy = false; self.progress = "" } }
            do {
                if let reason = model.unavailabilityReason { throw DocumentAssistantError.unavailable(reason) }
                let batches = request.batches
                var sections: [String] = []
                for (index, sources) in batches.enumerated() {
                    try Task.checkCancellation()
                    guard !document.isLocked, document.allowsCopying else { throw DocumentAssistantError.copyingRestricted }
                    guard self.generation == token, self.document === document else { return }
                    self.progress = batches.count > 1 ? "Writing section \(index + 1) of \(batches.count)…" : "Answering with \(providerName)…"
                    let text = try await model.generate(instructions: DocumentAssistantRequest.instructions,
                        prompt: request.prompt(for: sources), maximumResponseTokens: request.maximumOutputTokens)
                    try Task.checkCancellation()
                    let pages = Set(sources.map(\.pageNumber)).sorted().map(String.init).joined(separator: ", ")
                    sections.append(batches.count > 1 ? "Section \(index + 1) · pages \(pages)\n\n\(text)" : text)
                }
                guard self.generation == token, self.document === document else { return }
                guard !document.isLocked, document.allowsCopying else { throw DocumentAssistantError.copyingRestricted }
                self.append(.init(title: request.title, content: sections.joined(separator: "\n\n"),
                    coverage: request.coverage + " Generated with \(providerName).",
                    sources: request.sources, isGenerated: true, generatedBy: providerName))
                if request.operation == .ask { self.previousQuestion = request.question }
                self.prepared = nil
            } catch is CancellationError {
            } catch {
                if self.generation == token { self.errorMessage = error.localizedDescription }
            }
        }
        task = work
        return work
    }

    public func cancel(keepPrepared: Bool = false) {
        generation = UUID()
        task?.cancel()
        task = nil
        isBusy = false
        progress = ""
        if !keepPrepared { prepared = nil }
    }

    /// Earlier local/cloud questions must never silently become another
    /// provider's context. Visible answers remain available for the reader.
    public func selectProvider(_ provider: DocumentAssistantProvider) {
        guard selectedProvider != provider else { return }
        cancel()
        previousQuestion = ""
        selectedProvider = provider
    }

    public func reset() {
        cancel()
        answers = []
        removedAnswerCount = 0
        errorMessage = nil
        previousQuestion = ""
        document = nil
    }

    public func report(_ error: Error) { errorMessage = error.localizedDescription }

    private func append(_ answer: DocumentAssistantAnswer) {
        answers.append(answer)
        if answers.count > 12 { answers.removeFirst(); removedAnswerCount += 1 }
    }
}
