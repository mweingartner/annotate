import AnnotateCore
import AppKit
import Observation
import PDFKit

@MainActor @Observable
final class ImageEditSession {
    let image: PDFNativeImage
    let sourceRevision: Int
    let pageBounds: CGRect
    let preview: NSImage?
    var x: Double
    var y: Double
    var width: Double { didSet { resizeFromWidth() } }
    var height: Double { didSet { resizeFromHeight() } }
    var keepsAspectRatio = true {
        didSet {
            if keepsAspectRatio, width.isFinite, height.isFinite, width > 0, height > 0 {
                aspectRatio = width / height
            }
        }
    }
    private(set) var replacement: CGImage?
    private(set) var replacementName: String?
    @ObservationIgnored weak var source: PDFDocument?
    @ObservationIgnored private var aspectRatio: Double
    @ObservationIgnored private var isResizing = false

    init(image: PDFNativeImage, source: PDFDocument, revision: Int, pageBounds: CGRect, preview: NSImage?) {
        self.image = image; self.source = source; self.sourceRevision = revision
        self.pageBounds = pageBounds; self.preview = preview
        x = image.bounds.minX; y = image.bounds.minY
        width = image.bounds.width; height = image.bounds.height
        aspectRatio = image.bounds.width / image.bounds.height
    }

    var bounds: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var geometryChanged: Bool { bounds != image.bounds }
    var hasChanges: Bool { geometryChanged || replacement != nil }
    var geometryIsValid: Bool {
        guard [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return false }
        // Existing clipped placements may extend outside the crop box. They can
        // still be replaced in place; newly entered placements must fit the page.
        return !geometryChanged || (image.canTransform && width >= 1 && height >= 1 && pageBounds.contains(bounds))
    }

    func stageReplacement(_ image: CGImage, name: String) {
        replacement = image; replacementName = name
    }

    func reset() {
        isResizing = true
        x = image.bounds.minX; y = image.bounds.minY
        width = image.bounds.width; height = image.bounds.height
        isResizing = false
        aspectRatio = width / height
        replacement = nil; replacementName = nil
    }

    private func resizeFromWidth() {
        guard !isResizing, keepsAspectRatio, width.isFinite, width > 0,
              aspectRatio.isFinite, aspectRatio > 0 else { return }
        isResizing = true; height = width / aspectRatio; isResizing = false
    }

    private func resizeFromHeight() {
        guard !isResizing, keepsAspectRatio, height.isFinite, height > 0,
              aspectRatio.isFinite, aspectRatio > 0 else { return }
        isResizing = true; width = height * aspectRatio; isResizing = false
    }
}
