import AnnotateCore
import Atrium
import SwiftUI

/// One interactive field: its name and page, its value control, and removal.
struct FormFieldRow: View {
    @Bindable var model: ReaderModel
    let field: PDFFormField
    @State private var value = ""
    @State private var checked = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            HStack(spacing: Spacing.snug) {
                Button("\(UntrustedText.display(field.name, limit: 80)) • p. \(field.pageIndex + 1)") { model.goToPage(field.pageIndex + 1) }
                    .buttonStyle(.quiet).font(Typography.heading)
                Spacer(minLength: Spacing.snug)
                Button("Remove \(UntrustedText.display(field.name, limit: 80))", systemImage: "trash", role: .destructive) { model.removeFormField(field) }
                    .labelStyle(.iconOnly).buttonStyle(.quiet).help("Remove field")
            }
            if field.readOnly {
                // Symbol and word, on its own line so a long field name keeps its room.
                Label("Read-only", systemImage: "lock")
                    .font(Typography.meta).foregroundStyle(.secondary)
                    .accessibilityLabel("Read-only")
            }
            switch field.kind {
            case .text:
                HStack(spacing: Spacing.snug) {
                    TextField("Value", text: $value, axis: .vertical).lineLimit(1...5)
                        .accessibilityLabel("Value for \(UntrustedText.display(field.name, limit: 80))")
                        .onSubmit(save)
                    Button("Apply", action: save)
                }.disabled(field.readOnly)
            case .choice, .list:
                Picker("Value", selection: $value) {
                    ForEach(field.choices, id: \.self) { Text($0).tag($0) }
                }
                .disabled(field.readOnly)
                .onChange(of: value) { _, newValue in
                    if newValue != field.value { model.fillFormField(field, value: newValue) }
                }
            case .checkbox:
                Toggle("Checked", isOn: $checked)
                    .disabled(field.readOnly)
                    .onChange(of: checked) { _, newValue in
                        if newValue != field.checked { model.fillFormField(field, value: newValue ? field.exportValue : "Off") }
                    }
            case .radio:
                Button(field.exportValue, systemImage: field.checked ? "largecircle.fill.circle" : "circle") {
                    model.fillFormField(field, value: field.exportValue)
                }.disabled(field.readOnly)
            }
        }
        .onAppear(perform: synchronize)
        .onChange(of: field) { synchronize() }
    }
    private func save() { model.fillFormField(field, value: value) }
    private func synchronize() { value = field.value; checked = field.checked }
}
