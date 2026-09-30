import SwiftUI

public extension View {
    /// Standard window content margins (24 pt, the HIG's spacing around borderless
    /// content). Apply once, to the scrolling content of a pane.
    func atriumPageMargins() -> some View {
        padding(Spacing.margin)
    }

    /// Caps running text at a readable measure and keeps it leading-aligned.
    func atriumReadableWidth() -> some View {
        frame(maxWidth: Metrics.readableWidth, alignment: .leading)
    }

    /// The one raised surface a page may have: solid control background, a hairline
    /// edge, no shadow. Content layer only; never nest one inside another.
    func atriumSurface(padding: CGFloat = Spacing.group) -> some View {
        self
            .padding(padding)
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: Radius.surface))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.surface)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            }
    }

    /// Liquid Glass for a floating control cluster (a transport bar, a zoom control, a
    /// floating action). Navigation layer only: the HIG keeps glass out of content.
    /// Reduce Transparency and Increase Contrast are handled by the system.
    func atriumFloatingGlass() -> some View {
        self
            .padding(.horizontal, Spacing.group)
            .padding(.vertical, Spacing.snug)
            .glassEffect(.regular, in: .rect(cornerRadius: Radius.panel))
    }
}

/// A button style for everything that isn't the primary action: text-and-symbol
/// buttons in content, row actions, disclosure-like controls. It replaces hand-built
/// `.buttonStyle(.plain)` buttons: a hover wash, a pressed wash, a 28 pt target and the
/// system keyboard focus ring, with nothing drawn at rest.
public struct QuietButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        QuietButton(configuration: configuration)
    }

    private struct QuietButton: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.horizontal, Spacing.snug)
                .frame(minWidth: Metrics.control, minHeight: Metrics.control)
                .background(wash, in: .rect(cornerRadius: Radius.field))
                .contentShape(.rect(cornerRadius: Radius.field))
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovered = $0 }
        }

        private var wash: Color {
            if configuration.isPressed { return Palette.pressed }
            if isHovered && isEnabled { return Palette.hover }
            return .clear
        }
    }
}

public extension ButtonStyle where Self == QuietButtonStyle {
    /// Atrium's quiet button. See ``QuietButtonStyle``.
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

/// An empty state with Atrium's voice: a symbol, a serif title, one sentence saying what
/// will appear here, and at most one action to add the first item.
public struct EmptyState: View {
    let title: String
    let message: String
    let systemImage: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(
        _ title: String,
        message: String,
        systemImage: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Spacing.group) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            VStack(spacing: Spacing.snug) {
                Text(title)
                    .font(Typography.title)
                Text(message)
                    .font(Typography.supporting)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, Spacing.snug)
            }
        }
        .padding(Spacing.room)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A titled group inside an inspector: label, content, and a hairline before the next
/// group. Inspectors are built from these, stacked, inside `.inspector(isPresented:)`.
public struct InspectorSection<Content: View>: View {
    let title: String
    let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            SectionHeader(title)
            content
        }
        .padding(.vertical, Spacing.group)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// A Settings pane in the classic Mac form layout: labels right-aligned in a column,
/// controls to their right, groups separated by space rather than boxes. Put one in
/// each tab of the app's `Settings` scene.
public struct SettingsPane<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        Form {
            content
        }
        .formStyle(.columns)
        .padding(Spacing.margin)
        .frame(width: Metrics.settingsWidth)
    }
}
