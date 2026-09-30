import AnnotateCore
import Atrium
import SwiftUI

/// A marker's details, opened from its pin on the page. It sits on the popover's own
/// glass: glyph and kind at the top, the passage and the reader's words, then actions.
struct AnnotationPopoverView: View {
    /// The popover's width and the most its reading area grows before it scrolls.
    static let width = Metrics.inspector.max
    static let maximumReadingHeight = Metrics.inspector.max

    let marker: PDFMarker
    let canEdit: Bool
    let hasPendingDraft: Bool
    let edit: () -> Void
    let close: () -> Void
    var delete: (() -> Void)? = nil

    private var kind: String {
        if marker.isBookmark { return "Bookmark" }
        let titles = MarkerCategory.allCases.filter { marker.categories.contains($0) }.map(\.title)
        return titles.isEmpty ? "Marker" : titles.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.control) {
                MarkerGlyph(marker: marker, size: Metrics.control)
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text(kind).font(Typography.heading)
                    Text(MarkerPresentation.pageLabel(regions: marker.regions))
                        .font(Typography.meta)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.snug)
                Button("Close", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.quiet)
                    .help("Close")
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(Spacing.group)

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.group) {
                    if !marker.quote.isEmpty {
                        Text(marker.quote)
                            .font(Typography.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, Spacing.control)
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color(nsColor: marker.color.nsColor)).frame(width: Spacing.tight)
                            }
                            .accessibilityLabel("Passage: \(marker.quote)")
                    }
                    if !marker.note.isEmpty { section("Note", text: marker.note) }
                    if !marker.question.isEmpty { section("Question", text: marker.question) }
                    if marker.note.isEmpty && marker.question.isEmpty && marker.quote.isEmpty {
                        Text("A place to come back to in this document.")
                            .font(Typography.supporting)
                            .foregroundStyle(.secondary)
                    }
                    if hasPendingDraft {
                        StatusBadge("Finish the open marker first", kind: .caution)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.group)
                .padding(.bottom, Spacing.group)
            }
            .frame(maxHeight: Self.maximumReadingHeight)

            Hairline()
            if !canEdit {
                Label("Read Only", systemImage: "lock.fill")
                    .font(Typography.meta)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.control)
            } else {
                HStack {
                    if let delete {
                        Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                            .buttonStyle(.quiet)
                            .disabled(!canEdit || hasPendingDraft)
                            .help("Delete this marker. Undo brings it back.")
                    }
                    Spacer()
                    Button("Edit…", action: edit)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canEdit || hasPendingDraft)
                        .help("Change this marker's kind, look, note or question")
                }
                .padding(Spacing.control)
            }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Marker details")
    }

    private func section(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(title)
                .font(Typography.label)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(Typography.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
