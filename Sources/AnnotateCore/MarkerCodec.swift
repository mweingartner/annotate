import AppKit
import Foundation
import PDFKit

@MainActor
public enum MarkerCodec {
    public static let metadataKey = PDFAnnotationKey(rawValue: "/AnnotateMarker")
    public static let identifierKey = PDFAnnotationKey(rawValue: "/AnnotateMarkerID")
    public static let ownerKey = PDFAnnotationKey(rawValue: "/AnnotateOwner")
    public static let ownerValue = "org.annotate.marker.v1"
    public static let maximumMetadataBytes = 2 * 1_048_576
    /// What reading one document's markers may cost: a crafted file can repeat one large
    /// payload on many annotations, or carry tens of thousands of small markers.
    public static let maximumMarkers = 20_000
    public static let maximumDecodedMetadataBytes = 32 * 1_048_576

    /// Creates the highlight, icon and comment annotations a marker is made of. An app
    /// may return a PDFAnnotation subclass to change how its own viewer draws markers;
    /// what is written to the file is unaffected.
    public static var makeAnnotation: (CGRect, PDFAnnotationSubtype) -> PDFAnnotation = {
        PDFAnnotation(bounds: $0, forType: $1, withProperties: nil)
    }

    private struct Envelope: Codable {
        var version: Int
        var marker: PDFMarker
    }

    public static func markers(in document: PDFDocument) -> [PDFMarker] {
        guard !document.isLocked else { return [] }
        var found: [UUID: PDFMarker] = [:], decoded = 0
        reading: for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                // Cheap checks first: ownership and identity, then the payload's size.
                guard annotation.value(forAnnotationKey: ownerKey) as? String == ownerValue,
                      let identifier = (annotation.value(forAnnotationKey: identifierKey) as? String).flatMap(UUID.init(uuidString:)),
                      // A damaged PDF can repeat an anchor. Keep the first valid one deterministically.
                      found[identifier] == nil,
                      let raw = annotation.value(forAnnotationKey: metadataKey) as? String else { continue }
                let size = raw.utf8.count
                guard size <= maximumMetadataBytes else { continue }
                decoded += size
                guard decoded <= maximumDecodedMetadataBytes else { break reading }
                guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(raw.utf8)),
                      envelope.version == 1,
                      identifier == envelope.marker.id,
                      envelope.marker.pageIndex == index,
                      (try? validate(envelope.marker, in: document)) != nil else { continue }
                found[identifier] = envelope.marker
                if found.count >= maximumMarkers { break reading }
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
        try apply(marker, to: document, replacing: true)
    }

    /// `replacing: false` is for a marker whose annotations the caller has just removed
    /// (see `remove(ids:from:)`): it skips the scan of every annotation in the document
    /// for an old copy, which made restoring many markers quadratic.
    static func apply(_ marker: PDFMarker, to document: PDFDocument, replacing: Bool) throws {
        guard !document.isLocked else { throw AnnotateError.lockedDocument }
        guard document.allowsCommenting else { throw AnnotateError.commentingNotAllowed }
        try validate(marker, in: document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(version: 1, marker: marker))
        guard data.count <= maximumMetadataBytes, let payload = String(data: data, encoding: .utf8) else {
            throw AnnotateError.metadataTooLarge
        }
        var prepared: [(PDFPage, PDFAnnotation)] = []
        for (index, region) in marker.regions.enumerated() {
            guard let page = document.page(at: region.pageIndex) else { throw AnnotateError.invalidPage(region.pageIndex) }
            let highlight = makeAnnotation(region.bounds, .highlight)
            highlight.color = marker.color.nsColor.withAlphaComponent(0.35)
            // Contents on a highlight make PDFKit synthesize an unaddressable comment
            // icon outside its bounds. A separate owned Text annotation carries them.
            highlight.contents = nil
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
            let badge = makeAnnotation(CGRect(x: x, y: y, width: size, height: size), .freeText)
            badge.contents = iconGlyph(for: marker.icon)
            badge.font = NSFont.systemFont(ofSize: max(5, size - 4), weight: .bold)
            badge.fontColor = marker.color.readableInkColor
            // A solid fill keeps the ink contrast stable over colored PDF content.
            badge.color = marker.color.nsColor
            badge.alignment = .center
            let border = PDFBorder()
            border.lineWidth = 0
            badge.border = border
            badge.shouldPrint = true
            badge.shouldDisplay = true
            badge.userName = "Annotate"
            try identify(badge, marker: marker, payload: nil)
            prepared.append((page, badge))
            let comment = try commentTag(for: marker, on: page)
            prepared.append((page, comment.tag))
            prepared.append((page, comment.popup))
        }
        // Do not remove an existing marker until all validation and allocation succeeds.
        if replacing { remove(id: marker.id, from: document) }
        for (page, annotation) in prepared { page.addAnnotation(annotation) }
    }

    public static func remove(id: UUID, from document: PDFDocument) {
        remove(ids: [id], from: document)
    }

    /// Removes every annotation of these markers in one pass over the document.
    public static func remove(ids: Set<UUID>, from document: PDFDocument) {
        guard !document.isLocked, document.allowsCommenting, !ids.isEmpty else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let annotations = page.annotations.filter { ownerID(of: $0).map(ids.contains) == true }
            // Detach in-memory popup links before removing their parent. Otherwise
            // PDFKit can reinsert a companion while serializing the removed parent.
            for annotation in annotations where annotation.type != "Popup" { annotation.popup = nil }
            for annotation in annotations {
                page.removeAnnotation(annotation)
            }
        }
    }

    /// Repairs older Annotate appearances without rewriting marker metadata or identifiers.
    /// Normal document saving persists the updated appearance; restricted PDFs are left intact.
    public static func refreshAppearance(in document: PDFDocument) {
        guard !document.isLocked, document.allowsCommenting else { return }
        // Each page's owned annotations, by marker, read once: scanning a whole page for
        // every marker is quadratic on a page with many markers.
        var owned: [Int: [UUID: [PDFAnnotation]]] = [:]
        func annotations(of id: UUID, on pageIndex: Int) -> [PDFAnnotation] {
            if owned[pageIndex] == nil, let page = document.page(at: pageIndex) {
                var byMarker: [UUID: [PDFAnnotation]] = [:]
                for annotation in page.annotations where annotation.value(forAnnotationKey: ownerKey) as? String == ownerValue {
                    if let id = (annotation.value(forAnnotationKey: identifierKey) as? String).flatMap(UUID.init(uuidString:)) {
                        byMarker[id, default: []].append(annotation)
                    }
                }
                owned[pageIndex] = byMarker
            }
            return owned[pageIndex]?[id] ?? []
        }
        for marker in markers(in: document) {
            guard let page = document.page(at: marker.pageIndex) else { continue }
            let mine = annotations(of: marker.id, on: marker.pageIndex)
            let comments = mine.filter { $0.type == "Text" }
            let popups = mine.filter { $0.type == "Popup" }
            // Only a missing comment or popup is created; one marker's annotations cost a
            // fraction of a millisecond each, and this runs on load and after every edit.
            guard let placement = try? commentPlacement(for: marker, on: page) else { continue }
            var prepared: (tag: PDFAnnotation, popup: PDFAnnotation)?
            if comments.isEmpty || popups.isEmpty {
                guard let made = try? commentTag(for: marker, on: page) else { continue }
                prepared = made
            }
            guard let popup = popups.first ?? prepared?.popup else { continue }
            if comments.isEmpty, let tag = prepared?.tag {
                tag.popup = popup
                page.addAnnotation(tag)
            } else {
                // Unchanged values aren't written: a write marks the annotation for saving.
                for comment in comments {
                    if !sameBounds(comment.bounds, placement.bounds) { comment.bounds = placement.bounds }
                    if !sameColor(comment.color, placement.color) { comment.color = placement.color }
                    if comment.popup !== popup { comment.popup = popup }
                }
            }
            if popups.isEmpty { page.addAnnotation(popup) }
            for badge in mine where badge.type == "FreeText" {
                if !sameColor(badge.fontColor, marker.color.readableInkColor) { badge.fontColor = marker.color.readableInkColor }
                if !sameColor(badge.color, marker.color.nsColor) { badge.color = marker.color.nsColor }
            }
            for pageIndex in Set(marker.regions.map(\.pageIndex)) {
                for highlight in annotations(of: marker.id, on: pageIndex) where highlight.type == "Highlight" && highlight.contents != nil {
                    highlight.contents = nil
                }
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
        guard !marker.regions.isEmpty, marker.regions.count <= 20_000 else {
            throw AnnotateError.invalidMarker("choose a location or a shorter selection.")
        }
        guard marker.icon.utf8.count <= 128,
              marker.quote.utf8.count <= 1_048_576,
              marker.note.utf8.count <= 1_048_576,
              marker.question.utf8.count <= 1_048_576 else { throw AnnotateError.metadataTooLarge }
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

    /// Where a marker's comment icon sits, beside the start of its passage, and its tint.
    private static func commentPlacement(for marker: PDFMarker, on page: PDFPage) throws -> (bounds: CGRect, color: NSColor) {
        guard let first = marker.regions.first else { throw AnnotateError.invalidMarker("choose a location.") }
        let transform = page.transform(for: .cropBox)
        let crop = page.bounds(for: .cropBox).applying(transform)
        let passage = first.bounds.applying(transform)
        // PDFKit normalizes standard Text/comment icons to 24 points when saved.
        // Use that size up front so reopening does not expand them over the passage.
        let size = min(24.0, min(crop.width, crop.height))
        let x = min(max(crop.minX, passage.maxX + 3), crop.maxX - size)
        let y = min(max(crop.minY, passage.maxY + 3), crop.maxY - size)
        let bounds = CGRect(x: x, y: y, width: size, height: size).applying(transform.inverted())
        // PDFKit draws the standard comment glyph in dark ink. A pale category tint
        // keeps that glyph readable even when the marker itself uses a dark color.
        let color = NSColor(srgbRed: 0.75 + marker.color.red * 0.25,
                            green: 0.75 + marker.color.green * 0.25,
                            blue: 0.75 + marker.color.blue * 0.25, alpha: 1)
        return (bounds, color)
    }

    private static func commentTag(for marker: PDFMarker, on page: PDFPage) throws -> (tag: PDFAnnotation, popup: PDFAnnotation) {
        let (bounds, color) = try commentPlacement(for: marker, on: page)
        let tag = makeAnnotation(bounds, .text)
        tag.iconType = .comment
        tag.contents = readableContents(for: marker)
        tag.color = color
        tag.shouldDisplay = true
        tag.shouldPrint = true
        tag.userName = "Annotate"
        tag.modificationDate = Date()
        try identify(tag, marker: marker, payload: nil)
        // PDFKit does not automatically delete a serialized Text annotation's Popup.
        // Give both parts ownership so replacing or deleting a marker removes both.
        let popup = PDFAnnotation(bounds: CGRect(x: bounds.maxX + 7, y: bounds.minY, width: 240, height: 140), forType: .popup, withProperties: nil)
        popup.isOpen = false
        popup.shouldPrint = false
        try identify(popup, marker: marker, payload: nil)
        tag.popup = popup
        return (tag, popup)
    }

    /// Equal to within what a saved PDF keeps: colors to a 255th of a channel, sizes to a
    /// hundredth of a point.
    private static func sameColor(_ lhs: NSColor?, _ rhs: NSColor) -> Bool {
        guard let lhs = lhs?.usingColorSpace(.sRGB), let rhs = rhs.usingColorSpace(.sRGB) else { return false }
        return abs(lhs.redComponent - rhs.redComponent) < 0.5 / 255 && abs(lhs.greenComponent - rhs.greenComponent) < 0.5 / 255
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.5 / 255 && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.5 / 255
    }

    private static func sameBounds(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.01 && abs(lhs.minY - rhs.minY) < 0.01 && abs(lhs.width - rhs.width) < 0.01 && abs(lhs.height - rhs.height) < 0.01
    }

    /// The marker an annotation belongs to, if Annotate made it.
    private static func ownerID(of annotation: PDFAnnotation) -> UUID? {
        guard annotation.value(forAnnotationKey: ownerKey) as? String == ownerValue else { return nil }
        return (annotation.value(forAnnotationKey: identifierKey) as? String).flatMap(UUID.init(uuidString:))
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
        if symbol.contains("lightbulb") || symbol.contains("sparkle") { return "✦" }
        if symbol.contains("bookmark") { return "◆" }
        if symbol.contains("exclamation") { return "!" }
        if symbol.contains("heart") { return "♥" }
        if symbol.contains("quote") { return "“" }
        if symbol.contains("pin") { return "●" }
        return "≡"
    }
}
