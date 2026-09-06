import Foundation
import Testing
@testable import AnnotateCore

@Suite("Native font CMap resource limits")
struct NativeCMapBudgetTests {
    @Test("Repeated overlapping ranges consume the aggregate mapping budget")
    func repeatedRanges() {
        let map = "3 beginbfrange\n" + String(repeating: "<0000> <FFFF> <0000>\n", count: 3) + "endbfrange"
        #expect(throws: PDFNativeTextError.self) { try PDFNativeFont.cmap(Data(map.utf8)) }
    }

    @Test("Long mapping destinations cannot multiply into unbounded decoded strings")
    func expandedStrings() {
        let largeValue = String(repeating: "0041", count: 32_768)
        let map = "1 beginbfrange\n<0000> <00FF> <\(largeValue)>\nendbfrange"
        #expect(throws: PDFNativeTextError.self) { try PDFNativeFont.cmap(Data(map.utf8)) }
    }

    @Test("Bounded Unicode and CID ranges still decode correctly")
    func boundedRanges() throws {
        let map = try PDFNativeFont.cmap(Data("""
        1 begincodespacerange <00> <FF> endcodespacerange
        1 beginbfrange <41> <43> <0041> endbfrange
        1 beginbfchar <44> <65E5672C8A9E> endbfchar
        1 begincidrange <50> <52> 10 endcidrange
        """.utf8))
        #expect(map.unicode[[0x41]] == "A")
        #expect(map.unicode[[0x43]] == "C")
        #expect(map.unicode[[0x44]] == "日本語")
        #expect(map.cids[[0x52]] == 12)
    }
}
