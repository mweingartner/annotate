import AppKit
import Foundation

public enum MarkerCategory: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case important, revisit, question, note

    public var title: String {
        switch self {
        case .important: "Important"
        case .revisit: "Revisit"
        case .question: "Question"
        case .note: "Note"
        }
    }

    public var symbol: String {
        switch self {
        case .important: "star.fill"
        case .revisit: "bookmark.fill"
        case .question: "questionmark.circle.fill"
        case .note: "note.text"
        }
    }
}

public struct MarkerColor: Codable, Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = Self.normalized(red)
        self.green = Self.normalized(green)
        self.blue = Self.normalized(blue)
    }

    private static func normalized(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: Self.normalized(red), green: Self.normalized(green), blue: Self.normalized(blue), alpha: 1)
    }

    /// Chooses the higher-contrast ink for an opaque swatch of this sRGB color.
    /// WCAG's relative-luminance formula gives black or white at least 4.5:1 contrast.
    /// https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html
    public var usesDarkInk: Bool {
        func linear(_ component: Double) -> Double {
            let value = Self.normalized(component)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        return blackContrast >= whiteContrast
    }

    public var readableInkColor: NSColor {
        let component = usesDarkInk ? 0.0 : 1.0
        return NSColor(srgbRed: component, green: component, blue: component, alpha: 1)
    }

    public static let palette: [MarkerColor] = [
        .init(red: 1, green: 0.79, blue: 0.20),
        .init(red: 0.44, green: 0.79, blue: 0.53),
        .init(red: 0.33, green: 0.70, blue: 0.96),
        .init(red: 0.75, green: 0.54, blue: 0.91),
        .init(red: 1, green: 0.53, blue: 0.59),
        .init(red: 1, green: 0.64, blue: 0.32)
    ]
}

public struct PageRegion: Codable, Equatable, Sendable {
    public var pageIndex: Int
    public var bounds: CGRect

    public init(pageIndex: Int, bounds: CGRect) {
        self.pageIndex = pageIndex
        self.bounds = bounds
    }
}

public struct PDFMarker: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var categories: Set<MarkerCategory>
    public var color: MarkerColor
    public var icon: String
    public var quote: String
    public var note: String
    public var question: String
    public var regions: [PageRegion]
    public var createdAt: Date

    public init(
        id: UUID = UUID(), categories: Set<MarkerCategory>, color: MarkerColor,
        icon: String, quote: String, note: String, question: String,
        regions: [PageRegion], createdAt: Date = Date()
    ) {
        self.id = id
        self.categories = categories
        self.color = color
        self.icon = icon
        self.quote = quote
        self.note = note
        self.question = question
        self.regions = regions
        self.createdAt = createdAt
    }

    public var pageIndex: Int { regions.first?.pageIndex ?? 0 }
}

public enum MarkerFilter: String, CaseIterable, Codable, Equatable, Sendable {
    case all, important, revisit, question, note

    public var title: String {
        switch self {
        case .all: "All markers"
        case .important: "Important"
        case .revisit: "Revisit"
        case .question: "Questions"
        case .note: "Notes"
        }
    }

    public var symbol: String {
        switch self {
        case .all: "square.stack.3d.up"
        case .important: MarkerCategory.important.symbol
        case .revisit: MarkerCategory.revisit.symbol
        case .question: MarkerCategory.question.symbol
        case .note: MarkerCategory.note.symbol
        }
    }

    public func matches(_ marker: PDFMarker) -> Bool {
        switch self {
        case .all: true
        case .important: marker.categories.contains(.important)
        case .revisit: marker.categories.contains(.revisit)
        case .question: marker.categories.contains(.question) || !marker.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .note: marker.categories.contains(.note) || !marker.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

public enum AnnotateError: LocalizedError, Sendable {
    case lockedDocument
    case commentingNotAllowed
    case exportNotAllowed
    case emptyDocument
    case invalidMarker(String)
    case metadataTooLarge
    case annotationWriteFailed
    case exportFailed
    case invalidPage(Int)

    public var errorDescription: String? {
        switch self {
        case .lockedDocument: "Unlock this PDF before using its contents."
        case .commentingNotAllowed: "This PDF does not allow annotations."
        case .exportNotAllowed: "This PDF's permissions do not allow creating a flattened shareable copy. Printing and copying must both be allowed."
        case .emptyDocument: "This PDF has no pages."
        case .invalidMarker(let reason): "The marker could not be saved: \(reason)"
        case .metadataTooLarge: "This marker is too large to save. Shorten the selected passage, note, or question."
        case .annotationWriteFailed: "PDFKit could not save the marker information. Your existing marker was kept."
        case .exportFailed: "The PDF could not be exported."
        case .invalidPage(let page): "Page \(page + 1) has invalid dimensions and could not be exported."
        }
    }
}
