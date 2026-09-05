import AppKit
import PDFKit
import Testing
@testable import AnnotateCore

@Suite("Addressable PDF comment tags", .serialized)
@MainActor
struct MarkerCommentTests {
    @Test("Comment tags have real hit-test bounds and preserve text across page transformations", arguments: [0, 90, 180, 270], [false, true])
    func addressableTag(rotation: Int, cropped: Bool) throws {
        let crop = cropped ? CGRect(x: 50, y: 80, width: 280, height: 340) : CGRect(x: 0, y: 0, width: 400, height: 500)
        let document = try Fixtures.geometryDocument(rotation: rotation, crop: crop)
        let marker = try Fixtures.marker(in: document, text: "Rotation sentinel", note: "Readable comment — 日本語", question: "Where is the source?")
        try MarkerCodec.apply(marker, to: document)
        let reopened = try Fixtures.reopen(document)
        let page = try #require(reopened.page(at: 0))
        let tags = page.annotations.filter { $0.type == "Text" }
        #expect(tags.count == 1)
        let tag = try #require(tags.first)
        #expect(tag.iconType == .comment)
        #expect(tag.contents == MarkerCodec.readableContents(for: marker))
        #expect(tag.shouldPrint && tag.shouldDisplay)
        #expect(page.bounds(for: .cropBox).insetBy(dx: -0.01, dy: -0.01).contains(tag.bounds))
        let transform = page.transform(for: .cropBox)
        let visibleTag = tag.bounds.applying(transform)
        let visiblePassage = marker.regions[0].bounds.applying(transform)
        #expect(visibleTag.minX >= visiblePassage.maxX)
        #expect(visibleTag.minY >= visiblePassage.maxY)
        #expect(page.annotation(at: CGPoint(x: tag.bounds.midX, y: tag.bounds.midY)) === tag)
        #expect(tag.value(forAnnotationKey: MarkerCodec.identifierKey) as? String == marker.id.uuidString)
        #expect(MarkerCodec.markers(in: reopened) == [marker])
        #expect(page.annotations.filter { $0.type == "Highlight" }.allSatisfy { $0.contents?.isEmpty ?? true })
        #expect(page.annotations.filter { $0.type == "FreeText" }.map(\.contents) == ["★"])
    }

    @Test("Legacy multi-page markers migrate once without changing metadata or foreign comments")
    func migrateLegacyComments() throws {
        let document = try Fixtures.document()
        let matches = document.findString("attention", withOptions: .caseInsensitive)
        let selection = PDFSelection(document: document)
        selection.add(try #require(matches.first))
        selection.add(try #require(matches.last))
        var marker = try Fixtures.marker(in: document)
        marker.regions = MarkerCodec.regions(for: selection, in: document)
        try MarkerCodec.apply(marker, to: document)
        for annotation in Fixtures.annotations(in: document) {
            if annotation.type == "Text" { annotation.page?.removeAnnotation(annotation) }
            if annotation.type == "Highlight" { annotation.contents = MarkerCodec.readableContents(for: marker) }
        }
        let firstPage = try #require(document.page(at: 0))
        let foreign = Fixtures.foreignAnnotation(on: firstPage)
        foreign.setValue(marker.id.uuidString, forAnnotationKey: MarkerCodec.identifierKey)
        foreign.setValue("external.reader", forAnnotationKey: MarkerCodec.ownerKey)
        let foreignHighlight = PDFAnnotation(bounds: CGRect(x: 300, y: 80, width: 60, height: 18), forType: .highlight, withProperties: nil)
        foreignHighlight.contents = "Foreign highlight comment"
        firstPage.addAnnotation(foreignHighlight)
        let legacy = try Fixtures.reopen(document)
        let oldCount = Fixtures.annotations(in: legacy).filter { $0.type != "Popup" }.count
        let anchor = try #require(Fixtures.annotations(in: legacy).first { $0.value(forAnnotationKey: MarkerCodec.metadataKey) != nil })
        let originalMetadata = anchor.value(forAnnotationKey: MarkerCodec.metadataKey) as? String

        MarkerCodec.refreshAppearance(in: legacy)
        let firstRefreshCount = Fixtures.annotations(in: legacy).count
        MarkerCodec.refreshAppearance(in: legacy)

        let updated = Fixtures.annotations(in: legacy)
        let owned = updated.filter { $0.value(forAnnotationKey: MarkerCodec.ownerKey) as? String == MarkerCodec.ownerValue }
        #expect(updated.filter { $0.type != "Popup" }.count == oldCount + 1)
        #expect(updated.count == firstRefreshCount)
        #expect(owned.filter { $0.type == "Text" }.count == 1)
        #expect(owned.filter { $0.type == "Highlight" }.allSatisfy { $0.contents?.isEmpty ?? true })
        #expect(anchor.value(forAnnotationKey: MarkerCodec.metadataKey) as? String == originalMetadata)
        #expect(updated.contains { $0.contents == "Foreign highlight comment" })
        #expect(updated.contains { $0.contents == "Another reader's annotation — preserve this." })
        #expect(MarkerCodec.markers(in: legacy) == [marker])
        #expect(MarkerCodec.markers(in: try Fixtures.reopen(legacy)) == [marker])
    }

    @Test("Unrecognized marker metadata never has its comments migrated")
    func malformedMetadataPreserved() throws {
        let document = try Fixtures.document()
        let marker = try Fixtures.marker(in: document)
        try MarkerCodec.apply(marker, to: document)
        let annotations = Fixtures.annotations(in: document)
        let anchor = try #require(annotations.first { $0.value(forAnnotationKey: MarkerCodec.metadataKey) != nil })
        anchor.setValue("invalid metadata", forAnnotationKey: MarkerCodec.metadataKey)
        anchor.contents = "Retain this unrecognized comment"
        for tag in annotations where tag.type == "Text" { tag.page?.removeAnnotation(tag) }
        let originalCount = Fixtures.annotations(in: document).count
        MarkerCodec.refreshAppearance(in: document)
        #expect(anchor.contents == "Retain this unrecognized comment")
        #expect(Fixtures.annotations(in: document).count == originalCount)
    }

    @Test("Export includes owned comment text once in the index, with no interactive tag left")
    func commentExport() throws {
        let document = try Fixtures.document()
        let marker = try Fixtures.marker(in: document, note: "NoteCommentIndexSentinel", question: "QuestionCommentIndexSentinel")
        try MarkerCodec.apply(marker, to: document)
        let exported = try #require(PDFDocument(data: PDFExporter.flattenedData(document: document, markers: [marker])))
        #expect(Fixtures.annotations(in: exported).isEmpty)
        let text = exported.string ?? ""
        #expect(text.components(separatedBy: "NoteCommentIndexSentinel").count - 1 == 1)
        #expect(text.components(separatedBy: "QuestionCommentIndexSentinel").count - 1 == 1)
    }

    @Test("Repeated saved comment updates and deletion leave no orphan popups and preserve foreign popup pairs")
    func popupLifecycle() throws {
        var document = try Fixtures.document()
        let page = try #require(document.page(at: 0))
        let foreign = Fixtures.foreignAnnotation(on: page)
        let foreignPopup = PDFAnnotation(bounds: CGRect(x: 300, y: 130, width: 120, height: 80), forType: .popup, withProperties: nil)
        foreignPopup.contents = "Foreign popup sentinel"
        foreign.popup = foreignPopup
        page.addAnnotation(foreignPopup)
        document = try Fixtures.reopen(document)
        let foreignCount = Fixtures.annotations(in: document).count
        let foreignPopupBounds = try #require(Fixtures.annotations(in: document).first { $0.type == "Popup" }).bounds
        let foreignPopupContents = try #require(Fixtures.annotations(in: document).first { $0.type == "Popup" }).contents
        var marker = try Fixtures.marker(in: document)
        try MarkerCodec.apply(marker, to: document)
        var stableCount: Int?

        for revision in 1...5 {
            document = try Fixtures.reopen(document)
            MarkerCodec.refreshAppearance(in: document)
            let annotations = Fixtures.annotations(in: document)
            #expect(annotations.filter { $0.type == "Popup" }.count == 2)
            #expect(annotations.filter { $0.type == "Popup" && $0.value(forAnnotationKey: MarkerCodec.ownerKey) as? String == MarkerCodec.ownerValue }.count == 1)
            if let stableCount { #expect(annotations.count == stableCount) }
            else { stableCount = annotations.count }
            marker.note = "Saved revision \(revision)"
            try MarkerCodec.apply(marker, to: document)
        }

        document = try Fixtures.reopen(document)
        MarkerCodec.refreshAppearance(in: document)
        MarkerCodec.remove(id: marker.id, from: document)
        let deleted = try Fixtures.reopen(document)
        let remaining = Fixtures.annotations(in: deleted)
        #expect(MarkerCodec.markers(in: deleted).isEmpty)
        #expect(remaining.count == foreignCount)
        #expect(remaining.contains { $0.contents == "Another reader's annotation — preserve this." })
        #expect(remaining.filter { $0.type == "Popup" }.count == 1)
        #expect(remaining.contains { $0.type == "Popup" && $0.bounds == foreignPopupBounds && $0.contents == foreignPopupContents })
    }

}
