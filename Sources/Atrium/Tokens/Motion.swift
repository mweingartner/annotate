import SwiftUI

/// Motion. Short springs that settle without bouncing; nothing loops, nothing
/// decorates. Every animation has a still alternative for Reduce Motion (HIG › Motion,
/// Accessibility). Use ``Motion/resolve(_:reduceMotion:)`` or the `atriumAnimation`
/// modifier rather than calling `withAnimation` with these directly.
public enum Motion {
    /// State changes a person caused: toggles, selection, disclosure.
    public static let respond = Animation.snappy(duration: 0.22)
    /// Content arriving or leaving: rows inserted, panels shown.
    public static let settle = Animation.smooth(duration: 0.32)
    /// A view moving between places (matched geometry, sheet content resizing).
    public static let travel = Animation.smooth(duration: 0.42)

    /// The animation to use given the Reduce Motion setting: a quick cross-fade
    /// instead of movement when it is on.
    public static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.12) : animation
    }
}

public extension View {
    /// Animates changes to `value` with an Atrium motion, falling back to a short
    /// cross-fade when Reduce Motion is on.
    func atriumAnimation<V: Equatable>(_ animation: Animation = Motion.respond, value: V) -> some View {
        modifier(AtriumAnimationModifier(animation: animation, value: value))
    }
}

private struct AtriumAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(Motion.resolve(animation, reduceMotion: reduceMotion), value: value)
    }
}
