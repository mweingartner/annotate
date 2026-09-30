import SwiftUI

/// Atrium's type roles. Each maps to a macOS built-in text style, so sizes stay on the
/// HIG's macOS scale (HIG › Typography, macOS text styles):
///
/// | Role | Style | Size / line |
/// |---|---|---|
/// | ``display`` | Large Title, serif, semibold | 26 / 32 |
/// | ``title`` | Title 2, serif, semibold | 17 / 22 |
/// | ``heading`` | Headline | 13 / 16 bold |
/// | ``body`` | Body | 13 / 16 |
/// | ``supporting`` | Callout | 12 / 15 |
/// | ``label`` | Subheadline, semibold | 11 / 14 |
/// | ``meta`` | Subheadline | 11 / 14 |
///
/// The signature is the serif: New York for page titles and empty states only, so it
/// reads as a voice rather than a theme. Everything a person operates stays in SF Pro.
/// Atrium never goes below 11 pt; the HIG's 10 pt macOS minimum is for badges only.
public enum Typography {
    /// Page titles, onboarding, empty-state titles. One per view.
    public static let display = Font.system(.largeTitle, design: .serif).weight(.semibold)
    /// Titles of a pane, a sheet or an inspector.
    public static let title = Font.system(.title2, design: .serif).weight(.semibold)
    /// Row titles that need emphasis, group headings inside a pane.
    public static let heading = Font.headline
    /// Running text and control labels.
    public static let body = Font.body
    /// Second lines, descriptions under a setting.
    public static let supporting = Font.callout
    /// Section labels above a group. Pair with `.foregroundStyle(.secondary)`.
    public static let label = Font.subheadline.weight(.semibold)
    /// Timestamps, counts, file sizes.
    public static let meta = Font.subheadline
    /// Numbers that line up in columns or tick while you watch them.
    public static let numeric = Font.body.monospacedDigit()
    /// Paths, identifiers, code.
    public static let code = Font.system(.body, design: .monospaced)
}
