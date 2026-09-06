import SwiftUI

struct RedactionPanel: View {
    @Bindable var model: ReaderModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remove sensitive content").font(.headline)
            Text("Select text or draw areas, add them to the list, then export a redacted copy.")
            AreaSelectionControls(model: model)
            Button("Add Selected Areas", systemImage: "plus.rectangle.fill", action: model.queueRedaction)
                .disabled(model.selectedToolRegions.isEmpty)
            Divider()
            ForEach(Array(model.redactionRegions.enumerated()), id: \.offset) { index, region in
                HStack {
                    Button("Area \(index + 1) · Page \(region.pageIndex + 1)") {
                        model.goToPage(region.pageIndex + 1); model.toolSelection = region
                    }
                    Spacer()
                    Button("Remove area \(index + 1)", systemImage: "minus.circle") { model.redactionRegions.remove(at: index) }
                        .labelStyle(.iconOnly)
                }
            }
            if model.redactionRegions.isEmpty { Text("No areas queued.").foregroundStyle(.secondary) }
            Text("The exported copy contains only page images with the chosen areas permanently blackened. Searchable text, forms, links, metadata, and attachments are removed throughout that copy. Your open original retains its contents.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Export Redacted Copy…", systemImage: "square.and.arrow.up", action: model.exportRedactedPDF)
                .buttonStyle(.borderedProminent)
                .disabled(model.redactionRegions.isEmpty)
        }
        .buttonStyle(.bordered)
    }
}
