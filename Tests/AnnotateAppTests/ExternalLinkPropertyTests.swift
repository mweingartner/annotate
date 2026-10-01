import Foundation
import Testing
@testable import AnnotateApp

/// SplitMix64: every generated address replays from its seed.
private struct LinkRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 ^ 0xD1B5_4A32_D192_ED03 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The link policy over many generated and odd addresses: only web and mail links ever
/// ask, a refusal names the scheme it refused, and the address the reader is shown is the
/// whole address with nothing invisible in it.
@Suite("Links in a PDF: policy properties")
@MainActor
struct ExternalLinkPropertyTests {
    private static let openable: Set<String> = ["http", "https", "mailto"]

    private static func hasInvisible(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
        }
    }

    private static func randomCase(_ text: String, _ random: inout LinkRandom) -> String {
        String(text.map { Bool.random(using: &random) ? Character($0.uppercased()) : $0 })
    }

    @Test("Any scheme other than web or mail is refused, and the refusal names it", arguments: Array(UInt64(1)...UInt64(6)))
    func generatedSchemes(seed: UInt64) throws {
        var random = LinkRandom(seed: seed)
        let first = Array("abcdefghijklmnopqrstuvwxyz"), rest = Array("abcdefghijklmnopqrstuvwxyz0123456789+.-")
        var checked = 0
        for _ in 0..<500 {
            var scheme = String(first.randomElement(using: &random)!)
            scheme += String((0..<Int.random(in: 0...11, using: &random)).map { _ in rest.randomElement(using: &random)! })
            // Now and then, one of the openable schemes under any casing.
            if Int.random(in: 0..<5, using: &random) == 0 { scheme = Self.openable.randomElement(using: &random)! }
            scheme = Self.randomCase(scheme, &random)
            guard let url = URL(string: "\(scheme)://example.com/path?q=1") else { continue }
            checked += 1
            let lower = scheme.lowercased()
            switch ExternalLink(url) {
            case .confirm(let asked):
                #expect(Self.openable.contains(lower), "seed \(seed): \(scheme) asked to open")
                #expect(asked == url)
            case .refuse(let reason):
                #expect(!Self.openable.contains(lower), "seed \(seed): \(scheme) refused")
                #expect(reason.contains("\u{201C}\(lower):\u{201D}"), "seed \(seed): \(reason)")
            }
        }
        #expect(checked > 400)
    }

    @Test("A web link without a site is refused; a mail link needs none",
          arguments: ["https:///path", "https:example.com", "http:", "HTTP:relative", "https://?q=1", "https://#top"])
    func webWithoutSite(address: String) throws {
        let url = try #require(URL(string: address))
        guard case .refuse(let reason) = ExternalLink(url) else { Issue.record("\(address) would open"); return }
        #expect(reason.contains("no site"))
    }

    @Test("Mail links ask whatever follows the scheme", arguments: ["mailto:", "mailto:a@b.example", "MAILTO:a@b.example?subject=Hi&body=There", "mailto:?to=a@b.example"])
    func mailAsks(address: String) throws {
        let url = try #require(URL(string: address))
        #expect(ExternalLink(url) == .confirm(url))
    }

    /// Addresses a crafted PDF might use to mislead: credentials before the real host,
    /// look-alike letters, other dots, numeric and IPv6 hosts, ports, encoded hosts.
    nonisolated static let oddAddresses = [
        "https://good.example@evil.example/login",
        "https://user:password@evil.example:8443/a?b=c#d",
        "https://\u{0430}pple.com/",                 // Cyrillic a
        "https://b\u{00FC}cher.example/\u{00E4}?q=\u{00FC}",
        "https://example.com\u{3002}evil.com/",      // ideographic full stop
        "https://%65xample.com/",
        "http://127.0.0.1:631/",
        "http://[::1]:8080/x",
        "http://2130706433/",
        "https://example.com/\u{202E}fdp.exe",
        "https://example.com/a\u{2028}b\u{200B}c\u{0007}",
        "https://example.com/" + String(repeating: "very-long-segment/", count: 12_000),
        "https://" + String(repeating: "sub.", count: 60) + "example.com/",
    ]

    @Test("Odd but real web addresses ask, and the reader is shown the whole address", arguments: oddAddresses)
    func oddAddressShownWhole(address: String) throws {
        guard let url = URL(string: address) else { return }
        #expect(ExternalLink(url) == .confirm(url))
        let shown = ExternalLink.displayed(url)
        #expect(!Self.hasInvisible(shown), "\(shown.prefix(200))")
        // Complete, not shortened: Foundation already encodes anything invisible, so what is
        // shown is exactly the address that would open, host included.
        #expect(shown == url.absoluteString)
        // The host as written is visible. (A percent-encoded host is shown encoded, as
        // "%65xample.com" for example.com: complete, though not decoded for the reader.)
        let hosts = [url.host, url.host(percentEncoded: true)].compactMap { $0 }
        #expect(hosts.contains { shown.contains($0) }, "the host \(hosts) is visible")
        // Look-alike letters reach the reader as their punycode, not as the letters they imitate.
        if address.unicodeScalars.contains(where: { $0.value > 0x7F }) && url.host?.contains("xn--") == true {
            #expect(!shown.contains("\u{0430}"))
        }
    }

    @Test("Generated addresses: what's shown has nothing invisible and is the address that opens", arguments: Array(UInt64(30)...UInt64(33)))
    func generatedAddressesShown(seed: UInt64) {
        var random = LinkRandom(seed: seed)
        let pool: [Character] = Array("abcXYZ019-._~/?#=&%@:") + ["\u{202E}", "\u{202D}", "\u{2066}", "\u{2069}", "\u{200B}", "\u{200D}", "\u{FEFF}",
                                    "\u{2028}", "\u{2029}", "\u{0000}", "\u{0009}", "\u{000A}", "\u{001B}", "\u{007F}", "\u{0085}", "\u{00AD}",
                                    "\u{00E9}", "\u{4E2D}", "\u{1F600}", "\u{0430}", " "]
        for _ in 0..<400 {
            let tail = String((0..<Int.random(in: 0...40, using: &random)).map { _ in pool.randomElement(using: &random)! })
            guard let url = URL(string: "https://example.com/" + tail) else { continue }
            let shown = ExternalLink.displayed(url)
            #expect(!Self.hasInvisible(shown), "seed \(seed): \(tail.unicodeScalars.map { String($0.value, radix: 16) })")
            #expect(shown == url.absoluteString || shown.contains("\\u{"), "seed \(seed)")
            #expect(shown.count >= url.absoluteString.count, "seed \(seed): nothing is dropped")
        }
    }

    @Test("Deciding a link is deterministic and cheap, even for very long addresses")
    func deterministicAndCheap() throws {
        let url = try #require(URL(string: "https://example.com/?" + String(repeating: "a=b&", count: 250_000)))
        let clock = ContinuousClock(), start = clock.now
        let first = ExternalLink(url), shown = ExternalLink.displayed(url)
        #expect(clock.now - start < .seconds(5))
        #expect(ExternalLink(url) == first && ExternalLink.displayed(url) == shown)
        #expect(shown.count == url.absoluteString.count)
    }
}
