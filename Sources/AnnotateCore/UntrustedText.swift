import Foundation

/// Text that came from a file rather than from Annotate, prepared for display on one
/// line. A certificate name or field name in a PDF can carry line breaks, bidirectional
/// overrides that reverse what follows, or invisible characters that make it imitate
/// a status or another name; none of those survive.
public enum UntrustedText {
    /// Removes control characters (Cc) and format characters (Cf, including bidirectional
    /// embeddings, overrides and isolates, and zero-width characters), collapses each run
    /// of whitespace to one space, trims the ends, and shortens the result to at most
    /// `limit` characters, ending in an ellipsis when shortened.
    public static func display(_ text: String, limit: Int = 120) -> String {
        guard limit > 0 else { return "" }
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            // Whitespace first: line breaks and tabs are also controls, but they separate words.
            if scalar.properties.isWhitespace {
                pendingSpace = !scalars.isEmpty
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format: continue
            default: break
            }
            if pendingSpace { scalars.append(" "); pendingSpace = false }
            scalars.append(scalar)
        }
        let cleaned = String(scalars)
        guard cleaned.count > limit else { return cleaned }
        let kept = cleaned.prefix(limit - 1)
        return kept.trimmingCharacters(in: .whitespaces) + "…"
    }
}
