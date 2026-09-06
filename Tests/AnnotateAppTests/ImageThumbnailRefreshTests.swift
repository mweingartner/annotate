import AnnotateCore
import AppKit
import Observation
import PDFKit
import SwiftUI
import Testing
@testable import AnnotateApp

@Suite("Existing image thumbnail lifecycle", .serialized)
@MainActor
struct ImageThumbnailRefreshTests {
    @Test("Actual SwiftUI rows regenerate replacement and neighboring previews after delayed list refresh")
    func replacementRefresh() async throws {
        _ = NSApplication.shared
        let owner = AnnotateDocument()
        owner.model.load(try fixture(), owner: owner)
        let model = owner.model
        let state = ThumbnailListState(images: try model.imagesOnCurrentPage())
        let host = NSHostingView(rootView: ThumbnailListHarness(model: model, state: state))
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 150)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close(); owner.close() }
        #expect(try await eventually(host, red: 250, green: 250, blue: 0))

        let original = try #require(state.images.first)
        model.selectImage(original)
        model.imageEdit?.stageReplacement(try bitmap(.blue), name: "Blue.png")
        #expect(model.applyImageChanges())
        // Reproduce the real ordering: row receives the new model revision while
        // the parent's @State list still holds descriptors from the previous PDF.
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        let refreshed = try model.imagesOnCurrentPage()
        #expect(refreshed.first?.id == original.id)
        #expect(refreshed.first != original)
        state.images = refreshed
        #expect(try await eventually(host, red: 0, green: 250, blue: 250))
        let counts = try pixels(host)
        #expect(counts.red < 20)
    }

    private func eventually(_ host: NSView, red: Int, green: Int, blue: Int) async throws -> Bool {
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let counts = try pixels(host)
            if counts.red >= red && counts.green >= green && counts.blue >= blue { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private func pixels(_ host: NSView) throws -> (red: Int, green: Int, blue: Int) {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var red = 0, green = 0, blue = 0
        for y in 0..<bitmap.pixelsHigh {
            // Image previews occupy the first 80 points; exclude label colors.
            for x in 0..<min(bitmap.pixelsWide, Int(80 * CGFloat(bitmap.pixelsWide) / host.bounds.width)) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                // Compare dominance rather than a display-profile-dependent
                // brightness value when converting AppKit's PDF colors.
                if color.redComponent > color.greenComponent + 0.3 && color.redComponent > color.blueComponent + 0.3 { red += 1 }
                if color.greenComponent > color.redComponent + 0.3 && color.greenComponent > color.blueComponent + 0.3 { green += 1 }
                if color.blueComponent > color.redComponent + 0.3 && color.blueComponent > color.greenComponent + 0.3 { blue += 1 }
            }
        }
        return (red, green, blue)
    }

    private func fixture() throws -> PDFDocument {
        let data = NSMutableData(), consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        var media = CGRect(x: 0, y: 0, width: 400, height: 400)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.draw(try bitmap(.red), in: CGRect(x: 40, y: 70, width: 100, height: 50))
        context.draw(try bitmap(.green), in: CGRect(x: 220, y: 200, width: 100, height: 50))
        context.endPDFPage(); context.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }

    private func bitmap(_ color: NSColor) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color.cgColor); context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        return try #require(context.makeImage())
    }
}

@MainActor @Observable
private final class ThumbnailListState {
    var images: [PDFNativeImage]
    init(images: [PDFNativeImage]) { self.images = images }
}

private struct ThumbnailListHarness: View {
    @Bindable var model: ReaderModel
    @Bindable var state: ThumbnailListState
    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(state.images.enumerated()), id: \.element.id) { index, image in
                ImageSelectionRow(model: model, image: image, number: index + 1)
            }
        }
        .environment(\.colorScheme, .dark)
        .frame(width: 320, height: 150)
    }
}
