import Testing
@testable import AnnotateCore

@Suite("Reading categories", .serialized)
@MainActor
struct MarkerFilterTests {
    @Test("Important and revisit markers remain accessible through their attached note and question")
    func combinedCategories() throws {
        let marker = try Fixtures.marker(in: Fixtures.document())
        #expect(MarkerFilter.all.matches(marker))
        #expect(MarkerFilter.important.matches(marker))
        #expect(MarkerFilter.revisit.matches(marker))
        #expect(MarkerFilter.note.matches(marker))
        #expect(MarkerFilter.question.matches(marker))
    }

    @Test("Empty supplemental text does not populate the notes or questions list")
    func emptySupplementalText() throws {
        let marker = try Fixtures.marker(in: Fixtures.document(), note: " \n ", question: "\t")
        #expect(!MarkerFilter.note.matches(marker))
        #expect(!MarkerFilter.question.matches(marker))
    }

    @Test("Explicit note or question category is listed before supplemental text exists")
    func explicitCategories() throws {
        var marker = try Fixtures.marker(in: Fixtures.document(), note: "", question: "")
        marker.categories = [.question, .note]
        #expect(MarkerFilter.note.matches(marker))
        #expect(MarkerFilter.question.matches(marker))
        #expect(!MarkerFilter.important.matches(marker))
        #expect(!MarkerFilter.revisit.matches(marker))
    }
}
