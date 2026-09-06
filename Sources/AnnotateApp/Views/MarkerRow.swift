import SwiftUI
import AnnotateCore

struct MarkerRow: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let marker: PDFMarker
    let selected: Bool
    let jump: () -> Void
    let edit: () -> Void
    let delete: () -> Void
    let canEdit: Bool

    private var orderedCategories: [MarkerCategory] {
        [.important, .revisit, .question, .note].filter { marker.categories.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ReaderStyle.compactSpacing) {
            Button(action: jump) {
                VStack(alignment: .leading, spacing: ReaderStyle.compactSpacing) {
                    HStack(alignment: .center) {
                        Image(systemName: marker.icon)
                            .font(.headline)
                            .foregroundStyle(Color(nsColor: marker.color.readableInkColor))
                            .frame(width: 29, height: 29)
                            .background(Color(nsColor: marker.color.nsColor), in: .rect(cornerRadius: 7))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(ReaderStyle.outline(contrast: contrast), lineWidth: 1)
                            }
                            .accessibilityHidden(true)
                        HStack(spacing: 5) {
                            ForEach(orderedCategories, id: \.self) { category in
                                Image(systemName: category.symbol)
                                    .foregroundStyle(.secondary)
                                    .help(category.title)
                                    .accessibilityLabel(category.title)
                            }
                        }
                        Spacer()
                        Text(MarkerPresentation.pageLabel(regions: marker.regions))
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Text(marker.quote.isEmpty ? "Page marker" : marker.quote)
                        .font(.body)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !marker.question.isEmpty {
                        Label(marker.question, systemImage: "questionmark.bubble")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if !marker.note.isEmpty {
                        Label(marker.note, systemImage: "note.text")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(MarkerPresentation.pageLabel(regions: marker.regions)), \(orderedCategories.map(\.title).joined(separator: ", ")), \(marker.quote.isEmpty ? "Page marker" : marker.quote)")
            .accessibilityHint("Go to this exact passage")

            if selected {
                HStack {
                    Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                        .buttonStyle(.borderless)
                        .disabled(!canEdit)
                        .help("Delete this marker; Undo restores it")
                    Spacer()
                    Button("Edit", systemImage: "square.and.pencil", action: edit)
                        .buttonStyle(.borderless)
                        .disabled(!canEdit)
                        .help("Edit categories, color, icon, note, or question")
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(selected ? ReaderStyle.accent.opacity(0.07) : Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: ReaderStyle.radius))
        .overlay {
            RoundedRectangle(cornerRadius: ReaderStyle.radius)
                .stroke(ReaderStyle.outline(selected: selected, contrast: contrast), lineWidth: selected ? 2 : 1)
        }
        .contextMenu {
            Button("Go to passage", systemImage: "arrow.turn.down.right", action: jump)
            Button("Edit marker", systemImage: "square.and.pencil", action: edit).disabled(!canEdit)
            Divider()
            Button("Delete marker", systemImage: "trash", role: .destructive, action: delete).disabled(!canEdit)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
