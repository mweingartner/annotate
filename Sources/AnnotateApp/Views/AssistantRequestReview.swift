import AnnotateCore
import Atrium
import SwiftUI

/// What a request will send, and to whom, before anything leaves the Mac.
struct AssistantRequestReview: View {
    let request: DocumentAssistantRequest
    let provider: DocumentAssistantProvider
    let modelName: String
    let generate: () -> Void
    let goToPage: (Int) -> Void

    var body: some View {
        // A section of the pane, not a card: header, content, then section room.
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(provider.requiresAPIKey ? "Review before sending" : "Sources are ready") {
                Image(systemName: provider.requiresAPIKey ? "cloud" : "doc.text").accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Spacing.control) {
                Text(verbatim: request.title).font(Typography.body).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if request.operation == .translate {
                    Text("Target language: \(request.language)").font(Typography.supporting)
                }
                if let previous = request.includedPreviousQuestion {
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text("Previous question included for context").font(Typography.label).foregroundStyle(.secondary)
                        Text(verbatim: previous).font(Typography.body).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if provider.requiresAPIKey {
                    Text("Sending shares the request shown above\(request.includedPreviousQuestion == nil ? "" : ", including the previous question,") and the source passages below with \(provider.label).")
                        .font(Typography.supporting).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                AssistantSourcePages(sources: request.sources, goToPage: goToPage)
                DisclosureGroup("Review \(request.sources.count) source passages") {
                    AssistantSourceList(sources: request.sources, goToPage: goToPage)
                        .padding(.top, Spacing.snug)
                }
                DisclosureGroup("Coverage & request details") {
                    VStack(alignment: .leading, spacing: Spacing.snug) {
                        Text(request.coverage)
                        Text("\(request.requestCount) requests · \(request.sourceByteCount.formatted()) bytes of PDF text · up to \((request.requestCount * request.maximumOutputTokens).formatted()) output tokens")
                        Text("Model: \(modelName)").textSelection(.enabled)
                        Text(provider.privacyDescription)
                    }
                    .font(Typography.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.snug)
                }
                if let url = provider.pricingURL {
                    Text("\(request.requestCount) API \(request.requestCount == 1 ? "request" : "requests"). Charges depend on your model and account. Sending authorizes these requests; they are never retried automatically.")
                        .font(Typography.supporting).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("Provider pricing", destination: url).font(Typography.supporting)
                    Text("Stopping cannot undo requests already sent.")
                        .font(Typography.supporting).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(provider.requiresAPIKey ? "Send to \(provider.label)" : "Try local AI again",
                       systemImage: provider.requiresAPIKey ? "paperplane" : "arrow.clockwise", action: generate)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("assistant.generate")
            }
        }
        .padding(.bottom, Spacing.section)
    }
}
