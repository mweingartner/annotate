import AnnotateCore
import Atrium
import SwiftUI

/// What the sidebar lists: the reader's own marks, or the document's pages.
enum SidebarContent: String, CaseIterable, Identifiable {
    case markers, pages
    var id: String { rawValue }
    var title: String { self == .markers ? "Markers" : "Thumbnails" }
    var symbol: String { self == .markers ? "bookmark" : "rectangle.stack" }
}

/// The glass sidebar. Search results replace the list while a search is typed.
struct ReaderSidebar: View {
    @Bindable var model: ReaderModel
    @AppStorage("sidebarContent") private var content: SidebarContent = .markers

    private var isSearching: Bool { !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Group {
            if isSearching {
                SearchResultsList(model: model)
            } else if content == .pages {
                PageThumbnails(model: model)
            } else {
                MarkerList(model: model)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !isSearching { header }
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.snug) {
            Picker("Show", selection: $content) {
                ForEach(SidebarContent.allCases) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Show markers or page thumbnails")

            if content == .markers {
                Menu("Filter Markers", systemImage: model.filter == .all
                     ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") {
                    Picker("Show", selection: $model.filter) {
                        ForEach(MarkerFilter.allCases, id: \.self) { filter in
                            Label("\(filter.title) (\(model.markers.count { filter.matches($0) }))", systemImage: filter.symbol)
                                .tag(filter)
                        }
                    }
                    .pickerStyle(.inline)
                }
                .labelStyle(.iconOnly)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Show only some kinds of marker")
                .accessibilityValue(model.filter.title)
            }
        }
        .padding(.horizontal, Spacing.control)
        .padding(.vertical, Spacing.snug)
    }
}

/// Bookmarks (marked pages) first, then annotations (marked passages), in page order.
private struct MarkerList: View {
    @Bindable var model: ReaderModel

    private var bookmarks: [PDFMarker] { model.filteredMarkers.filter(\.isBookmark) }
    private var annotations: [PDFMarker] { model.filteredMarkers.filter { !$0.isBookmark } }

    var body: some View {
        if model.filteredMarkers.isEmpty {
            emptyState
        } else {
            List(selection: selection) {
                if !bookmarks.isEmpty {
                    Section("Bookmarks") { rows(bookmarks) }
                }
                if !annotations.isEmpty {
                    Section("Annotations") { rows(annotations) }
                }
            }
            .listStyle(.sidebar)
            .onKeyPress(.space) {
                // Space shows the selected marker's details, as Quick Look does for files.
                guard let marker = model.markers.first(where: { $0.id == model.selectedMarkerID }) else { return .ignored }
                model.pdfView?.showDetails(for: marker)
                return .handled
            }
            .accessibilityLabel("\(model.filter.title) markers")
        }
    }

    private func rows(_ markers: [PDFMarker]) -> some View {
        ForEach(markers) { marker in
            MarkerRow(marker: marker)
                .tag(marker.id)
                .contextMenu { menu(for: marker) }
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) { model.removeMarkerFromReader(marker) }
                        .disabled(!canChange)
                }
        }
    }

    @ViewBuilder
    private func menu(for marker: PDFMarker) -> some View {
        Button(marker.isBookmark ? "Go to Page" : "Go to Passage", systemImage: "arrow.turn.down.right") { model.jump(to: marker) }
        Button("Show Details", systemImage: "info.circle") { model.pdfView?.showDetails(for: marker) }
        Button("Edit Marker…", systemImage: "square.and.pencil") { model.openMarkerEditor(marker) }
            .disabled(!canChange)
        Divider()
        Button("Delete Marker", systemImage: "trash", role: .destructive) { model.removeMarkerFromReader(marker) }
            .disabled(!canChange)
    }

    private func showAll() { model.filter = .all }
    private func bookmarkPage() { model.markCurrentPageFromWorkspace() }

    private var canChange: Bool { model.canEdit && !model.isProcessing && !model.hasDraftChanges }

    /// Only a person's click writes the selection, and a click means "take me there".
    private var selection: Binding<UUID?> {
        Binding(get: { model.selectedMarkerID }, set: { id in
            guard let id, let marker = model.markers.first(where: { $0.id == id }) else { return }
            model.jump(to: marker)
        })
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.filter != .all {
            SidebarEmptyState(title: "No \(model.filter.title.lowercased())",
                              message: "Markers in this category appear here. A passage can belong to more than one.",
                              systemImage: model.filter.symbol, actionTitle: "Show All Markers", action: showAll)
        } else if model.canEdit {
            SidebarEmptyState(title: "Nothing marked yet",
                              message: "Select a passage to annotate it, or bookmark this page to find your way back.",
                              systemImage: "bookmark", actionTitle: "Bookmark This Page", action: bookmarkPage)
        } else {
            SidebarEmptyState(title: "Nothing marked",
                              message: "This PDF does not allow annotations, so markers can’t be added.",
                              systemImage: "lock")
        }
    }
}

/// Atrium's empty state sized for a sidebar column: symbol, serif title, one sentence
/// and at most one ordinary button, with group spacing instead of the page-sized room.
private struct SidebarEmptyState: View {
    let title: String
    let message: String
    let systemImage: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Spacing.snug) {
            Image(systemName: systemImage)
                .font(Typography.title)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(Typography.title)
                .multilineTextAlignment(.center)
            Text(message)
                .font(Typography.supporting)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .padding(.top, Spacing.tight)
            }
        }
        .padding(Spacing.group)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One marker in the sidebar: its glyph, the passage (or page), and the reader's note.
struct MarkerRow: View {
    let marker: PDFMarker

    private var categories: [MarkerCategory] {
        [.important, .revisit, .question, .note].filter { marker.categories.contains($0) }
    }
    private var pageLabel: String { MarkerPresentation.pageLabel(regions: marker.regions) }
    private var title: String { marker.isBookmark ? pageLabel : marker.quote }
    private var detail: String {
        [marker.note, marker.question].first { !$0.isEmpty } ?? ""
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.snug) {
            MarkerGlyph(marker: marker)
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text(title)
                    .font(Typography.body)
                    .lineLimit(marker.isBookmark ? 1 : 2)
                if !detail.isEmpty {
                    Text(detail)
                        .font(Typography.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !marker.isBookmark {
                    HStack(spacing: Spacing.tight) {
                        ForEach(categories, id: \.self) { Image(systemName: $0.symbol).help($0.title) }
                        Text(pageLabel).monospacedDigit()
                    }
                    .font(Typography.meta)
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                }
            }
        }
        .padding(.vertical, Spacing.tight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([pageLabel, categories.map(\.title).joined(separator: ", "), title, detail]
            .filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint("Go to this marker")
    }
}

/// Search hits, each a page and the words around the match.
private struct SearchResultsList: View {
    @Bindable var model: ReaderModel
    @State private var selectedHit: SearchHit.ID?

    var body: some View {
        if model.searchResults.isEmpty {
            if model.isSearching {
                ProgressView("Searching…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: model.query)
            }
        } else {
            List(selection: $selectedHit) {
                Section {
                    ForEach(model.searchResults) { hit in
                        VStack(alignment: .leading, spacing: Spacing.hair) {
                            Text("Page \(hit.pageIndex + 1)")
                                .font(Typography.label)
                                .foregroundStyle(.secondary)
                            Text(hit.snippet)
                                .font(Typography.body)
                                .lineLimit(3)
                        }
                        .padding(.vertical, Spacing.tight)
                        .tag(hit.id)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("Go to this result on page \(hit.pageIndex + 1)")
                    }
                } header: {
                    Text(model.isSearching ? "Searching…" : "\(model.searchResults.count) \(model.searchResults.count == 1 ? "Result" : "Results")")
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selectedHit) { _, id in
                if let hit = model.searchResults.first(where: { $0.id == id }) { model.jump(to: hit) }
            }
            .accessibilityLabel("Search results")
        }
    }
}

extension PDFMarker {
    /// A bookmark marks a page; an annotation marks a passage.
    var isBookmark: Bool { quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
