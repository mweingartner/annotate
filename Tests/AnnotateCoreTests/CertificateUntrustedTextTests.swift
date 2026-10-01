import Foundation
import Testing
@testable import AnnotateCore

@Suite("Certificate names shown as untrusted text")
struct CertificateUntrustedTextTests {
    @Test("Plain names pass through unchanged", arguments: [
        "Annotate Disposable Test Certificate", "Zoë Müller-Łukasiewicz", "山田 太郎", "مركز التوقيع", "", "Signer 🇫🇷 Team", "Cafe\u{0301}"
    ])
    func plain(text: String) {
        #expect(UntrustedText.display(text) == text)
    }

    @Test("Bidirectional embeddings, overrides, and isolates are removed", arguments: [
        ("Invoice\u{202E}fdp.exe", "Invoicefdp.exe"),
        ("\u{202A}A\u{202B}B\u{202C}C\u{202D}D", "ABCD"),
        ("\u{2066}A\u{2067}B\u{2068}C\u{2069}", "ABC"),
        ("\u{200E}Left\u{200F}Right\u{061C}", "LeftRight")
    ])
    func bidi(text: String, expected: String) {
        #expect(UntrustedText.display(text) == expected)
    }

    @Test("Line breaks and whitespace runs become single spaces, so a name stays on one line", arguments: [
        ("Mallory\nSignature intact · trusted certificate", "Mallory Signature intact · trusted certificate"),
        ("A\r\n\r\nB", "A B"),
        ("  A\t\t B \u{2028}C\u{2029}D\u{0085}E\u{00A0}\u{3000}F  ", "A B C D E F")
    ])
    func whitespace(text: String, expected: String) {
        let display = UntrustedText.display(text)
        #expect(display == expected)
        #expect(!display.contains { $0.isNewline })
    }

    @Test("Zero-width and other invisible characters are removed", arguments: [
        ("Pay\u{200B}Pal", "PayPal"),
        ("\u{FEFF}A\u{200C}B\u{200D}C\u{2060}D\u{00AD}E", "ABCDE"),
        ("Bell\u{07}\u{1B}[31mRed\u{7F}\u{00}", "Bell[31mRed"),
        // The joiner is a format character too: a joined emoji shows as its parts.
        ("👩🏽\u{200D}💻", "👩🏽💻")
    ])
    func invisible(text: String, expected: String) {
        #expect(UntrustedText.display(text) == expected)
    }

    @Test("Long names are shortened to the limit, ending in an ellipsis")
    func truncation() {
        let long = String(repeating: "a", count: 500)
        let display = UntrustedText.display(long)
        #expect(display.count == 120)
        #expect(display.hasSuffix("…"))
        #expect(UntrustedText.display("abcdef", limit: 4) == "abc…")
        #expect(UntrustedText.display("abcd", limit: 4) == "abcd")
        // The space before a cut is not kept in front of the ellipsis.
        #expect(UntrustedText.display("abc def", limit: 5) == "abc…")
        // Grapheme clusters are counted and never split.
        #expect(UntrustedText.display("🇫🇷🇫🇷🇫🇷", limit: 2) == "🇫🇷…")
        #expect(UntrustedText.display("abc", limit: 1) == "…")
        #expect(UntrustedText.display("abc", limit: 0) == "")
        #expect(UntrustedText.display("abc", limit: -3) == "")
    }

    @Test("Removed characters and collapsed whitespace count before truncation")
    func cleanedBeforeTruncation() {
        let padded = String(repeating: "\u{200B}", count: 1_000) + "Name" + String(repeating: "\n", count: 1_000) + "Here"
        #expect(UntrustedText.display(padded, limit: 20) == "Name Here")
    }
}
