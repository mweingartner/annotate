import SwiftUI

/// A list row: optional leading symbol, a title, an optional supporting line, and
/// trailing content. Use it in `List` or in a plain `VStack` separated by ``Hairline``.
///
/// The symbol renders hierarchically in the secondary colour, so rows stay quiet and
/// the accent is left for selection.
public struct Row<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    let trailing: Trailing

    public init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: Spacing.control) {
            if let systemImage {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text(title)
                    .font(Typography.body)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(Typography.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.snug)
            trailing
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: subtitle == nil ? Metrics.row : Metrics.doubleRow)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

public extension Row where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil) {
        self.init(title, subtitle: subtitle, systemImage: systemImage) { EmptyView() }
    }
}

/// A label on the left, a value on the right, digits aligned. For inspectors and
/// detail panes: file sizes, durations, counts.
public struct ValueRow: View {
    let label: String
    let value: String

    public init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.snug) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: Spacing.snug)
            Text(value)
                .font(Typography.numeric)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(Typography.body)
        .frame(minHeight: Metrics.row - Spacing.snug)
        .accessibilityElement(children: .combine)
    }
}

/// The separator Atrium uses in place of boxes and card borders.
public struct Hairline: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// A small status marker: symbol plus word, tinted by meaning. Never colour alone.
public struct StatusBadge: View {
    public enum Kind: Sendable {
        case positive, caution, critical, info, neutral

        var color: Color {
            switch self {
            case .positive: Palette.Status.positive
            case .caution: Palette.Status.caution
            case .critical: Palette.Status.critical
            case .info: Palette.Status.info
            case .neutral: .secondary
            }
        }

        var symbol: String {
            switch self {
            case .positive: "checkmark.circle.fill"
            case .caution: "exclamationmark.triangle.fill"
            case .critical: "xmark.octagon.fill"
            case .info: "info.circle.fill"
            case .neutral: "circle.fill"
            }
        }
    }

    let text: String
    let kind: Kind

    public init(_ text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }

    public var body: some View {
        Label {
            Text(text).foregroundStyle(.primary)
        } icon: {
            Image(systemName: kind.symbol).foregroundStyle(kind.color)
        }
        .font(Typography.meta)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.hair)
        // Symbols differ in height by kind; a fixed height keeps a column of badges aligned.
        .frame(height: 20)
        .background(kind.color.opacity(0.12), in: .rect(cornerRadius: Radius.badge))
    }
}
