import SwiftUI
import AppKit

// MARK: - Design tokens

/// Shared design language for ContextSphere's native macOS surface.
///
/// Principles (Phase 3):
/// - Content layer stays calm and opaque. Glass is reserved for the
///   navigation/control layer and for contextual chrome that must float.
/// - Native materials and controls everywhere — nothing is faked.
/// - Hierarchy comes from spacing, typography and material depth, not
///   from stacking rounded "cards" at every level.
enum Theme {
    static let accent = Color.accentColor

    /// Max width for reading columns on wide windows.
    static let contentMaxWidth: CGFloat = 1120

    static let cornerSmall: CGFloat = 6
    static let cornerRegular: CGFloat = 10
    static let cornerLarge: CGFloat = 12

    /// Standard spring used for selection, expansion and materialization.
    /// Callers that already read `accessibilityReduceMotion` should prefer
    /// `Theme.spring(reduceMotion:)`.
    static func spring(_ reduceMotion: Bool = false,
                       response: Double = 0.4,
                       damping: Double = 0.78) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: response, dampingFraction: damping)
    }
}

// MARK: - App background

/// The content backdrop of every detail screen. A calm, near-monochrome
/// tint that gives Liquid Glass something to refract without the noise of
/// a decorative gradient wall. Respects Reduced Transparency.
struct ContentBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Color(nsColor: .windowBackgroundColor)
        } else if reduceTransparency {
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
                        colors: [Theme.accent.opacity(scheme == .dark ? 0.08 : 0.05), .clear],
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

/// A calm content panel. Material (not glass) is the correct surface for
/// the information layer; glass lives on the navigation/control layer.
struct ContentCard<Content: View>: View {
    var cornerRadius: CGFloat = Theme.cornerLarge
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
    }
}

/// Floating contextual chrome: glass that must stay legible above the
/// content layer (hero panels, pinned headers, hover surfaces).
struct GlassSection<Content: View>: View {
    var tint: Color = .clear
    var interactive = false
    var cornerRadius: CGFloat = Theme.cornerLarge
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .glassEffect(
                interactive ? Glass.regular.interactive() : Glass.regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

/// Legacy `Theme.card` alias so existing views keep compiling.
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

// MARK: - Typography / headers

/// Consistent page header shared by every screen: a large title, an
/// optional leading symbol, a subtitle, and optional trailing actions.
struct ScreenHeader<Content: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    @ViewBuilder var trailing: Content

    init(_ title: String, subtitle: String? = nil, symbol: String? = nil,
         @ViewBuilder trailing: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.trailing = trailing()
    }

    init(_ title: String, subtitle: String? = nil, symbol: String? = nil) where Content == EmptyView {
        self.init(title, subtitle: subtitle, symbol: symbol) { EmptyView() }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(.system(size: 28, weight: .semibold))
                        .tracking(-0.4)
                        .accessibilityLabel(title)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
    }
}

/// Section label used inside scrollable content.
struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var symbol: String?

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }
}

// MARK: - States

struct EmptyStateView: View {
    let title: String
    var message: String?
    var symbol: String = "sparkles"

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityElement(children: .combine)
    }
}

struct LoadingView: View {
    var label = "Connecting to ContextSphere core…"

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}