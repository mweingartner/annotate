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
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Margin icon picker")
    }
}
