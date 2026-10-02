import AppKit
import PDFKit
import Testing
@testable import AnnotateCore

/// An image's fingerprint identifies a page or page-tree node it reaches by type instead of
/// hashing it, so listing (other pages as placeholders) and editing (every page whole) agree.
/// These tests check that narrowing loses nothing else: a changed image, a changed resource
/// dictionary, or a changed stream that merely claims to be a page still makes an earlier
/// listing stale.
@Suite("Image fingerprints across page-tree references", .serialized)
@MainActor
struct ImageFingerprintTests {
    /// Two pages drawing one image. The image links to the second page, to a plain resource
    /// dictionary, and to a stream whose dictionary says it is a page.
    private func document(pixel: UInt8 = 200, note: String = "alpha", rotate: Int = 0, pageLike: UInt8 = 1, pageLikeType: String = "/Page",
                          impostor: String = "first") throws -> PDFDocument {
        let content = "q 100 0 0 80 40 200 cm /Im Do Q"
        return try #require(PDFDocument(data: NativeEditScopeTests.rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 /MediaBox [0 0 400 400] >>",
            "<< /Type /Page /Parent 2 0 R /Resources << /XObject << /Im 5 0 R >> >> /Contents 4 0 R >>",
            "<<",
            "<< /Type /XObject /Subtype /Image /Width 16 /Height 12 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Owner 6 0 R /Meta 7 0 R /Extra 8 0 R /Impostor 9 0 R",
            "<< /Type /Page /Parent 2 0 R /Rotate \(rotate) /Resources << /XObject << /Im 5 0 R >> >> /Contents 4 0 R >>",
            "<< /Note (\(note)) >>",
            "<< /Type \(pageLikeType)",
            // Typed as a page, but not in the page tree.
            "<< /Type /Page /Parent 2 0 R /Note (\(impostor)) >>"
        ], streams: [4: Data(content.utf8), 5: Data(repeating: pixel, count: 16 * 12 * 3), 8: Data(repeating: pageLike, count: 8)])))
    }

    private func listed(_ document: PDFDocument, page: Int = 0) throws -> PDFNativeImage {
        try #require(try PDFNativeImageEditor.images(in: document, pageIndex: page).first)
    }

    @Test("A listing applies to the same document, on either page that draws the image")
    func sameDocument() throws {
        let source = try document()
        for page in 0..<2 {
            let image = try listed(source, page: page)
            let result = try PDFNativeImageEditor.remove(in: source, image: image)
            #expect(try PDFNativeImageEditor.images(in: result, pageIndex: page).isEmpty)
        }
    }

    @Test("A changed image, resource dictionary, or page-like stream makes an earlier listing stale", arguments: ["pixels", "note", "page-like stream", "page-like stream type", "dictionary typed as a page"])
    func changesAreCaught(_ change: String) throws {
        let image = try listed(try document())
        let changed: PDFDocument = switch change {
        case "pixels": try document(pixel: 201)
        case "note": try document(note: "beta")
        case "page-like stream": try document(pageLike: 2)
        case "page-like stream type": try document(pageLikeType: "/Pages")
        default: try document(impostor: "second")
        }
        #expect(throws: PDFNativeImageError.staleSelection) { try PDFNativeImageEditor.remove(in: changed, image: image) }
        #expect(throws: PDFNativeImageError.staleSelection) { try PDFNativeImageEditor.preview(in: changed, image: image) }
        #expect(try listed(changed).id == image.id, "same position in the content")
        #expect(try listed(changed) != image)
    }

    @Test("A change to a page the image merely points at doesn't make the listing stale, by design")
    func pageReferenceIsIdentityOnly() throws {
        let image = try listed(try document())
        let rotated = try document(rotate: 90)
        #expect(try listed(rotated) == image)
        let result = try PDFNativeImageEditor.remove(in: rotated, image: image)
        #expect(try PDFNativeImageEditor.images(in: result, pageIndex: 0).isEmpty)
        #expect(result.page(at: 1)?.rotation == 90)
    }

    @Test("Listing is deterministic: the same bytes give the same fingerprints, whichever page is listed first")
    func deterministic() throws {
        let first = try document(), second = try document()
        let a = try (0..<2).map { try PDFNativeImageEditor.images(in: first, pageIndex: $0) }
        let b = try (0..<2).reversed().map { try PDFNativeImageEditor.images(in: second, pageIndex: $0) }.reversed()
        #expect(a == Array(b))
    }
}
