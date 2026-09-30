import AnnotateCore
import AppKit
import PDFKit
import Testing
@testable import AnnotateApp

@Suite("Annotation interaction", .serialized)
@MainActor
struct AnnotationInteractionTests {
    @Test("Saved tags and icons resolve their marker while highlights remain selectable after zoom and rotation",
          arguments: [0, 90, 180, 270], [0.65, 1.0, 1.5])
    func ownedAnnotations(rotation: Int, scale: Double) throws {
        let fixture = try makeFixture(rotation: rotation, scale: scale)
        defer { fixture.window.close() }
        for marker in fixture.document.model.markers {
            let annotations = fixture.page.annotations.filter {
                $0.value(forAnnotationKey: MarkerCodec.identifierKey) as? String == marker.id.uuidString
            }
            #expect(Set(annotations.compactMap(\.type)) == ["Highlight", "FreeText", "Text", "Popup"])
            for annotation in annotations where annotation.type != "Popup" {
                let point = fixture.view.convert(center(of: annotation.bounds), from: fixture.page)
                #expect(fixture.view.bounds.contains(point))
                #expect(fixture.view.page(for: point, nearest: false) === fixture.page)
                let superviewPoint = fixture.view.convert(point, to: fixture.view.superview)
                let target = try #require(fixture.view.hitTest(superviewPoint))
                let result = AnnotationHitTesting.hit(at: point, in: fixture.view,
                                                      markers: fixture.document.model.markers)
                if annotation.type == "Highlight" {
                    #expect(result == nil, "Highlight text must retain PDFKit's selection handling.")
                    #expect(annotation.contents == nil, "Only the explicit comment tag should offer a note popup.")
                    #expect(target !== fixture.view, "PDFKit's document subview must receive highlight selection events.")
                    continue
                }
                #expect(target === fixture.view, "Owned tags and badges must bypass PDFKit's native annotation popup.")
                let hit = try #require(result)
                #expect(hit.marker == marker)
                #expect(hit.anchor.contains(point))
                #expect(hit.anchor.width > 0 && hit.anchor.height > 0)
            }
        }
    }

    @Test("Foreign comments and interactive PDF annotations keep native handling",
          arguments: ["Text", "Highlight", "FreeText", "Link", "Widget"])
    func foreignAnnotations(type: String) throws {
        let fixture = try makeFixture()
        defer { fixture.window.close() }
        let annotation = PDFAnnotation(bounds: CGRect(x: 275, y: 130, width: 80, height: 24),
                                       forType: PDFAnnotationSubtype(rawValue: type), withProperties: nil)
        annotation.contents = "This annotation belongs to another PDF reader."
        annotation.userName = "Another reader"
        if type == "Link" {
            annotation.action = PDFActionURL(url: try #require(URL(string: "https://example.com/")))
        }
        if type == "Widget" { annotation.widgetFieldType = .text }
        fixture.page.addAnnotation(annotation)
        fixture.view.annotationsChanged(on: fixture.page)
        let pagePoint = center(of: annotation.bounds)
        #expect(fixture.page.annotation(at: pagePoint) === annotation)
        let point = fixture.view.convert(pagePoint, from: fixture.page)
        #expect(AnnotationHitTesting.hit(at: point, in: fixture.view,
                                         markers: fixture.document.model.markers) == nil)
    }

    @Test("An overlapping foreign annotation takes precedence over an owned comment tag")
    func overlappingForeignAnnotation() throws {
        let fixture = try makeFixture()
        defer { fixture.window.close() }
        let comment = try #require(fixture.page.annotations.first { $0.type == "Text" })
        let link = PDFAnnotation(bounds: comment.bounds, forType: .link, withProperties: nil)
        link.action = PDFActionURL(url: try #require(URL(string: "https://example.com/source")))
        fixture.page.addAnnotation(link)
        fixture.view.annotationsChanged(on: fixture.page)
        let pagePoint = center(of: comment.bounds)
        #expect(fixture.page.annotation(at: pagePoint) === link)
        let point = fixture.view.convert(pagePoint, from: fixture.page)
        #expect(AnnotationHitTesting.hit(at: point, in: fixture.view,
                                         markers: fixture.document.model.markers) == nil)
    }

    @Test("Ownership metadata never overrides a PDF link, form, or action",
          arguments: ["Link", "Widget", "FreeText", "Text"])
    func ownedInteractiveAnnotations(type: String) throws {
        let fixture = try makeFixture()
        defer { fixture.window.close() }
        let marker = try #require(fixture.document.model.markers.first)
        let annotation = PDFAnnotation(bounds: CGRect(x: 275, y: 130, width: 80, height: 24),
                                       forType: PDFAnnotationSubtype(rawValue: type), withProperties: nil)
        #expect(annotation.setValue(MarkerCodec.ownerValue, forAnnotationKey: MarkerCodec.ownerKey))
        #expect(annotation.setValue(marker.id.uuidString, forAnnotationKey: MarkerCodec.identifierKey))
        if type == "Widget" { annotation.widgetFieldType = .text }
        if type != "Widget" {
            annotation.action = PDFActionURL(url: try #require(URL(string: "https://example.com/")))
        }
        fixture.page.addAnnotation(annotation)
        let point = fixture.view.convert(center(of: annotation.bounds), from: fixture.page)
        #expect(AnnotationHitTesting.hit(at: point, in: fixture.view,
                                         markers: fixture.document.model.markers) == nil)
    }

    @Test("A bookmark's highlight opens the bookmark, at every rotation; a passage's highlight stays text",
          arguments: [0, 90, 180, 270])
    func bookmarkHighlightOpensBookmark(rotation: Int) throws {
        let fixture = try makeFixture(rotation: rotation)
        defer { fixture.window.close() }
        // An empty-quote marker: a bookmark, placed in the top margin clear of text.
        let bookmark = PDFMarker(categories: [.revisit], color: MarkerColor.palette[1], icon: "bookmark.fill",
                                 quote: "", note: "", question: "",
                                 regions: [PageRegion(pageIndex: 0, bounds: CGRect(x: 300, y: 740, width: 20, height: 20))])
        try MarkerCodec.apply(bookmark, to: fixture.pdf)
        fixture.document.model.markers = MarkerCodec.markers(in: fixture.pdf)
        fixture.view.annotationsChanged(on: fixture.page)
        let markers = fixture.document.model.markers
        let highlight = try #require(fixture.page.annotations.first {
            $0.type == "Highlight" && $0.value(forAnnotationKey: MarkerCodec.identifierKey) as? String == bookmark.id.uuidString
        })
        let pagePoint = center(of: highlight.bounds)
        #expect(fixture.page.annotation(at: pagePoint) === highlight)
        let point = fixture.view.convert(pagePoint, from: fixture.page)
        let hit = try #require(AnnotationHitTesting.hit(at: point, in: fixture.view, markers: markers))
        #expect(hit.marker.id == bookmark.id)
        #expect(hit.anchor.contains(point))
        // The click is routed to the reader, not PDFKit's text selection.
        #expect(fixture.view.hitTest(fixture.view.convert(point, to: fixture.view.superview)) === fixture.view)

        // Every passage highlight still returns nil.
        for passage in markers where !passage.isBookmark {
            for annotation in fixture.page.annotations where annotation.type == "Highlight"
                && annotation.value(forAnnotationKey: MarkerCodec.identifierKey) as? String == passage.id.uuidString {
                let passagePoint = fixture.view.convert(center(of: annotation.bounds), from: fixture.page)
                #expect(AnnotationHitTesting.hit(at: passagePoint, in: fixture.view, markers: markers) == nil)
            }
        }
        // Whether a highlight opens follows the marker it belongs to: once the marker has a
        // quote, the same highlight is text again.
        let quoted = markers.map { $0.id == bookmark.id ? PDFMarker(id: $0.id, categories: $0.categories, color: $0.color,
            icon: $0.icon, quote: "Now a passage", note: "", question: "", regions: $0.regions, createdAt: $0.createdAt) : $0 }
        #expect(AnnotationHitTesting.hit(at: point, in: fixture.view, markers: quoted) == nil)
        // With its highlight and its pin's icon annotation both hidden, nothing is intercepted.
        let icon = try #require(fixture.page.annotations.first {
            $0.type == "FreeText" && $0.value(forAnnotationKey: MarkerCodec.identifierKey) as? String == bookmark.id.uuidString
        })
        highlight.shouldDisplay = false
        icon.shouldDisplay = false
        #expect(AnnotationHitTesting.hit(at: point, in: fixture.view, markers: markers) == nil)
    }

    @Test("A hidden pin, or one carrying a link, is never taken for a marker, even where the pin would be")
    func hiddenOrLinkedPinsStayWithPDFKit() throws {
        // At half size the 18 pt icon is smaller on screen than a pin's minimum target.
        let fixture = try makeFixture(scale: 0.65)
        defer { fixture.window.close() }
        let markers = fixture.document.model.markers
        let icon = try #require(fixture.page.annotations.first { $0.type == "FreeText" })
        let marker = try #require(markers.first { $0.id.uuidString == icon.value(forAnnotationKey: MarkerCodec.identifierKey) as? String })
        // The icon's centre, and a point in the pin's enlarged on-screen target that lies
        // outside the icon annotation (only the pin fallback finds that one).
        let centre = fixture.view.convert(CGPoint(x: icon.bounds.midX, y: icon.bounds.midY), from: fixture.page)
        let target = MarkerPinArtwork.screenFrame(fixture.view.convert(MarkerPin.footprint(of: marker, icon: icon.bounds, on: fixture.page), from: fixture.page))
        let iconOnScreen = fixture.view.convert(icon.bounds, from: fixture.page)
        var points = [centre]
        if target.minX < iconOnScreen.minX - 1 { points.append(CGPoint(x: (target.minX + iconOnScreen.minX) / 2, y: target.midY)) }
        for point in points {
            #expect(AnnotationHitTesting.hit(at: point, in: fixture.view, markers: markers)?.marker.id == marker.id, "\(point)")
            icon.shouldDisplay = false
            #expect(AnnotationHitTesting.hit(at: point, in: fixture.view, markers: markers) == nil, "hidden, \(point)")
            icon.shouldDisplay = true
            icon.action = PDFActionURL(url: try #require(URL(string: "https://example.com/")))
            #expect(AnnotationHitTesting.hit(at: point, in: fixture.view, markers: markers) == nil, "linked, \(point)")
            icon.action = nil
        }
    }

    @Test("A foreign highlight that shares a bookmark's identity but not its owner stays with PDFKit")
    func foreignHighlightWithBookmarkIdentity() throws {
        let fixture = try makeFixture()
        defer { fixture.window.close() }
        let bookmark = PDFMarker(categories: [.revisit], color: MarkerColor.palette[1], icon: "bookmark.fill",
                                 quote: "", note: "", question: "",
                                 regions: [PageRegion(pageIndex: 0, bounds: CGRect(x: 300, y: 740, width: 20, height: 20))])
        let foreign = PDFAnnotation(bounds: CGRect(x: 400, y: 740, width: 20, height: 20), forType: .highlight, withProperties: nil)
        #expect(foreign.setValue(bookmark.id.uuidString, forAnnotationKey: MarkerCodec.identifierKey))
        fixture.page.addAnnotation(foreign)
        let point = fixture.view.convert(center(of: foreign.bounds), from: fixture.page)
        #expect(AnnotationHitTesting.hit(at: point, in: fixture.view, markers: fixture.document.model.markers + [bookmark]) == nil)
    }

    @Test("Missing, unknown, and malformed marker identities fall back to PDFKit",
          arguments: ["missingMarker", "missingOwner", "foreignOwner", "missingIdentifier", "invalidIdentifier"])
    func unresolvedOwnership(scenario: String) throws {
        let fixture = try makeFixture()
        defer { fixture.window.close() }
        let annotation = try #require(fixture.page.annotations.first { $0.type == "FreeText" })
        var markers = fixture.document.model.markers
        switch scenario {
        case "missingMarker": markers.removeAll()
        case "missingOwner": annotation.removeValue(forAnnotationKey: MarkerCodec.ownerKey)
        case "foreignOwner":
            #expect(annotation.setValue("AnotherReader", forAnnotationKey: MarkerCodec.ownerKey))
        case "missingIdentifier": annotation.removeValue(forAnnotationKey: MarkerCodec.identifierKey)
        default:
            #expect(annotation.setValue("not-a-uuid", forAnnotationKey: MarkerCodec.identifierKey))
        }
        let point = fixture.view.convert(center(of: annotation.bounds), from: fixture.page)
        #expect(AnnotationHitTesting.hit(at: point, in: fixture.view, markers: markers) == nil)
    }

    @Test("Unmarked text and points outside the PDF remain available to native selection")
    func ordinarySelectionLocations() throws {
        let fixture = try makeFixture()
        defer { fixture.window.close() }
        let selection = try #require(fixture.pdf.findString("A better way to return", withOptions: []).first)
        let ordinaryText = fixture.view.convert(center(of: selection.bounds(for: fixture.page)), from: fixture.page)
        #expect(fixture.page.annotation(at: fixture.view.convert(ordinaryText, to: fixture.page)) == nil)
        let nativeTarget = try #require(fixture.view.hitTest(fixture.view.convert(ordinaryText, to: fixture.view.superview)))
        #expect(nativeTarget !== fixture.view)
        for point in [ordinaryText, CGPoint(x: -1, y: -1),
                      CGPoint(x: fixture.view.bounds.maxX + 1, y: fixture.view.bounds.maxY + 1)] {
            #expect(AnnotationHitTesting.hit(at: point, in: fixture.view,
                                             markers: fixture.document.model.markers) == nil)
        }
    }

    @Test("The click gate converts window coordinates and preserves modifier gestures", arguments: ["Text", "FreeText"])
    func clickGate(type: String) throws {
        let fixture = try makeFixture()
        defer { fixture.window.close() }
        let annotation = try #require(fixture.page.annotations.first { $0.type == type })
        let viewPoint = fixture.view.convert(center(of: annotation.bounds), from: fixture.page)
        let windowPoint = fixture.view.convert(viewPoint, to: nil)
        #expect(windowPoint != viewPoint, "The fixture must exercise an embedded view's coordinate conversion.")
        let click = try event(at: windowPoint, in: fixture.window)
        #expect(fixture.view.annotationHit(for: click) != nil)
        for modifier: NSEvent.ModifierFlags in [.shift, .command, .option, .control, [.shift, .command]] {
            let modified = try event(at: windowPoint, in: fixture.window, modifiers: modifier)
            #expect(fixture.view.annotationHit(for: modified) == nil)
        }
        for type: NSEvent.EventType in [.leftMouseUp, .leftMouseDragged, .rightMouseDown] {
            let otherEvent = try event(at: windowPoint, in: fixture.window, type: type)
            #expect(fixture.view.annotationHit(for: otherEvent) == nil)
        }
        fixture.view.model = nil
        #expect(fixture.view.annotationHit(for: click) == nil)
    }

    @Test("Dragging or releasing away from the pressed tag cancels the annotation popup",
          arguments: ["drag", "releaseOutside", "releaseOnDifferentMarker"])
    func interruptedTagClicks(scenario: String) throws {
        let fixture = try makeFixture()
        defer { fixture.window.close() }
        let tags = fixture.page.annotations.filter { $0.type == "Text" }
        #expect(tags.count == 2)
        let first = try #require(tags.first)
        let start = fixture.view.convert(fixture.view.convert(center(of: first.bounds), from: fixture.page), to: nil)
        #expect(fixture.view.annotationHit(for: try event(at: start, in: fixture.window)) != nil)
        #expect(fixture.document.model.selectedMarkerID == nil)
        fixture.view.mouseDown(with: try event(at: start, in: fixture.window))
        var end = start
        if scenario == "drag" {
            fixture.view.mouseDragged(with: try event(at: CGPoint(x: start.x + 10, y: start.y),
                                                       in: fixture.window, type: .leftMouseDragged))
        } else if scenario == "releaseOutside" {
            end = fixture.view.convert(CGPoint(x: -10, y: -10), to: nil)
        } else {
            let other = try #require(tags.last)
            end = fixture.view.convert(fixture.view.convert(center(of: other.bounds), from: fixture.page), to: nil)
        }
        fixture.view.mouseUp(with: try event(at: end, in: fixture.window, type: .leftMouseUp))
        #expect(fixture.view.annotationPopover == nil)
        #expect(fixture.document.model.selectedMarkerID == nil)
        #expect(!fixture.document.isDocumentEdited)
    }

    private struct Fixture {
        let document: AnnotateDocument
        let pdf: PDFDocument
        let page: PDFPage
        let view: SelectionPDFView
        let window: NSWindow
    }

    private func makeFixture(rotation: Int = 0, scale: Double = 1) throws -> Fixture {
        _ = NSApplication.shared
        let original = SamplePDF.make()
        for index in (1..<original.pageCount).reversed() { original.removePage(at: index) }
        for text in ["attention", "Select a few words"] {
            let selection = try #require(original.findString(text, withOptions: .caseInsensitive).first)
            let marker = PDFMarker(categories: [.important, .note], color: MarkerColor.palette[0],
                                   icon: "star.fill", quote: selection.string ?? text,
                                   note: "Saved note for \(text).", question: "",
                                   regions: MarkerCodec.regions(for: selection, in: original))
            try MarkerCodec.apply(marker, to: original)
        }
        // Exercise serialized PDF annotations, as encountered when opening an existing file.
        let savedData = try #require(original.dataRepresentation())
        let pdf = try #require(PDFDocument(data: savedData))
        let page = try #require(pdf.page(at: 0))
        page.rotation = rotation
        let document = AnnotateDocument()
        document.model.load(pdf, owner: document)
        #expect(document.model.markers.count == 2)
        let view = SelectionPDFView(frame: CGRect(x: 37, y: 51, width: 1_400, height: 1_400))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1_500, height: 1_500),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        view.displayMode = .singlePage
        view.displayBox = .cropBox
        view.document = pdf
        view.autoScales = false
        view.scaleFactor = scale
        view.layoutDocumentView()
        view.layoutSubtreeIfNeeded()
        view.model = document.model
        document.model.pdfView = view
        return Fixture(document: document, pdf: pdf, page: page, view: view, window: window)
    }

    private func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    private func event(at point: CGPoint, in window: NSWindow, type: NSEvent.EventType = .leftMouseDown,
                       modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 1, clickCount: 1, pressure: 1))
    }
}
