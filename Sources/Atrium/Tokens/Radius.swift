import CoreGraphics

/// Corner radii. The HIG gives no fixed radii for cards or buttons; its rule is
/// concentricity: a shape nested inside another keeps the same visual curve
/// (HIG › Materials, Layout). Atrium keeps a small set of outer radii and derives inner
/// ones with ``Radius/concentric(outer:inset:)`` instead of guessing.
///
/// Prefer `ConcentricRectangle()` for shapes that sit inside a window, sheet or glass
/// container: the system then matches the container's corners automatically.
public enum Radius {
    /// 4 pt. Badges, tags, keycaps.
    public static let badge: CGFloat = 4
    /// 8 pt. Text fields, thumbnails, small wells.
    public static let field: CGFloat = 8
    /// 12 pt. The one content surface a page may have.
    public static let surface: CGFloat = 12
    /// 20 pt. Floating glass panels and popover-like overlays.
    public static let panel: CGFloat = 20

    /// The radius for a shape inset by `inset` points inside a shape with radius `outer`,
    /// so both curves share a centre. Never returns less than the badge radius,
    /// because a near-square corner inside a rounded one reads as a mistake.
    public static func concentric(outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(outer - inset, badge)
    }
}
