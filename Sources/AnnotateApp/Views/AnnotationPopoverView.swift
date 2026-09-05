import AnnotateCore
import SwiftUI

struct AnnotationPopoverView: View {
    let marker: PDFMarker
    let canEdit: Bool
    let hasPendingDraft: Bool
    let edit: () -> Void
    let close: () -> Void

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
                    Text("Your annotation").font(.headline)
                    Text("Page \(marker.pageIndex + 1)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close annotation", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .help("Close this annotation")
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
                        Text("Save or cancel the open draft before editing another annotation.")
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
                Button("Close", action: close)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Edit annotation", systemImage: "square.and.pencil", action: edit)
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
