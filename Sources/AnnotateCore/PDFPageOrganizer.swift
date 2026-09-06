import AppKit
import PDFKit

/// Page operations retain page objects, native annotations, and Annotate's semantic regions.
@MainActor
public enum PDFPageOrganizer {
    public static func reorder(_ document: PDFDocument, order: [Int]) throws {
        try requireAssembly(document)
        guard order.count == document.pageCount, Set(order) == Set(0..<document.pageCount) else {
            throw PDFPageOperationError.invalidOrder
        }
        let markers = MarkerCodec.markers(in: document)
        let pages = try order.map { index in
            guard let page = document.page(at: index) else { throw AnnotateError.invalidPage(index) }
            return page
        }
        let mapping = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        removeMarkers(markers, from: document)
        while document.pageCount > 0 { document.removePage(at: 0) }
        for (index, page) in pages.enumerated() { document.insert(page, at: index) }
        try restore(markers, mapping: mapping, to: document)
    }

    public static func move(_ document: PDFDocument, page: Int, to destination: Int) throws {
        guard (0..<document.pageCount).contains(page), (0..<document.pageCount).contains(destination) else {
            throw PDFPageOperationError.invalidOrder
        }
        var order = Array(0..<document.pageCount)
        order.insert(order.remove(at: page), at: destination)
        try reorder(document, order: order)
    }

    public static func delete(_ document: PDFDocument, pages: IndexSet) throws {
        try requireAssembly(document)
        try validate(pages, in: document)
        guard pages.count < document.pageCount else { throw PDFPageOperationError.lastPage }
        let markers = MarkerCodec.markers(in: document)
        let retained = (0..<document.pageCount).filter { !pages.contains($0) }
        let mapping = Dictionary(uniqueKeysWithValues: retained.enumerated().map { ($0.element, $0.offset) })
        removeMarkers(markers, from: document)
        for index in pages.reversed() { document.removePage(at: index) }
        try restore(markers, mapping: mapping, to: document)
    }

    public static func rotate(_ document: PDFDocument, pages: IndexSet, clockwise: Bool = true) throws {
        try requireAssembly(document)
        try validate(pages, in: document)
        for index in pages {
            guard let page = document.page(at: index) else { continue }
            page.rotation = (page.rotation + (clockwise ? 90 : 270)) % 360
        }
        MarkerCodec.refreshAppearance(in: document)
    }

    /// The source is cloned before insertion, so merging never transfers or mutates its pages.
    public static func insert(_ source: PDFDocument, into document: PDFDocument, at insertion: Int) throws {
        try requireAssembly(document)
        guard !source.isLocked, source.allowsCopying, source.allowsDocumentAssembly else {
            throw PDFPageOperationError.sourceRestricted
        }
        guard insertion >= 0, insertion <= document.pageCount, source.pageCount > 0,
              let sourceData = source.dataRepresentation(), let copy = PDFDocument(data: sourceData) else {
            throw PDFPageOperationError.invalidOrder
        }
        let existing = MarkerCodec.markers(in: document)
        var incoming = MarkerCodec.markers(in: copy)
        var identifiers = Set(existing.map(\.id))
        for index in incoming.indices {
            if !identifiers.insert(incoming[index].id).inserted { incoming[index].id = UUID() }
        }
        let oldIncoming = MarkerCodec.markers(in: copy)
        removeMarkers(oldIncoming, from: copy)
        disambiguateFieldNames(in: copy, against: document)
        let count = copy.pageCount
        let pages = (0..<count).compactMap { copy.page(at: $0) }
        guard pages.count == count else { throw PDFPageOperationError.invalidOrder }
        removeMarkers(existing, from: document)
        let originalCount = document.pageCount
        for (offset, page) in pages.enumerated() {
            guard let duplicated = page.copy() as? PDFPage else { throw AnnotateError.exportFailed }
            let fieldNames = page.annotations.enumerated().compactMap { index, annotation -> (Int, String)? in
                guard let name = annotation.fieldName else { return nil }
                return (index, name)
            }
            document.insert(duplicated, at: insertion + offset)
            // PDFKit page-copy loses inherited field names. Restore them after page insertion.
            for (index, name) in fieldNames where duplicated.annotations.indices.contains(index) {
                duplicated.annotations[index].fieldName = name
            }
        }
        let oldMapping = Dictionary(uniqueKeysWithValues: (0..<originalCount).map { ($0, $0 < insertion ? $0 : $0 + count) })
        let newMapping = Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, insertion + $0) })
        try restore(existing, mapping: oldMapping, to: document)
        try restore(incoming, mapping: newMapping, to: document)
    }

    public static func insertBlank(into document: PDFDocument, at insertion: Int, size: CGSize = CGSize(width: 612, height: 792)) throws {
        guard size.width.isFinite, size.height.isFinite, size.width >= 36, size.height >= 36,
              size.width <= 14_400, size.height <= 14_400 else { throw PDFPageOperationError.invalidDimensions }
        let source = PDFDocument()
        let data = NSMutableData()
        var bounds = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw AnnotateError.exportFailed }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(bounds)
        context.endPDFPage()
        context.closePDF()
        guard let blank = PDFDocument(data: data as Data)?.page(at: 0) else { throw AnnotateError.exportFailed }
        source.insert(blank, at: 0)
        try insert(source, into: document, at: insertion)
    }

    public static func insertImages(_ images: [NSImage], into document: PDFDocument, at insertion: Int) throws {
        guard !images.isEmpty else { throw PDFPageOperationError.noSelection }
        let source = PDFDocument()
        for image in images {
            guard image.size.width > 0, image.size.height > 0, let page = PDFPage(image: image) else {
                throw PDFPageOperationError.invalidImage
            }
            source.insert(page, at: source.pageCount)
        }
        try insert(source, into: document, at: insertion)
    }

    public static func extract(_ document: PDFDocument, pages: IndexSet) throws -> PDFDocument {
        guard !document.isLocked, document.allowsCopying, document.allowsDocumentAssembly else {
            throw PDFPageOperationError.sourceRestricted
        }
        try validate(pages, in: document)
        guard let data = document.dataRepresentation(), let copy = PDFDocument(data: data) else { throw AnnotateError.exportFailed }
        let removed = IndexSet((0..<copy.pageCount).filter { !pages.contains($0) })
        if !removed.isEmpty { try delete(copy, pages: removed) }
        return copy
    }

    public static func split(_ document: PDFDocument, every count: Int) throws -> [PDFDocument] {
        guard count > 0 else { throw PDFPageOperationError.invalidOrder }
        guard document.pageCount > 0 else { throw AnnotateError.emptyDocument }
        return try stride(from: 0, to: document.pageCount, by: count).map { start in
            try extract(document, pages: IndexSet(integersIn: start..<min(document.pageCount, start + count)))
        }
    }

    public static func requireAssembly(_ document: PDFDocument) throws {
        guard !document.isLocked else { throw AnnotateError.lockedDocument }
        guard document.allowsDocumentAssembly else { throw PDFPageOperationError.assemblyRestricted }
        // Updating owned marker metadata is required to preserve exact navigation.
        if !document.allowsCommenting, !MarkerCodec.markers(in: document).isEmpty {
            throw AnnotateError.commentingNotAllowed
        }
    }

    private static func validate(_ pages: IndexSet, in document: PDFDocument) throws {
        guard !pages.isEmpty else { throw PDFPageOperationError.noSelection }
        guard pages.allSatisfy({ (0..<document.pageCount).contains($0) }) else { throw PDFPageOperationError.invalidOrder }
    }

    private static func removeMarkers(_ markers: [PDFMarker], from document: PDFDocument) {
        for marker in markers { MarkerCodec.remove(id: marker.id, from: document) }
    }

    private static func restore(_ markers: [PDFMarker], mapping: [Int: Int], to document: PDFDocument) throws {
        for var marker in markers {
            marker.regions = marker.regions.compactMap { region in
                guard let page = mapping[region.pageIndex] else { return nil }
                return PageRegion(pageIndex: page, bounds: region.bounds)
            }.enumerated().sorted { lhs, rhs in
                lhs.element.pageIndex == rhs.element.pageIndex ? lhs.offset < rhs.offset : lhs.element.pageIndex < rhs.element.pageIndex
            }.map(\.element)
            if !marker.regions.isEmpty { try MarkerCodec.apply(marker, to: document) }
        }
    }

    private static func disambiguateFieldNames(in source: PDFDocument, against document: PDFDocument) {
        let existing = Set((0..<document.pageCount).flatMap { document.page(at: $0)?.annotations.compactMap(\.fieldName) ?? [] })
        let widgets = (0..<source.pageCount).flatMap { source.page(at: $0)?.annotations.filter { $0.type == "Widget" } ?? [] }
        var occupied = existing.union(widgets.compactMap(\.fieldName))
        var renamed: [String: String] = [:]
        for widget in widgets {
            guard let name = widget.fieldName, existing.contains(name) else { continue }
            if let replacement = renamed[name] { widget.fieldName = replacement; continue }
            var suffix = 2
            while occupied.contains("\(name) (import \(suffix))") { suffix += 1 }
            let replacement = "\(name) (import \(suffix))"
            occupied.insert(replacement)
            renamed[name] = replacement
            widget.fieldName = replacement
        }
    }
}
