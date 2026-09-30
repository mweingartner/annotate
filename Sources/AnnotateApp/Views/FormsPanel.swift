import AnnotateCore
import Atrium
import SwiftUI

/// The Forms inspector: create interactive fields, and fill the ones the document has.
struct FormsPanel: View {
    @Bindable var model: ReaderModel
    @State private var name = ""
    @State private var kind: PDFFormKind = .text
    @State private var options = "Option 1, Option 2"
    @State private var radioValue = "Option 1"
    @State private var multiline = false
    @State private var left = 10.0
    @State private var top = 20.0
    @State private var width = 40.0
    @State private var height = 4.0
    @State private var useSelection = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Fill existing interactive fields below or directly on the PDF. Create new fields on page \(model.pageNumber).")
                .font(Typography.supporting).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Spacing.group)
            DisclosureGroup("Create a field") {
                VStack(alignment: .leading, spacing: Spacing.control) {
                    TextField("Field name or radio group", text: $name)
                    Picker("Field type", selection: $kind) {
                        ForEach(PDFFormKind.allCases) { Text($0.title).tag($0) }
                    }
                    if kind == .text { Toggle("Multiple lines", isOn: $multiline) }
                    if kind == .choice || kind == .list { TextField("Choices separated by commas", text: $options) }
                    if kind == .radio { TextField("Radio option value", text: $radioValue) }
                    Toggle("Use selected PDF area when available", isOn: $useSelection)
                    Button(model.selectingToolArea ? "Cancel area selection" : "Draw an area on the PDF", systemImage: "selection.pin.in.out") { model.selectingToolArea.toggle() }
                    SignaturePlacementFields(left: $left, top: $top, width: $width, height: $height)
                    Button("Create \(kind.title.lowercased())", systemImage: "plus.rectangle", action: create)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(.top, Spacing.snug)
            }
            .padding(.bottom, Spacing.section)
            if fields.isEmpty {
                EmptyState("No interactive fields",
                           message: "Create a field above, or use Text and Sign to fill a noninteractive form.",
                           systemImage: "rectangle.and.pencil.and.ellipsis")
            } else {
                PageSection("\(fields.count) fields") {
                    ForEach(fields) { field in
                        Hairline()
                        FormFieldRow(model: model, field: field)
                            .padding(.vertical, Spacing.snug)
                    }
                }
            }
        }
        .disabled(model.isProcessing)
    }

    private var fields: [PDFFormField] {
        _ = model.documentRevision
        return model.pdfDocument.map(PDFFormEditor.fields(in:)) ?? []
    }

    private func create() {
        let manual = model.placementRegion(page: model.pageNumber - 1, left: left / 100, top: top / 100, width: width / 100, height: height / 100)
        guard let region = (useSelection ? model.toolSelection : nil) ?? manual else {
            model.errorMessage = "Keep the field inside the page: left + width and top + height must each be at most 100%."
            return
        }
        model.createFormField(name: name, kind: kind, choices: options.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }, exportValue: radioValue, multiline: multiline, region: region)
    }
}
