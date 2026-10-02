import Foundation
import Testing
@testable import AnnotateCore

@Suite("Native font CMap resource limits")
struct NativeCMapBudgetTests {
    @Test("Repeated overlapping ranges consume the aggregate mapping budget")
    func repeatedRanges() {
        let map = "5 beginbfrange\n" + String(repeating: "<0000> <FFFF> <0000>\n", count: 5) + "endbfrange"
        #expect(throws: PDFNativeTextError.self) { try PDFNativeFont.cmap(Data(map.utf8)) }
    }

    /// PDFNativeFont.cmap: 262,144 mappings in all, four full two-byte ranges.
    @Test("The mapping budget admits exactly four full two-byte ranges")
    func mappingBudgetAtLimit() throws {
        let map = "4 begincidrange\n" + String(repeating: "<0000> <FFFF> 0\n", count: 4) + "endcidrange"
        let parsed = try PDFNativeFont.cmap(Data(map.utf8))
        #expect(parsed.cids.count == 65_536)
        #expect(parsed.cids[[0xFF, 0xFF]] == 65_535)
    }

    /// PDFNativeFont.cmap: at most 524,288 tokens.
    @Test("A CMap of exactly the token limit is read; one token more is refused", arguments: [(0, true), (1, false)])
    func tokenLimit(extra: Int, reads: Bool) throws {
        let data = Data(String(repeating: "1 ", count: 524_288 + extra).utf8)
        if reads { #expect(try PDFNativeFont.cmap(data).unicode.isEmpty) }
        else {
            #expect { try PDFNativeFont.cmap(data) } throws: { error in
                guard case .malformed(let message)? = error as? PDFNativeTextError else { return false }
                return message.contains("too many tokens")
            }
        }
    }

    /// PDFNativeFont.cmap: CMap streams up to 32 MiB.
    @Test("A CMap stream of exactly 32 MiB is read; one byte more is refused before lexing")
    func sizeLimit() throws {
        // One comment line: the lexer passes over it cheaply.
        let limit = 32 * 1_024 * 1_024
        var data = Data("%".utf8) + Data(repeating: UInt8(ascii: "x"), count: limit - 1)
        #expect(try PDFNativeFont.cmap(data).unicode.isEmpty)
        data.append(UInt8(ascii: "x"))
        #expect { try PDFNativeFont.cmap(data) } throws: { error in
            guard case .malformed(let message)? = error as? PDFNativeTextError else { return false }
            return message.contains("too large")
        }
    }

    /// PDFNativeFont.cmap: 16 MiB of decoded keys and values (a value counts twice).
    @Test("Decoded mappings may total exactly 16 MiB; one byte more is refused", arguments: [(2, true), (3, false)])
    func decodedBytesLimit(lastKeyBytes: Int, reads: Bool) throws {
        // Each mapping costs a 2-byte key plus a 31-byte value counted twice: 64 bytes, so the
        // whole mapping budget (262,144) costs exactly 16 MiB. The last mapping's key decides.
        let value = String(repeating: "41", count: 31)
        let lastKey = String(repeating: "FF", count: lastKeyBytes)
        let map = "4 beginbfrange\n" + String(repeating: "<0000> <FFFF> <\(value)>\n", count: 3)
            + "<0000> <FFFE> <\(value)>\nendbfrange\n1 beginbfchar\n<\(lastKey)> <\(value)>\nendbfchar"
        if reads { _ = try PDFNativeFont.cmap(Data(map.utf8)) }
        else {
            #expect { try PDFNativeFont.cmap(Data(map.utf8)) } throws: { error in
                guard case .malformed(let message)? = error as? PDFNativeTextError else { return false }
                return message.contains("decoded size")
            }
        }
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
