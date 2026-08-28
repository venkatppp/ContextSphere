import SwiftUI
import AppKit

// MARK: - Design tokens
//
// ContextSphere's design language.
//
// Principles:
// - Calm content layer, glass for navigation/control layer only.
// - Native materials and controls — nothing faked.
// - Hierarchy comes from spacing, typography, and material depth.
// - Information density without clutter (Raycast, Linear, Things).
// - Liquid Glass is intentional: sidebar, toolbar, hero chrome, search field,
//   command palette. Content uses standard materials, not glass-on-glass.

enum Theme {

    // Accent — system accent. Used sparingly, never decoratively.
    static let accent = Color.accentColor

    // MARK: Spacing scale
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 10
        static let l: CGFloat = 14
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
        static let xxxl: CGFloat = 40
    }

    // MARK: Radii
    static let cornerSmall: CGFloat = 6
    static let cornerRegular: CGFloat = 8
    static let cornerLarge: CGFloat = 12
    static let cornerXLarge: CGFloat = 16
    static let cornerPill: CGFloat = 999

    // MARK: Layout
    static let contentMaxWidth: CGFloat = 1120
    static let sidebarWidth: CGFloat = 232
    static let cardPadding: CGFloat = 16
    static let cardPaddingLarge: CGFloat = 20
    static let sectionGap: CGFloat = 22

    // MARK: Control heights (native-feel)
    enum Control {
        static let minHeightRegular: CGFloat = 24
        static let minHeightLarge: CGFloat = 32
        static let minHeightXLarge: CGFloat = 38
        static let fieldHeight: CGFloat = 30
    }

    // MARK: Animation
    static func spring(_ reduceMotion: Bool = false,
                       response: Double = 0.4,
                       damping: Double = 0.78) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: response, dampingFraction: damping)
    }
}

// MARK: - Typography
//
// A coherent type scale. Native system fonts only.
extension Font {

    /// Screen title (28pt semibold).
    static let csScreenTitle = Font.system(size: 26, weight: .semibold, design: .default)

    /// Section title (17pt semibold — same as .headline, but explicit).
    static let csSectionTitle = Font.system(size: 17, weight: .semibold, design: .default)

    /// Card title.
    static let csCardTitle = Font.system(size: 15, weight: .semibold, design: .default)

    /// Primary body.
    static let csBody = Font.system(size: 13, weight: .regular, design: .default)

    /// Secondary body.
    static let csSecondary = Font.system(size: 13, weight: .regular, design: .default)

    /// Metadata, captions.
    static let csMetadata = Font.system(size: 11, weight: .regular, design: .default)

    /// Small caps-style eyebrow labels (uppercased, tracked).
    static func csEyebrow(size: CGFloat = 11) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    /// Large metric/number display.
    static func csMetric(size: CGFloat = 28) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }
}

// MARK: - Content backdrop
//
// Calm, near-monochrome tint for the content layer. Respects Reduce
// Transparency and Reduce Motion.
struct ContentBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceTransparency || reduceMotion {
            Color(nsColor: .windowBackgroundColor)
        } else {
            ZStack {
                LinearGradient(
                    colors: scheme == .dark
                        ? [Color(red: 0.085, green: 0.090, blue: 0.115),
                           Color(red: 0.055, green: 0.060, blue: 0.085)]
                        : [Color(red: 0.965, green: 0.970, blue: 0.980),
                           Color(red: 0.930, green: 0.940, blue: 0.960)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .overlay {
                    RadialGradient(
                        colors: [Theme.accent.opacity(scheme == .dark ? 0.07 : 0.04), .clear],
                        center: .topTrailing,
                        startRadius: 0,
                        endRadius: 700
                    )
                }
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Surfaces

/// Calm content panel for the information layer. Material, not glass.
struct ContentCard<Content: View>: View {
    var cornerRadius: CGFloat = Theme.cornerLarge
    var padding: CGFloat = Theme.cardPaddingLarge
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
            }
    }
}

/// Compact content panel with smaller padding.
struct CompactCard<Content: View>: View {
    var cornerRadius: CGFloat = Theme.cornerRegular
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Theme.cardPadding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
            }
    }
}

/// Floating contextual chrome: glass that stays legible above the
/// content layer (hero panels, search fields, transient toolbars).
struct GlassSection<Content: View>: View {
    var tint: Color = .clear
    var interactive = false
    var cornerRadius: CGFloat = Theme.cornerLarge
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Theme.cardPaddingLarge)
            .glassEffect(
                interactive ? Glass.regular.interactive() : Glass.regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

/// Legacy `Theme.card` alias for existing views.
extension Theme {
    static func card<Content: View>(_ content: Content, cornerRadius: CGFloat = 14) -> some View {
        content
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
    }
}

// MARK: - Divider

/// Subtle hairline divider used between rows.
struct Hairline: View {
    var opacity: Double = 0.5
    var body: some View {
        Rectangle()
            .fill(.separator.opacity(opacity))
            .frame(height: 0.5)
    }
}

// MARK: - Headers

/// Page header shared by every screen: title + optional subtitle, with
/// optional trailing slot. Eyebrow-style group label sits above.
struct ScreenHeader<Content: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var eyebrow: String?
    @ViewBuilder var trailing: Content

    init(_ title: String,
         subtitle: String? = nil,
         symbol: String? = nil,
         eyebrow: String? = nil,
         @ViewBuilder trailing: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.eyebrow = eyebrow
        self.trailing = trailing()
    }

    init(_ title: String, subtitle: String? = nil, symbol: String? = nil, eyebrow: String? = nil) where Content == EmptyView {
        self.init(title, subtitle: subtitle, symbol: symbol, eyebrow: eyebrow) { EmptyView() }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                if let eyebrow {
                    Text(eyebrow)
                        .font(.csEyebrow())
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 10) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(.csScreenTitle)
                        .tracking(-0.4)
                        .accessibilityLabel(title)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// In-content section header.
struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var systemImageColor: Color = .secondary

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(systemImageColor)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.csEyebrow())
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
            if let subtitle {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - States

/// Premium empty-state: large title, calm subtitle, contextual action,
/// optional secondary detail block. No decorative noise.
struct EmptyStateView: View {
    let title: String
    var message: String?
    var symbol: String = "sparkles"
    var primaryAction: (label: String, perform: () -> Void)?
    var secondaryAction: (label: String, perform: () -> Void)?
    var details: [(String, String)]? = nil // (symbol, detail)

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }
            if let details, !details.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                        Label(detail.1, systemImage: detail.0)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 360, alignment: .leading)
            }
            if primaryAction != nil || secondaryAction != nil {
                HStack(spacing: 10) {
                    if let action = secondaryAction {
                        Button(action.label, action: action.perform)
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                    }
                    if let action = primaryAction {
                        Button(action.label, action: action.perform)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts = [title]
        if let message { parts.append(message) }
        return parts.joined(separator: ". ")
    }
}

/// Loading view: subtle progress + label.
struct LoadingView: View {
    var label = "Loading…"

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

/// Inline loading row (used inside cards/lists).
struct InlineLoading: View {
    var label = "Loading…"
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Badges / status indicators

/// Calm status badge used for system states. Rounded, tonal, small.
struct CSStatusBadge: View {
    enum Kind {
        case success, warning, error, info, neutral

        var color: Color {
            switch self {
            case .success: .green
            case .warning: .orange
            case .error: .red
            case .info: .blue
            case .neutral: .secondary
            }
        }

        var symbol: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.circle.fill"
            case .info: "info.circle.fill"
            case .neutral: "circle.fill"
            }
        }
    }

    let text: String
    var kind: Kind = .neutral
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage ?? kind.symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(kind.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(kind.color.opacity(0.12), in: Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

/// Compact, neutral chip used for grouping metadata.
struct MetaChip: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.caption2)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.4), in: Capsule(style: .continuous))
    }
}

// MARK: - Stat tile

/// A calm stat tile: large number, label, optional symbol.
struct CSStatTile: View {
    let value: String
    let label: String
    var symbol: String? = nil
    var trend: (text: String, isPositive: Bool)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(label)
                    .font(.csEyebrow())
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
            Text(value)
                .font(.csMetric(size: 24))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .monospacedDigit()
                .accessibilityLabel("\(label): \(value)")
            if let trend {
                HStack(spacing: 2) {
                    Image(systemName: trend.isPositive ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(trend.text)
                        .font(.caption2)
                }
                .foregroundStyle(trend.isPositive ? .green : .orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Toolbar

/// Native-feeling toolbar item with system-correct spacing.
struct ToolbarIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    var role: ButtonRole? = nil
    var isActive: Bool = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
    }
}

// MARK: - Hero card (used in Dashboard / Workspaces detail)

struct HeroCard<Content: View>: View {
    var cornerRadius: CGFloat = Theme.cornerXLarge
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Theme.cardPaddingLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
            }
    }
}

// MARK: - Pill button (used for filter chips / quick filters)

struct PillButton: View {
    let title: String
    var systemImage: String? = nil
    var isSelected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isSelected ? Theme.accent.opacity(0.18) : Color.clear,
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isSelected ? Theme.accent.opacity(0.4) : Color.secondary.opacity(0.35),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Banner (for warnings, errors, info across the app)

struct StatusBanner: View {
    enum Style {
        case warning, error, info
        var color: Color {
            switch self {
            case .warning: .orange
            case .error: .red
            case .info: .blue
            }
        }
        var symbol: String {
            switch self {
            case .warning: "exclamationmark.triangle"
            case .error: "xmark.octagon"
            case .info: "info.circle"
            }
        }
    }

    let message: String
    var style: Style = .info
    var detail: String? = nil
    var primaryAction: (label: String, perform: () -> Void)? = nil
    var secondaryAction: (label: String, perform: () -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: style.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(style.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.callout.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if let action = secondaryAction {
                    Button(action.label, action: action.perform)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                if let action = primaryAction {
                    Button(action.label, action: action.perform)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous)
                .fill(style.color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous)
                .strokeBorder(style.color.opacity(0.35), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Hover + selection helpers

/// View modifier for a calm row hover state.
struct HoverRowModifier: ViewModifier {
    let isHovered: Bool
    let isSelected: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isSelected
                          ? Theme.accent.opacity(0.18)
                          : (isHovered ? Color.primary.opacity(0.06) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.4) : .clear, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    /// Calm row treatment: subtle on hover, accent on selection.
    func hoverRow(isHovered: Bool, isSelected: Bool, cornerRadius: CGFloat = Theme.cornerRegular) -> some View {
        modifier(HoverRowModifier(isHovered: isHovered, isSelected: isSelected, cornerRadius: cornerRadius))
    }
}
