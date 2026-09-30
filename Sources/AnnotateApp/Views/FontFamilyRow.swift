import Atrium
import SwiftUI

struct FontFamilyRow: View {
    let family: String
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack {
                Text(FontCatalog.displayName(for: family)).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.quiet)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
