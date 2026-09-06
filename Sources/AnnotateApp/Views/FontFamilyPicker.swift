import SwiftUI

struct FontFamilyPicker: View {
    let font: NSFont
    let choose: (NSFont) -> Void
    @State private var isPresented = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        Button(action: showFonts) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Font family").font(.caption).foregroundStyle(.secondary)
                    Text(FontCatalog.displayName(for: FontCatalog.family(of: font))).font(.body).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Font family, \(FontCatalog.displayName(for: FontCatalog.family(of: font)))")
        .popover(isPresented: $isPresented, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose a font").font(.headline)
                TextField("Search font families", text: $query)
                    .textFieldStyle(.roundedBorder).focused($searchFocused)
                    .accessibilityLabel("Search installed font families")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(matchingFamilies, id: \.self) { family in
                            FontFamilyRow(family: family, selected: family == FontCatalog.family(of: font)) { select(family) }
                        }
                    }
                }
                if matchingFamilies.isEmpty { Text("No matching fonts").foregroundStyle(.secondary) }
            }
            .padding(14)
            .frame(width: 300, height: 360)
            .onAppear { searchFocused = true }
        }
    }

    private var matchingFamilies: [String] {
        query.isEmpty ? FontCatalog.families : FontCatalog.families.filter { FontCatalog.displayName(for: $0).localizedStandardContains(query) }
    }
    private func showFonts() { query = ""; isPresented = true }
    private func select(_ family: String) {
        guard let selected = FontCatalog.font(in: family, matching: font) else { return }
        choose(selected)
        isPresented = false
    }
}
