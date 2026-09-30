import Atrium
import SwiftUI

/// The Redact inspector: choose areas, queue them, and export a sanitized copy.
struct RedactionPanel: View {
    @Bindable var model: ReaderModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageSection("Remove sensitive content") {
                VStack(alignment: .leading, spacing: Spacing.control) {
                    Text("Select text or draw areas, add them to the list, then export a redacted copy.")
                        .font(Typography.supporting).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    AreaSelectionControls(model: model)
                    Button("Add Selected Areas", systemImage: "plus.rectangle.fill", action: model.queueRedaction)
                        .disabled(model.selectedToolRegions.isEmpty)
                }
            }
            PageSection("Queued areas") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.redactionRegions.enumerated()), id: \.offset) { index, region in
                        if index > 0 { Hairline() }
                        HStack(spacing: Spacing.snug) {
                            Button("Area \(index + 1) · Page \(region.pageIndex + 1)") {
                                model.goToPage(region.pageIndex + 1); model.toolSelection = region
                            }
                            Spacer(minLength: Spacing.snug)
                            Button("Remove area \(index + 1)", systemImage: "minus.circle") { model.redactionRegions.remove(at: index) }
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.quiet)
                        .padding(.vertical, Spacing.hair)
                    }
                    if model.redactionRegions.isEmpty {
                        Text("No areas queued.").font(Typography.supporting).foregroundStyle(.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: Spacing.control) {
                Text("The exported copy contains only page images with the chosen areas permanently blackened. Searchable text, forms, links, metadata, and attachments are removed throughout that copy. Your open original retains its contents.")
                    .font(Typography.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Export Redacted Copy…", systemImage: "square.and.arrow.up", action: model.exportRedactedPDF)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.redactionRegions.isEmpty)
            }
        }
        .buttonStyle(.bordered)
    }
}
