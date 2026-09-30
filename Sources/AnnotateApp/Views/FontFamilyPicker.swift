import Atrium
import SwiftUI

/// The current font family as a button that opens a searchable list of installed families.
struct FontFamilyPicker: View {
    let font: NSFont
    let choose: (NSFont) -> Void
    @State private var isPresented = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        Button(action: showFonts) {
            HStack(spacing: Spacing.snug) {
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text("Font family").font(Typography.meta).foregroundStyle(.secondary)
                    Text(FontCatalog.displayName(for: FontCatalog.family(of: font))).font(Typography.body).lineLimit(1)
                }
                Spacer(minLength: Spacing.tight)
                Image(systemName: "chevron.up.chevron.down").font(Typography.meta).foregroundStyle(.secondary)
            }
            .padding(.vertical, Spacing.tight)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Font family, \(FontCatalog.displayName(for: FontCatalog.family(of: font)))")
        .popover(isPresented: $isPresented, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: Spacing.control) {
                Text("Choose a font").font(Typography.heading)
                TextField("Search font families", text: $query)
                    .textFieldStyle(.roundedBorder).focused($searchFocused)
                    .accessibilityLabel("Search installed font families")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.hair) {
                        ForEach(matchingFamilies, id: \.self) { family in
                            FontFamilyRow(family: family, selected: family == FontCatalog.family(of: font)) { select(family) }
                        }
                    }
                }
                if matchingFamilies.isEmpty { Text("No matching fonts").font(Typography.supporting).foregroundStyle(.secondary) }
            }
            .padding(Spacing.group)
            .frame(width: Metrics.inspector.ideal, height: Metrics.inspector.max)
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
