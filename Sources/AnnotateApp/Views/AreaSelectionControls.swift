import AnnotateCore
import Atrium
import SwiftUI

/// Choose an area on a page by dragging, or by typing its coordinates.
struct AreaSelectionControls: View {
    @Bindable var model: ReaderModel
    @State private var x = 60.0
    @State private var y = 500.0
    @State private var width = 280.0
    @State private var height = 70.0
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.control) {
            Button(model.selectingToolArea ? "Cancel Area Selection" : "Draw an Area on Page", systemImage: "selection.pin.in.out") {
                model.selectingToolArea.toggle()
                model.pdfView?.clearSelection()
            }
            if model.selectingToolArea {
                Text("Drag across one page to choose the area.")
                    .font(Typography.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let region = model.toolSelection {
                Text("Page \(region.pageIndex + 1) · \(Double(region.bounds.width).formatted(.number.precision(.fractionLength(0)))) × \(Double(region.bounds.height).formatted(.number.precision(.fractionLength(0)))) pt selected")
                    .font(Typography.meta).foregroundStyle(.secondary)
            }
            DisclosureGroup("Enter area coordinates") {
                VStack(spacing: Spacing.snug) {
                    HStack(spacing: Spacing.snug) {
                        TextField("X", value: $x, format: .number)
                        TextField("Y", value: $y, format: .number)
                    }
                    HStack(spacing: Spacing.snug) {
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
                .padding(.top, Spacing.snug)
            }
        }
    }
}
