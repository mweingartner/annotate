import Atrium
import SwiftUI

/// A floating glass control at the foot of the page: page position with previous and
/// next, the progress of a long operation, and brief confirmations ("Marker added").
struct PageIndicator: View {
    @Bindable var model: ReaderModel
    @State private var pageEntry = 1
    @State private var visibleStatus = ""
    @State private var statusTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: Spacing.snug) {
            if model.isProcessing {
                ProgressView().controlSize(.small)
                Text(model.operationProgress.isEmpty ? "Working…" : model.operationProgress)
                    .font(Typography.supporting)
                    .lineLimit(1)
                Button("Cancel", systemImage: "xmark") { model.operationTask?.cancel() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.quiet)
                    .help("Cancel this operation")
            } else if !visibleStatus.isEmpty {
                Label(visibleStatus, systemImage: symbol(for: visibleStatus))
                    .font(Typography.supporting)
                    .symbolRenderingMode(.hierarchical)
                    .lineLimit(1)
                    .transition(.opacity)
                if visibleStatus.localizedCaseInsensitiveContains("deleted") {
                    Button("Undo") { model.owner?.undoManager?.undo() }
                        .buttonStyle(.quiet)
                        .help("Bring it back")
                }
            } else {
                pagePosition
            }
        }
        .atriumFloatingGlass()
        .atriumAnimation(value: visibleStatus)
        .atriumAnimation(value: model.isProcessing)
        .onAppear(perform: updatePageEntry)
        .onChange(of: model.pageNumber, updatePageEntry)
        .onChange(of: model.statusMessage) { _, message in show(message) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page navigation")
    }

    private var pagePosition: some View {
        HStack(spacing: Spacing.tight) {
            Button("Previous Page", systemImage: "chevron.up") { model.goToPage(model.pageNumber - 1) }
                .disabled(model.pageNumber <= 1)
                .help("Previous page")
            TextField("Page", value: $pageEntry, format: .number.grouping(.never))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(Typography.numeric)
                .frame(width: Metrics.control + Spacing.snug)
                .onSubmit(goToPage)
                .accessibilityLabel("Go to page")
            Text("of \(model.pageCount)")
                .font(Typography.numeric)
                .foregroundStyle(.secondary)
                .fixedSize()
            Button("Next Page", systemImage: "chevron.down") { model.goToPage(model.pageNumber + 1) }
                .disabled(model.pageNumber >= model.pageCount)
                .help("Next page")
            if !model.canEdit {
                Label("Read Only", systemImage: "lock.fill")
                    .font(Typography.meta)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .help("This PDF does not allow annotations")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.quiet)
    }

    private func updatePageEntry() { pageEntry = model.pageNumber }
    private func goToPage() { model.goToPage(pageEntry); pageEntry = model.pageNumber }

    /// Confirmations replace the page position for a moment, then step aside. The model's
    /// message is cleared afterwards, so the same confirmation shows again next time.
    private func show(_ message: String) {
        guard !message.isEmpty else { return }
        statusTask?.cancel()
        visibleStatus = message
        AccessibilityNotification.Announcement(message).post()
        statusTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(2.4)) } catch { return }
            visibleStatus = ""
            if model.statusMessage == message { model.statusMessage = "" }
        }
    }

    /// Symbol plus words: what kind of news this is.
    private func symbol(for message: String) -> String {
        if message.localizedCaseInsensitiveContains("cancel") { return "xmark.circle.fill" }
        if message.localizedCaseInsensitiveContains("deleted") { return "trash.fill" }
        return "checkmark.circle.fill"
    }
}
