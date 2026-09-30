import SwiftUI

/// The top of a page: a serif title, an optional line of context, and an optional
/// trailing accessory (a count, a filter, one button). One per view.
///
/// ```swift
/// PageHeader("Voices", subtitle: "12 voices · 3 cloned") {
///     Button("New Voice", systemImage: "plus") { … }
/// }
/// ```
public struct PageHeader<Accessory: View>: View {
    let title: String
    let subtitle: String?
    let accessory: Accessory

    public init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.group) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(title)
                    .font(Typography.display)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(Typography.supporting)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Spacing.group)
            accessory
        }
        .padding(.bottom, Spacing.group)
    }
}

public extension PageHeader where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// A label above a group of related content. Small, semibold, secondary, with an
/// optional trailing detail. It replaces the grouped-form box: the label and the space
/// above it do the grouping.
public struct SectionHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    public init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(Typography.label)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Spacing.snug)
            trailing
                .font(Typography.meta)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, Spacing.snug)
    }
}

public extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// A titled block of content with Atrium's section rhythm: header, content, then
/// ``Spacing/section`` of room before whatever follows.
public struct PageSection<Content: View>: View {
    let title: String
    let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title)
            content
        }
        .padding(.bottom, Spacing.section)
    }
}
