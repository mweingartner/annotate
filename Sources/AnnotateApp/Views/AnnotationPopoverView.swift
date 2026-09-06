import AnnotateCore
import SwiftUI

struct AnnotationPopoverView: View {
    let marker: PDFMarker
    let canEdit: Bool
    let hasPendingDraft: Bool
    let edit: () -> Void
    let close: () -> Void
    var delete: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: marker.icon)
                    .font(.title3)
                    .foregroundStyle(Color(nsColor: marker.color.readableInkColor))
                    .frame(width: 34, height: 34)
                    .background(Color(nsColor: marker.color.nsColor), in: .rect(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Saved marker").font(.headline)
                    Text(MarkerPresentation.pageLabel(regions: marker.regions)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close annotation", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .help("Close this annotation")
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(MarkerCategory.allCases.filter { marker.categories.contains($0) }.map(\.title).joined(separator: " · "))
                        .font(.callout.bold())
                        .foregroundStyle(.primary)
                    if !marker.note.isEmpty { section("Note", text: marker.note, symbol: "note.text") }
                    if !marker.question.isEmpty { section("Question", text: marker.question, symbol: "questionmark.bubble") }
                    if !marker.quote.isEmpty { section("Selected passage", text: marker.quote, symbol: "text.quote") }
                    if marker.note.isEmpty && marker.question.isEmpty && marker.quote.isEmpty {
                        Text("A saved place to return to in this document.").foregroundStyle(.secondary)
                    }
                    if hasPendingDraft {
                        Text("Save or cancel the open draft before editing or deleting a marker.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
            .frame(maxHeight: 380)
            Divider()
            HStack {
                if let delete {
                    Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                        .buttonStyle(.borderless)
                        .disabled(!canEdit || hasPendingDraft)
                        .help("Delete this marker; Undo restores it")
                } else {
                    Button("Close", action: close).buttonStyle(.bordered)
                }
                Spacer()
                Button("Edit marker", systemImage: "square.and.pencil", action: edit)
                    .buttonStyle(.borderedProminent)
                    .tint(ReaderStyle.actionFill)
                    .foregroundStyle(.white)
                    .disabled(!canEdit || hasPendingDraft)
            }
            .padding(18)
        }
        .frame(width: 370)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.primary)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(ReaderStyle.accent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Annotation details")
    }

    private func section(_ title: String, text: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
