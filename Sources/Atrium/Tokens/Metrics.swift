import CoreGraphics

/// Window and pane sizes, so every Atrium app opens and resizes the same way instead of
/// each window picking its own minimum. The control sizes are the HIG's macOS values
/// (HIG › Layout: default 28×28 pt, minimum 20×20 pt).
public enum Metrics {
    /// Default height and width of a clickable target.
    public static let control: CGFloat = 28
    /// The smallest clickable target the HIG allows on macOS.
    public static let minimumControl: CGFloat = 20
    /// Height of a list row with one line of text.
    public static let row: CGFloat = 28
    /// Height of a list row with a title and a supporting line.
    public static let doubleRow: CGFloat = 44

    /// Sidebar width: minimum, ideal, maximum.
    public static let sidebar = (min: CGFloat(200), ideal: CGFloat(232), max: CGFloat(320))
    /// Inspector width: minimum, ideal, maximum.
    public static let inspector = (min: CGFloat(240), ideal: CGFloat(280), max: CGFloat(360))
    /// The narrowest a detail pane may get before the layout should collapse a column.
    public static let contentMinWidth: CGFloat = 440

    /// Readable measure for running text, about 65 characters of 13 pt SF Pro.
    public static let readableWidth: CGFloat = 560

    /// Minimum window size for a single-pane utility window.
    public static let utilityWindow = CGSize(width: 480, height: 320)
    /// Minimum window size for a sidebar + detail window.
    public static let mainWindow = CGSize(width: 760, height: 480)
    /// Width of a Settings window pane.
    public static let settingsWidth: CGFloat = 560
}
