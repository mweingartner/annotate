import AnnotateCore
import SwiftUI

struct FormFieldRow: View {
    @Bindable var model: ReaderModel
    let field: PDFFormField
    @State private var value = ""
    @State private var checked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Button("\(field.name) • p. \(field.pageIndex + 1)") { model.goToPage(field.pageIndex + 1) }
                    .buttonStyle(.plain).font(.subheadline.bold())
                Spacer()
                if field.readOnly { Image(systemName: "lock").accessibilityLabel("Read-only") }
                Button("Remove \(field.name)", systemImage: "trash", role: .destructive) { model.removeFormField(field) }
                    .labelStyle(.iconOnly).help("Remove field")
            }
            switch field.kind {
            case .text:
                HStack {
                    TextField("Value", text: $value, axis: .vertical).lineLimit(1...5)
                        .accessibilityLabel("Value for \(field.name)")
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
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .onAppear(perform: synchronize)
        .onChange(of: field) { synchronize() }
    }
    private func save() { model.fillFormField(field, value: value) }
    private func synchronize() { value = field.value; checked = field.checked }
}
