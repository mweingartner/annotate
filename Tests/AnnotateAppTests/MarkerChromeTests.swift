import AnnotateCore
import AppKit
import PDFKit
import Testing
@testable import AnnotateApp

@Suite("Marker pins replace drawn marker icons only in the viewer", .serialized)
@MainActor
struct MarkerChromeTests {
    private func reopened(with markers: [PDFMarker]) throws -> PDFDocument {
        let pdf = SamplePDF.make()
        for marker in markers { try MarkerCodec.apply(marker, to: pdf) }
        let data = try #require(pdf.dataRepresentation())
        let document = try #require(PDFDocument(data: data))
        document.delegate = MarkerChrome.documentDelegate
        // The reader remembers the markers it reads (ReaderModel.markers), and only those
        // are drawn as pins.
        MarkerChrome.remember(MarkerCodec.markers(in: document))
        return document
    }

    private func marker(quote: String, icon: String = "star.fill") -> PDFMarker {
        PDFMarker(categories: [.important], color: MarkerColor.palette[0], icon: icon, quote: quote, note: "", question: "",
                  regions: [PageRegion(pageIndex: 0, bounds: CGRect(x: 72, y: 600, width: 200, height: 14))])
    }

    @Test("Reopened marker annotations are viewer annotations; icons and comments are drawn by the viewer")
    func reopenedAnnotations() throws {
        let passage = marker(quote: "A passage")
        let bookmark = marker(quote: "", icon: "bookmark.fill")
        let document = try reopened(with: [passage, bookmark])
        let owned = try #require(document.page(at: 0)).annotations.filter {
            $0.value(forAnnotationKey: MarkerCodec.ownerKey) as? String == MarkerCodec.ownerValue && $0.type != "Popup"
        }
        #expect(owned.count == 6)
        for annotation in owned {
            switch annotation.type {
            case "FreeText", "Text":
                #expect(annotation is ViewerMarkerAnnotation, "\(annotation.type ?? "?") should be a viewer annotation")
                #expect(MarkerChrome.isDrawnByViewer(annotation))
            case "Highlight":
                // PDFView draws highlights itself; they stay ordinary annotations.
                #expect(!(annotation is ViewerMarkerAnnotation))
            default: Issue.record("Unexpected marker annotation \(annotation.type ?? "?")")
            }
        }
    }

    @Test("Output drawing always draws every marker annotation as saved")
    func outputDrawsEverything() async throws {
        let bookmark = marker(quote: "", icon: "bookmark.fill")
        let document = try reopened(with: [bookmark])
        let owned = try #require(document.page(at: 0)).annotations.filter { $0.type != "Popup" }
        MarkerChrome.drawingForOutput {
            for annotation in owned { #expect(!MarkerChrome.isDrawnByViewer(annotation)) }
        }
        await MarkerChrome.drawingForOutput {
            await Task.yield()
            for annotation in owned { #expect(!MarkerChrome.isDrawnByViewer(annotation)) }
        }
        #expect(owned.contains { MarkerChrome.isDrawnByViewer($0) })
    }

    private struct Interrupted: Error {}

    private func ownedIcon() throws -> PDFAnnotation {
        let document = try reopened(with: [marker(quote: "A passage")])
        return try #require(document.page(at: 0)?.annotations.first { $0.type == "FreeText" })
    }

    @Test("Output drawing ends when its work throws, so the viewer hides marker icons again")
    func outputEndsOnThrow() async throws {
        let icon = try ownedIcon()
        #expect(MarkerChrome.isDrawnByViewer(icon))
        #expect(throws: Interrupted.self) {
            try MarkerChrome.drawingForOutput {
                #expect(!MarkerChrome.isDrawnByViewer(icon))
                throw Interrupted()
            }
        }
        #expect(MarkerChrome.isDrawnByViewer(icon))
        await #expect(throws: Interrupted.self) {
            try await MarkerChrome.drawingForOutput {
                try await Task.sleep(for: .milliseconds(5))
                #expect(!MarkerChrome.isDrawnByViewer(icon))
                throw Interrupted()
            }
        }
        #expect(MarkerChrome.isDrawnByViewer(icon))
    }

    @Test("Output drawing nests, overlaps across tasks, and returns its work's value")
    func outputNestsAndOverlaps() async throws {
        let icon = try ownedIcon()
        let value = MarkerChrome.drawingForOutput { () -> Int in
            let inner = MarkerChrome.drawingForOutput { MarkerChrome.isDrawnByViewer(icon) ? 0 : 7 }
            // The inner job ending does not end the outer one.
            #expect(!MarkerChrome.isDrawnByViewer(icon))
            return inner * 6
        }
        #expect(value == 42)
        #expect(MarkerChrome.isDrawnByViewer(icon))
        // Two exports in flight at once: the first to finish must not re-hide icons the
        // other is still drawing.
        let (first, second) = (Task { @MainActor in
            await MarkerChrome.drawingForOutput { () async -> Bool in
                try? await Task.sleep(for: .milliseconds(10))
                return MarkerChrome.isDrawnByViewer(icon)
            }
        }, Task { @MainActor in
            await MarkerChrome.drawingForOutput { () async -> Bool in
                try? await Task.sleep(for: .milliseconds(40))
                return MarkerChrome.isDrawnByViewer(icon)
            }
        })
        #expect(await first.value == false)
        #expect(await second.value == false)
        #expect(MarkerChrome.isDrawnByViewer(icon))
    }

    @Test("Only an owned icon or comment is drawn by the viewer; its highlight and popup are not")
    func viewerOwnsOnlyIconAndComment() throws {
        let document = try reopened(with: [marker(quote: "A passage")])
        let annotations = try #require(document.page(at: 0)).annotations
        let drawnByViewer = Set(annotations.filter { MarkerChrome.isDrawnByViewer($0) }.compactMap(\.type))
        #expect(drawnByViewer == ["FreeText", "Text"])
        // Claiming Annotate's owner key is not enough to be hidden: the marker must be one
        // the reader knows. Then the class does not matter.
        let plain = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 10, height: 10), forType: .freeText, withProperties: nil)
        #expect(plain.setValue(MarkerCodec.ownerValue, forAnnotationKey: MarkerCodec.ownerKey))
        #expect(!MarkerChrome.isDrawnByViewer(plain), "No identifier")
        #expect(plain.setValue(UUID().uuidString, forAnnotationKey: MarkerCodec.identifierKey))
        #expect(!MarkerChrome.isDrawnByViewer(plain), "An identifier no marker has")
        let known = try #require(MarkerCodec.markers(in: document).first)
        #expect(plain.setValue(known.id.uuidString, forAnnotationKey: MarkerCodec.identifierKey))
        #expect(MarkerChrome.isDrawnByViewer(plain))
        #expect(!MarkerChrome.drawingForOutput { MarkerChrome.isDrawnByViewer(plain) })
    }

    @Test("Documents with the viewer delegate create viewer annotations only for icon and comment types")
    func delegateClasses() {
        let delegate = MarkerChrome.documentDelegate
        #expect(ObjectIdentifier(delegate.class(forAnnotationType: "FreeText")) == ObjectIdentifier(ViewerMarkerAnnotation.self))
        #expect(ObjectIdentifier(delegate.class(forAnnotationType: "Text")) == ObjectIdentifier(ViewerMarkerAnnotation.self))
        for type in ["Highlight", "Link", "Widget", "Popup", "Ink", ""] {
            #expect(ObjectIdentifier(delegate.class(forAnnotationType: type)) == ObjectIdentifier(PDFAnnotation.self), "\(type)")
        }
    }

    /// Non-white pixels an annotation paints into a page-sized bitmap.
    private func paintedPixels(_ annotation: PDFAnnotation) throws -> Int {
        let width = 612, height = 792
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        annotation.draw(with: .cropBox, in: context)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var painted = 0
        // Rows may be padded past the last pixel; count pixels only.
        for row in 0..<height {
            for column in 0..<width {
                let offset = row * context.bytesPerRow + column * 4
                if data[offset] < 250 || data[offset + 1] < 250 || data[offset + 2] < 250 { painted += 1 }
            }
        }
        return painted
    }

    @Test("A viewer icon paints nothing on the main thread in the viewer, and paints for output")
    func viewerAnnotationDrawing() throws {
        // The annotation draws through its page, so its document must stay alive.
        let document = try reopened(with: [marker(quote: "A passage")])
        let icon = try #require(document.page(at: 0)?.annotations.first { $0.type == "FreeText" })
        defer { withExtendedLifetime(document) {} }
        #expect(icon is ViewerMarkerAnnotation)
        let viewer = try paintedPixels(icon)
        #expect(viewer == 0)
        let output = try MarkerChrome.drawingForOutput { try paintedPixels(icon) }
        #expect(output > 20)
        // A foreign FreeText of the same class always paints.
        let foreign = ViewerMarkerAnnotation(bounds: CGRect(x: 100, y: 100, width: 40, height: 20), forType: .freeText, withProperties: nil)
        foreign.color = .systemRed
        foreign.contents = "X"
        let foreignPixels = try paintedPixels(foreign)
        #expect(foreignPixels > 20)
    }

    @Test("Foreign annotations are never hidden", arguments: ["FreeText", "Text"])
    func foreignAnnotations(type: String) {
        let foreign = ViewerMarkerAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20),
                                             forType: PDFAnnotationSubtype(rawValue: type), withProperties: nil)
        #expect(!MarkerChrome.isDrawnByViewer(foreign))
    }

    @Test("A bookmark's pin covers its icon and highlight as one tab; a passage's pin is its icon centred on its line")
    func pinFootprint() throws {
        let passage = marker(quote: "A passage")
        let bookmark = marker(quote: "", icon: "bookmark.fill")
        let document = try reopened(with: [])
        let page = try #require(document.page(at: 0))
        let icon = CGRect(x: 51, y: 596, width: 18, height: 18)
        // The passage's line (y 600, height 14) is centred 2 pt above the icon's centre.
        #expect(MarkerPin.footprint(of: passage, icon: icon, on: page) == icon.offsetBy(dx: 0, dy: 2))
        let tab = MarkerPin.footprint(of: PDFMarker(categories: [.revisit], color: MarkerColor.palette[0], icon: "bookmark.fill",
            quote: "", note: "", question: "", regions: [PageRegion(pageIndex: 0, bounds: CGRect(x: 72, y: 596, width: 20, height: 20))]),
            icon: icon, on: page)
        #expect(tab == icon.union(CGRect(x: 72, y: 596, width: 20, height: 20)))
        // A region far from its icon never stretches the pin across the page.
        #expect(MarkerPin.footprint(of: bookmark, icon: CGRect(x: 500, y: 100, width: 18, height: 18), on: page).width == 18)
    }

    @Test("A pin stays on its icon when the marked line is elsewhere, on another page, or unusable")
    func pinFootprintFallbacks() throws {
        let document = try reopened(with: [])
        let page = try #require(document.page(at: 0))
        let icon = CGRect(x: 51, y: 596, width: 18, height: 18)
        func passage(_ region: PageRegion) -> PDFMarker {
            PDFMarker(categories: [.important], color: MarkerColor.palette[0], icon: "star.fill", quote: "A passage",
                      note: "", question: "", regions: [region])
        }
        // A line more than an icon's height away (the icon was clamped at a page edge).
        #expect(MarkerPin.footprint(of: passage(PageRegion(pageIndex: 0, bounds: CGRect(x: 72, y: 560, width: 200, height: 14))),
                                    icon: icon, on: page) == icon)
        // Exactly an icon's height away still centres.
        let edge = CGRect(x: 72, y: 605 - 18 - 7, width: 200, height: 14)
        #expect(MarkerPin.footprint(of: passage(PageRegion(pageIndex: 0, bounds: edge)), icon: icon, on: page) == icon.offsetBy(dx: 0, dy: -18))
        // The marked line is on another page.
        #expect(MarkerPin.footprint(of: passage(PageRegion(pageIndex: 2, bounds: CGRect(x: 72, y: 600, width: 200, height: 14))),
                                    icon: icon, on: page) == icon)
        // Zero-height or non-finite lines.
        for line in [CGRect(x: 72, y: 600, width: 200, height: 0), CGRect(x: 72, y: CGFloat.nan, width: 200, height: 14),
                     CGRect(x: CGFloat.infinity, y: 600, width: 200, height: 14)] {
            #expect(MarkerPin.footprint(of: passage(PageRegion(pageIndex: 0, bounds: line)), icon: icon, on: page) == icon, "\(line)")
        }
        // A page outside any document has no index, so no line is found on it.
        #expect(MarkerPin.footprint(of: passage(PageRegion(pageIndex: 0, bounds: CGRect(x: 72, y: 600, width: 200, height: 14))),
                                    icon: icon, on: PDFPage()) == icon)
        // A bookmark's tab never grows taller than one and a half icons.
        let bookmark = PDFMarker(categories: [.revisit], color: MarkerColor.palette[0], icon: "bookmark.fill", quote: "",
                                 note: "", question: "", regions: [PageRegion(pageIndex: 0, bounds: CGRect(x: 72, y: 596, width: 20, height: 28))])
        #expect(MarkerPin.footprint(of: bookmark, icon: icon, on: page) == icon)
    }

    @Test("Flattened export draws each marker's icon as the viewer's pin, in its colour")
    func exportDrawsPins() throws {
        let passage = marker(quote: "A passage")
        let document = try reopened(with: [passage])
        let markers = MarkerCodec.markers(in: document)
        MarkerChrome.remember(markers)
        let page = try #require(document.page(at: 0))
        let badge = try #require(page.annotations.first { $0.type == "FreeText" })
        let (_, frame) = try #require(MarkerChrome.outputPin(for: badge))
        #expect(abs(frame.midY - passage.regions[0].bounds.midY) < 0.01, "The pin is centred on the marked line")
        let data = try MarkerChrome.drawingForOutput { try PDFExporter.flattenedData(document: document, markers: markers) }
        let exported = try #require(PDFDocument(data: data)?.page(at: 0))
        // The pin is artwork, not a text box.
        #expect(exported.string?.contains("★") != true)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(exported.bounds(for: .cropBox).width),
            pixelsHigh: Int(exported.bounds(for: .cropBox).height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
        exported.draw(with: .cropBox, to: context)
        // Just inside the pin's lower corner: the body colour, not white paper.
        let sample = try #require(bitmap.colorAt(x: Int(frame.minX + frame.width * 0.2),
                                                 y: bitmap.pixelsHigh - Int(frame.minY + frame.height * 0.2)))
        #expect(sample.blueComponent < 0.7, "Amber pin body expected, got \(sample)")
    }

    @Test("Pin frames: a thin or oversized icon falls back to a square pin; tabs are at most three pins wide")
    func pinFrameCaps() {
        let thin = MarkerPinArtwork.frame(icon: CGRect(x: 100, y: 100, width: 36, height: 0.01), line: nil, isBookmark: false)
        #expect(abs(thin.width - thin.height) < 0.001)
        let huge = MarkerPinArtwork.frame(icon: CGRect(x: 0, y: 0, width: 500, height: 500), line: nil, isBookmark: false)
        #expect(huge.width == 18 && huge.height == 18)
        let screen = MarkerPinArtwork.screenFrame(CGRect(x: 0, y: 0, width: 1000, height: 10))
        #expect(screen.height == 20)
        #expect(screen.width <= 60)
    }
}
