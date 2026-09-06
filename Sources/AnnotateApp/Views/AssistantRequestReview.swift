import AnnotateCore
import SwiftUI

struct AssistantRequestReview: View {
    let request: DocumentAssistantRequest
    let provider: DocumentAssistantProvider
    let modelName: String
    let generate: () -> Void
    let goToPage: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(provider.requiresAPIKey ? "Review before sending" : "Sources are ready", systemImage: provider.requiresAPIKey ? "cloud" : "doc.text")
                .font(.headline)
            Text(verbatim: request.title).font(.callout).textSelection(.enabled)
            if request.operation == .translate {
                Text("Target language: \(request.language)").font(.callout)
            }
            if let previous = request.includedPreviousQuestion {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Previous question included for context").font(.caption.bold())
                    Text(verbatim: previous).font(.callout).textSelection(.enabled)
                }
            }
            if provider.requiresAPIKey {
                Text("Sending shares the request shown above\(request.includedPreviousQuestion == nil ? "" : ", including the previous question,") and the source passages below with \(provider.label).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            AssistantSourcePages(sources: request.sources, goToPage: goToPage)
            DisclosureGroup("Review \(request.sources.count) source passages") {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(request.sources) { source in AssistantSourceRow(source: source, goToPage: goToPage) }
                }.padding(.top, 8)
            }
            DisclosureGroup("Coverage & request details") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(request.coverage)
                    Text("\(request.requestCount) requests · \(request.sourceByteCount.formatted()) bytes of PDF text · up to \((request.requestCount * request.maximumOutputTokens).formatted()) output tokens")
                    Text("Model: \(modelName)").textSelection(.enabled)
                    Text(provider.privacyDescription)
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
            if let url = provider.pricingURL {
                Text("\(request.requestCount) API \(request.requestCount == 1 ? "request" : "requests"). Charges depend on your model and account. Sending authorizes these requests; they are never retried automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Provider pricing", destination: url).font(.caption)
                Text("Stopping cannot undo requests already sent.").font(.caption).foregroundStyle(.secondary)
            }
            Button(provider.requiresAPIKey ? "Send to \(provider.label)" : "Try local AI again",
                   systemImage: provider.requiresAPIKey ? "paperplane" : "arrow.clockwise", action: generate)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("assistant.generate")
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }
}
