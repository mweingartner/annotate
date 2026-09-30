import CoreGraphics

/// Atrium's spacing scale. Every gap, padding and margin in an Atrium app comes from here.
///
/// The scale sits on a 4 pt grid and deliberately skips the in-between values (6, 10, 14)
/// that make layouts feel hand-tuned. The HIG anchors two of the steps: about 12 pt around
/// controls with a bezel and about 24 pt around borderless ones (HIG › Layout).
public enum Spacing {
    /// 2 pt. Hairline nudges only: icon-to-badge, stacked caption lines.
    public static let hair: CGFloat = 2
    /// 4 pt. Inside a compound element: symbol to its label, title to its subtitle.
    public static let tight: CGFloat = 4
    /// 8 pt. Between items in a row or a tight stack.
    public static let snug: CGFloat = 8
    /// 12 pt. Between bezeled controls (HIG), and between rows of a form.
    public static let control: CGFloat = 12
    /// 16 pt. Between related groups inside one section.
    public static let group: CGFloat = 16
    /// 24 pt. Window content margins, and around borderless controls (HIG).
    public static let margin: CGFloat = 24
    /// 32 pt. Between sections on a page.
    public static let section: CGFloat = 32
    /// 48 pt. Around a page title or an empty state; the "breathing room" step.
    public static let room: CGFloat = 48

    /// The whole scale in ascending order, for tests and the gallery.
    public static let scale: [(name: String, value: CGFloat)] = [
        ("hair", hair), ("tight", tight), ("snug", snug), ("control", control),
        ("group", group), ("margin", margin), ("section", section), ("room", room),
    ]
}
