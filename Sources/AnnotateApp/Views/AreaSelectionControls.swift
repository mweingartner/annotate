import AnnotateCore
import SwiftUI

struct AreaSelectionControls: View {
    @Bindable var model: ReaderModel
    @State private var x = 60.0
    @State private var y = 500.0
    @State private var width = 280.0
    @State private var height = 70.0
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(model.selectingToolArea ? "Cancel Area Selection" : "Draw an Area on Page", systemImage: "selection.pin.in.out") {
                model.selectingToolArea.toggle()
                model.pdfView?.clearSelection()
            }
            if model.selectingToolArea { Text("Drag across one page to choose the area.").foregroundStyle(.secondary) }
            if let region = model.toolSelection {
                Text("Page \(region.pageIndex + 1) · \(Double(region.bounds.width).formatted(.number.precision(.fractionLength(0)))) × \(Double(region.bounds.height).formatted(.number.precision(.fractionLength(0)))) pt selected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Enter area coordinates") {
                VStack(spacing: 8) {
                    HStack {
                        TextField("X", value: $x, format: .number)
                        TextField("Y", value: $y, format: .number)
                    }
                    HStack {
                        TextField("Width", value: $width, format: .number)
                        TextField("Height", value: $height, format: .number)
                    }
                    Button("Use Area on Current Page") {
                        let region = PageRegion(pageIndex: model.pageNumber - 1, bounds: CGRect(x: x, y: y, width: width, height: height))
                        do {
                            if let pdf = model.pdfDocument {
                                _ = try PDFContentEditor.checkedPage(region, in: pdf)
                                model.toolSelection = region
                                model.pdfView?.clearSelection()
                            }
                        } catch { model.errorMessage = error.localizedDescription }
                    }
                }
                .padding(.top, 8)
            }
        }
    }
}
