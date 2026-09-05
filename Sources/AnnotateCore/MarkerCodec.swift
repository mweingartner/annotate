import AppKit
import Foundation
import PDFKit

@MainActor
public enum MarkerCodec {
    public static let metadataKey = PDFAnnotationKey(rawValue: "/AnnotateMarker")
    public static let identifierKey = PDFAnnotationKey(rawValue: "/AnnotateMarkerID")
    public static let ownerKey = PDFAnnotationKey(rawValue: "/AnnotateOwner")
    public static let ownerValue = "org.annotate.marker.v1"
    public static let maximumMetadataBytes = 1_048_576

    private struct Envelope: Codable {
        var version: Int
        var marker: PDFMarker
    }

    public static func markers(in document: PDFDocument) -> [PDFMarker] {
        guard !document.isLocked else { return [] }
        var found: [UUID: PDFMarker] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                guard annotation.value(forAnnotationKey: ownerKey) as? String == ownerValue,
                      let raw = annotation.value(forAnnotationKey: metadataKey) as? String,
                      raw.utf8.count <= maximumMetadataBytes,
                      let data = raw.data(using: .utf8),
                      let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
                      envelope.version == 1,
                      let identifier = annotation.value(forAnnotationKey: identifierKey) as? String,
                      UUID(uuidString: identifier) == envelope.marker.id,
                      envelope.marker.pageIndex == index,
                      (try? validate(envelope.marker, in: document)) != nil else { continue }
                // A damaged PDF can repeat an anchor. Keep the first valid one deterministically.
                if found[envelope.marker.id] == nil { found[envelope.marker.id] = envelope.marker }
            }
        }
        return ordered(Array(found.values), in: document)
    }

    static func ordered(_ markers: [PDFMarker], in document: PDFDocument) -> [PDFMarker] {
        markers.sorted {
            if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
            if let page = document.page(at: $0.pageIndex),
               let first = $0.regions.first, let second = $1.regions.first {
                let transform = page.transform(for: .cropBox)
                let a = first.bounds.applying(transform)
                let b = second.bounds.applying(transform)
                if a.maxY != b.maxY { return a.maxY > b.maxY }
                if a.minX != b.minX { return a.minX < b.minX }
            }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public static func apply(_ marker: PDFMarker, to document: PDFDocument) throws {
        guard !document.isLocked else { throw AnnotateError.lockedDocument }
        guard document.allowsCommenting else { throw AnnotateError.commentingNotAllowed }
        try validate(marker, in: document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(version: 1, marker: marker))
        guard data.count <= maximumMetadataBytes, let payload = String(data: data, encoding: .utf8) else {
            throw AnnotateError.metadataTooLarge
        }
        let contents = readableContents(for: marker)
        var prepared: [(PDFPage, PDFAnnotation)] = []
        for (index, region) in marker.regions.enumerated() {
            guard let page = document.page(at: region.pageIndex) else { throw AnnotateError.invalidPage(region.pageIndex) }
            let highlight = PDFAnnotation(bounds: region.bounds, forType: .highlight, withProperties: nil)
            highlight.color = marker.color.nsColor.withAlphaComponent(0.35)
            highlight.contents = index == 0 ? contents : "Annotate · " + MarkerCategory.allCases.filter { marker.categories.contains($0) }.map(\.title).joined(separator: " · ")
            highlight.shouldDisplay = true
            highlight.shouldPrint = true
            highlight.userName = "Annotate"
            highlight.modificationDate = Date()
            try identify(highlight, marker: marker, payload: index == 0 ? payload : nil)
            prepared.append((page, highlight))
        }
        // A compact standard FreeText annotation gives every marker a printable icon,
        // including markers made on image-only pages. It survives other PDF readers.
        if let first = marker.regions.first, let page = document.page(at: first.pageIndex) {
            let crop = page.bounds(for: .cropBox)
            let size = min(18.0, min(crop.width, crop.height))
            let proposedX = first.bounds.minX - size - 3
            let x = min(max(crop.minX, proposedX), crop.maxX - size)
            let y = min(max(crop.minY, first.bounds.maxY - size), crop.maxY - size)
            let badge = PDFAnnotation(bounds: CGRect(x: x, y: y, width: size, height: size), forType: .freeText, withProperties: nil)
            badge.contents = iconGlyph(for: marker.icon)
            badge.font = NSFont.systemFont(ofSize: max(5, size - 4), weight: .bold)
            badge.fontColor = NSColor.black
            badge.color = marker.color.nsColor.withAlphaComponent(0.9)
            badge.alignment = .center
            let border = PDFBorder()
            border.lineWidth = 0
            badge.border = border
            badge.shouldPrint = true
            badge.shouldDisplay = true
            badge.userName = "Annotate"
            try identify(badge, marker: marker, payload: nil)
            prepared.append((page, badge))
        }
        // Do not remove an existing marker until all validation and allocation succeeds.
        remove(id: marker.id, from: document)
        for (page, annotation) in prepared { page.addAnnotation(annotation) }
    }

    public static func remove(id: UUID, from document: PDFDocument) {
        guard !document.isLocked, document.allowsCommenting else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where owns(annotation, id: id) {
                page.removeAnnotation(annotation)
            }
        }
    }

    public static func regions(for selection: PDFSelection, in document: PDFDocument) -> [PageRegion] {
        var result: [PageRegion] = []
        let lines = selection.selectionsByLine()
        for line in lines {
            for page in line.pages {
                let index = document.index(for: page)
                guard index != NSNotFound, index >= 0, index < document.pageCount else { continue }
                let bounds = line.bounds(for: page).intersection(page.bounds(for: .mediaBox))
                guard finite(bounds), bounds.width > 0, bounds.height > 0 else { continue }
                let region = PageRegion(pageIndex: index, bounds: bounds)
                if !result.contains(region) { result.append(region) }
            }
        }
        // Line selections preserve reading order and avoid covering whitespace between lines.
        return result
    }

    public static func readableContents(for marker: PDFMarker) -> String {
        var parts = [MarkerCategory.allCases.filter { marker.categories.contains($0) }.map(\.title).joined(separator: " · ")]
        if !marker.quote.isEmpty { parts.append("Passage: \(marker.quote)") }
        if !marker.note.isEmpty { parts.append("Note: \(marker.note)") }
        if !marker.question.isEmpty { parts.append("Question: \(marker.question)") }
        return parts.joined(separator: "\n\n")
    }

    static func validate(_ marker: PDFMarker, in document: PDFDocument) throws {
        guard !marker.categories.isEmpty else { throw AnnotateError.invalidMarker("choose at least one category.") }
        guard !marker.regions.isEmpty, marker.regions.count <= 10_000 else {
            throw AnnotateError.invalidMarker("choose a location or a shorter selection.")
        }
        guard marker.icon.utf8.count <= 128,
              marker.quote.utf8.count <= 524_288,
              marker.note.utf8.count <= 524_288,
              marker.question.utf8.count <= 524_288 else { throw AnnotateError.metadataTooLarge }
        guard marker.createdAt.timeIntervalSinceReferenceDate.isFinite,
              [marker.color.red, marker.color.green, marker.color.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw AnnotateError.invalidMarker("the color or date is invalid.")
        }
        for region in marker.regions {
            guard region.pageIndex >= 0, region.pageIndex < document.pageCount,
                  let page = document.page(at: region.pageIndex),
                  finite(region.bounds), region.bounds.size.width > 0, region.bounds.size.height > 0,
                  region.bounds.width <= 1_000_000, region.bounds.height <= 1_000_000,
                  page.bounds(for: .mediaBox).insetBy(dx: -1, dy: -1).contains(region.bounds) else {
                throw AnnotateError.invalidMarker("a location is outside its PDF page.")
            }
        }
    }

    private static func identify(_ annotation: PDFAnnotation, marker: PDFMarker, payload: String?) throws {
        guard annotation.setValue(ownerValue, forAnnotationKey: ownerKey),
              annotation.setValue(marker.id.uuidString, forAnnotationKey: identifierKey) else {
            throw AnnotateError.annotationWriteFailed
        }
        if let payload, !annotation.setValue(payload, forAnnotationKey: metadataKey) {
            throw AnnotateError.annotationWriteFailed
        }
    }

    private static func owns(_ annotation: PDFAnnotation, id: UUID) -> Bool {
        annotation.value(forAnnotationKey: ownerKey) as? String == ownerValue &&
        (annotation.value(forAnnotationKey: identifierKey) as? String).flatMap(UUID.init(uuidString:)) == id
    }

    static func finite(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy(\.isFinite)
    }

    private static func iconGlyph(for symbol: String) -> String {
        if symbol.contains("star") { return "★" }
        if symbol.contains("question") { return "?" }
        if symbol.contains("checkmark") { return "✓" }
        if symbol.contains("flag") { return "⚑" }
        if symbol.contains("arrow") { return "↻" }
        if symbol.contains("lightbulb") { return "✦" }
        if symbol.contains("bookmark") { return "◆" }
        if symbol.contains("exclamation") { return "!" }
        return "≡"
    }
}
