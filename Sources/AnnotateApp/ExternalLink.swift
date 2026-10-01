import AppKit
import Foundation

/// A link in a PDF that would leave Annotate. The PDF's author chooses its target, so
/// only web and mail links may open, and only once the reader has seen the whole address
/// and agreed; anything else (local files, network shares, other apps' URL schemes) is
/// refused with the reason.
enum ExternalLink: Equatable {
    /// Ask the reader before opening this address.
    case confirm(URL)
    /// Never open it; say why.
    case refuse(String)

    static let openableSchemes: Set<String> = ["http", "https", "mailto"]

    init(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        guard Self.openableSchemes.contains(scheme) else {
            self = .refuse(scheme.isEmpty
                ? "This link has no web address, so Annotate doesn't open it."
                : "This link opens \u{201C}\(scheme):\u{201D} content outside a web browser or mail, so Annotate doesn't open it.")
            return
        }
        if scheme != "mailto", url.host?.isEmpty ?? true {
            self = .refuse("This web link has no site, so Annotate doesn't open it.")
            return
        }
        self = .confirm(url)
    }

    /// A link to a page in another PDF file is refused: the author chooses which file.
    static let remoteDocument = ExternalLink.refuse("This link opens another file on your Mac or network, so Annotate doesn't open it.")

    /// What the reader is asked about: the site first, as people read the start of an
    /// address, a warning when the address hides it behind a user name, then the
    /// complete address.
    static func summary(_ url: URL) -> String {
        var lines: [String] = []
        if let host = url.host(percentEncoded: false), !host.isEmpty { lines.append("Site: \(displayed(host))") }
        if url.user(percentEncoded: false) != nil {
            lines.append("This address includes a user name before the site, which can make it look like a different site.")
        }
        lines.append(displayed(url))
        return lines.joined(separator: "\n\n")
    }

    /// The address as the reader sees it before agreeing: complete, on one line, with
    /// invisible and direction-changing characters shown escaped.
    static func displayed(_ url: URL) -> String { displayed(url.absoluteString) }

    static func displayed(_ text: String) -> String {
        text.unicodeScalars.map { scalar -> String in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                String(format: "\\u{%04X}", scalar.value)
            default: String(scalar)
            }
        }.joined()
    }
}
