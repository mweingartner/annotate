import SwiftUI

struct MarkerIconPicker: View {
    @Bindable var draft: MarkerDraft

    var body: some View {
        VStack(alignment: .leading, spacing: ReaderStyle.compactSpacing) {
            Text("Margin icon")
                .font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: ReaderStyle.compactSpacing) {
                ForEach(MarkerIconOption.all) { option in
                    MarkerIconButton(option: option, selected: draft.icon == option.symbol, action: { draft.icon = option.symbol })
                }
            }
            if let selectedOption = MarkerIconOption.all.first(where: { $0.symbol == draft.icon }) {
                Text("Selected: \(selectedOption.name)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Margin icon picker")
    }
}
