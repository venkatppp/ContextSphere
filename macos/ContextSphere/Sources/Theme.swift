import SwiftUI
import AppKit

// MARK: - Design system
//
// ContextSphere's design language.
//
// Principles:
// - Calm content layer, glass for navigation/control layer only.
// - Native materials and controls — nothing faked.
// - Hierarchy from spacing, typography, and material depth.
// - Information density without clutter (Raycast, Linear, Things).
// - Liquid Glass is intentional: sidebar, toolbar, hero chrome, search
//   field, command palette. Content uses standard materials.
// - Semantic tokens over hardcoded values. Every screen reads from the
//   same palette. Dark and light are first-class themes.

// MARK: - Theme mode

/// User-selectable theme. `system` follows macOS appearance.
enum AppearanceMode: String, CaseIterable, Identifiable, Hashable, Codable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
    /// Resolves the mode against the current system appearance.
    func resolved(scheme: ColorScheme) -> ColorScheme {
        switch self {
        case .system: scheme
        case .light: .light
        case .dark: .dark
        }
    }
}

// MARK: - Semantic tokens

/// All semantic colors used by the app. Two palettes, one for dark, one
/// for light. Resolved via `Color.cs(...)` extensions at the call site.
enum CSColor {
    // Layered surfaces
    static let backdropTop       = "backdrop.top"
    static let backdropBottom    = "backdrop.bottom"
    static let backdropAccent    = "backdrop.accent"
    static let surface           = "surface"
    static let surfaceElevated   = "surface.elevated"
    static let surfaceSidebar    = "surface.sidebar"
    static let surfaceChrome     = "surface.chrome"
    static let surfaceHero       = "surface.hero"
    static let surfaceField      = "surface.field"   // graph canvas wash

    // Text
    static let textPrimary       = "text.primary"
    static let textSecondary     = "text.secondary"
    static let textTertiary      = "text.tertiary"
    static let textOnAccent      = "text.onAccent"

    // Structure
    static let border            = "border"
    static let borderSubtle      = "border.subtle"
    static let separator         = "separator"
    static let hoverFill         = "hover.fill"
    static let selectionFill     = "selection.fill"
    static let selectionBorder   = "selection.border"

    // Status
    static let success           = "status.success"
    static let warning           = "status.warning"
    static let error             = "status.error"
    static let info              = "status.info"

    // Graph nodes (semantic)
    static let graphWorkspace       = "graph.workspace"
    static let graphFile            = "graph.file"
    static let graphSession         = "graph.session"
    static let graphExecution       = "graph.execution"
    static let graphMemory          = "graph.memory"
    static let graphIntelligence    = "graph.intelligence"
    static let graphEvent           = "graph.event"
    static let graphEdge            = "graph.edge"
    static let graphEdgeHighlight   = "graph.edge.highlight"
    static let graphEdgeAmbient     = "graph.edge.ambient"
    static let graphHalo            = "graph.halo"
    static let graphCluster         = "graph.cluster"
    static let graphFocus           = "graph.focus"

    // Sidebar selected pill
    static let sidebarSelectedFill  = "sidebar.selected"
    static let sidebarSelectedTint  = "sidebar.selected.tint"
}

struct ThemePalette {
    // Backdrop wash
    let backdropTop: Color
    let backdropBottom: Color
    let backdropAccent: Color

    // Surfaces
    let surface: Color
    let surfaceElevated: Color
    let surfaceSidebar: Color
    let surfaceChrome: Color
    let surfaceHero: Color
    let surfaceField: Color

    // Text
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let textOnAccent: Color

    // Structure
    let border: Color
    let borderSubtle: Color
    let separator: Color
    let hoverFill: Color
    let selectionFill: Color
    let selectionBorder: Color

    // Status
    let success: Color
    let warning: Color
    let error: Color
    let info: Color

    // Graph
    let graphWorkspace: Color
    let graphFile: Color
    let graphSession: Color
    let graphExecution: Color
    let graphMemory: Color
    let graphIntelligence: Color
    let graphEvent: Color
    let graphEdge: Color
    let graphEdgeHighlight: Color
    let graphEdgeAmbient: Color
    let graphHalo: Color
    let graphCluster: Color
    let graphFocus: Color

    // Sidebar
    let sidebarSelectedFill: Color
    let sidebarSelectedTint: Color
}

private let darkPalette = ThemePalette(
    backdropTop:        Color(red: 0.085, green: 0.090, blue: 0.115),
    backdropBottom:     Color(red: 0.055, green: 0.060, blue: 0.085),
    backdropAccent:     Color(red: 0.30, green: 0.45, blue: 0.95),
    surface:            Color(red: 0.110, green: 0.115, blue: 0.140),
    surfaceElevated:    Color(red: 0.135, green: 0.142, blue: 0.170),
    surfaceSidebar:     Color(red: 0.090, green: 0.095, blue: 0.118),
    surfaceChrome:      Color(red: 0.110, green: 0.115, blue: 0.140),
    surfaceHero:        Color(red: 0.130, green: 0.137, blue: 0.165),
    surfaceField:       Color(red: 0.075, green: 0.080, blue: 0.105),
    textPrimary:        Color(red: 0.940, green: 0.948, blue: 0.962),
    textSecondary:      Color(red: 0.690, green: 0.710, blue: 0.745),
    textTertiary:       Color(red: 0.490, green: 0.510, blue: 0.545),
    textOnAccent:       Color.white,
    border:             Color.white.opacity(0.10),
    borderSubtle:       Color.white.opacity(0.06),
    separator:          Color.white.opacity(0.07),
    hoverFill:          Color.white.opacity(0.05),
    selectionFill:      Color.accentColor.opacity(0.18),
    selectionBorder:    Color.accentColor.opacity(0.40),
    success:            Color(red: 0.36, green: 0.82, blue: 0.46),
    warning:            Color(red: 0.95, green: 0.66, blue: 0.30),
    error:              Color(red: 0.95, green: 0.42, blue: 0.42),
    info:               Color(red: 0.40, green: 0.70, blue: 0.95),
    graphWorkspace:     Color(red: 0.55, green: 0.62, blue: 0.95), // indigo
    graphFile:          Color(red: 0.36, green: 0.78, blue: 0.82), // teal
    graphSession:       Color(red: 0.45, green: 0.75, blue: 0.95), // cyan
    graphExecution:     Color(red: 0.95, green: 0.62, blue: 0.32), // orange
    graphMemory:        Color(red: 0.85, green: 0.55, blue: 0.80), // pink
    graphIntelligence:  Color(red: 0.70, green: 0.55, blue: 0.95), // purple
    graphEvent:         Color(red: 0.65, green: 0.85, blue: 0.45), // green
    graphEdge:          Color.white.opacity(0.30),
    graphEdgeHighlight: Color.accentColor,
    graphEdgeAmbient:   Color.white.opacity(0.12),
    graphHalo:          Color.accentColor.opacity(0.20),
    graphCluster:       Color.accentColor.opacity(0.05),
    graphFocus:         Color.accentColor,
    sidebarSelectedFill:   Color.accentColor.opacity(0.18),
    sidebarSelectedTint:   Color.accentColor
)

private let lightPalette = ThemePalette(
    backdropTop:        Color(red: 0.985, green: 0.988, blue: 0.995),
    backdropBottom:     Color(red: 0.945, green: 0.955, blue: 0.975),
    backdropAccent:     Color(red: 0.30, green: 0.45, blue: 0.95),
    surface:            Color(red: 1.000, green: 1.000, blue: 1.000),
    surfaceElevated:    Color(red: 0.998, green: 0.998, blue: 1.000),
    surfaceSidebar:     Color(red: 0.965, green: 0.970, blue: 0.982),
    surfaceChrome:      Color(red: 0.985, green: 0.988, blue: 0.995),
    surfaceHero:        Color(red: 1.000, green: 1.000, blue: 1.000),
    surfaceField:       Color(red: 0.975, green: 0.980, blue: 0.990),
    textPrimary:        Color(red: 0.110, green: 0.115, blue: 0.140),
    textSecondary:      Color(red: 0.380, green: 0.410, blue: 0.470),
    textTertiary:       Color(red: 0.560, green: 0.585, blue: 0.640),
    textOnAccent:       Color.white,
    border:             Color.black.opacity(0.10),
    borderSubtle:       Color.black.opacity(0.05),
    separator:          Color.black.opacity(0.08),
    hoverFill:          Color.black.opacity(0.04),
    selectionFill:      Color.accentColor.opacity(0.14),
    selectionBorder:    Color.accentColor.opacity(0.35),
    success:            Color(red: 0.18, green: 0.62, blue: 0.32),
    warning:            Color(red: 0.82, green: 0.52, blue: 0.10),
    error:              Color(red: 0.82, green: 0.22, blue: 0.22),
    info:               Color(red: 0.20, green: 0.50, blue: 0.85),
    graphWorkspace:     Color(red: 0.40, green: 0.46, blue: 0.85),
    graphFile:          Color(red: 0.18, green: 0.62, blue: 0.68),
    graphSession:       Color(red: 0.22, green: 0.55, blue: 0.80),
    graphExecution:     Color(red: 0.82, green: 0.50, blue: 0.18),
    graphMemory:        Color(red: 0.72, green: 0.36, blue: 0.66),
    graphIntelligence:  Color(red: 0.55, green: 0.40, blue: 0.82),
    graphEvent:         Color(red: 0.40, green: 0.65, blue: 0.22),
    graphEdge:          Color.black.opacity(0.22),
    graphEdgeHighlight: Color.accentColor,
    graphEdgeAmbient:   Color.black.opacity(0.08),
    graphHalo:          Color.accentColor.opacity(0.15),
    graphCluster:       Color.accentColor.opacity(0.04),
    graphFocus:         Color.accentColor,
    sidebarSelectedFill:   Color.accentColor.opacity(0.14),
    sidebarSelectedTint:   Color.accentColor
)

// MARK: - Environment

/// The current palette. Push into the SwiftUI environment from
/// `RootEnvironment` so views can read semantic colors without re-reading
/// `ColorScheme`.
struct CSPalette: EnvironmentKey {
    static let defaultValue: ThemePalette = darkPalette
}

extension EnvironmentValues {
    var csPalette: ThemePalette {
        get { self[CSPalette.self] }
        set { self[CSPalette.self] = newValue }
    }
    /// Resolved appearance mode (system/light/dark → concrete scheme).
    var csAppearanceMode: AppearanceMode {
        get { self[CSAppearanceModeKey.self] }
        set { self[CSAppearanceModeKey.self] = newValue }
    }
}

private struct CSAppearanceModeKey: EnvironmentKey {
    static let defaultValue: AppearanceMode = .system
}

// MARK: - Color resolution

extension Color {
    /// Resolves a semantic color token in the current environment.
    /// Reads from the environment palette, falling back to darkPalette.
    static func cs(_ token: String) -> Color {
        let palette = currentPalette()
        switch token {
        case CSColor.backdropTop:       return palette.backdropTop
        case CSColor.backdropBottom:    return palette.backdropBottom
        case CSColor.backdropAccent:    return palette.backdropAccent
        case CSColor.surface:           return palette.surface
        case CSColor.surfaceElevated:   return palette.surfaceElevated
        case CSColor.surfaceSidebar:    return palette.surfaceSidebar
        case CSColor.surfaceChrome:     return palette.surfaceChrome
        case CSColor.surfaceHero:       return palette.surfaceHero
        case CSColor.surfaceField:      return palette.surfaceField
        case CSColor.textPrimary:       return palette.textPrimary
        case CSColor.textSecondary:     return palette.textSecondary
        case CSColor.textTertiary:      return palette.textTertiary
        case CSColor.textOnAccent:      return palette.textOnAccent
        case CSColor.border:            return palette.border
        case CSColor.borderSubtle:      return palette.borderSubtle
        case CSColor.separator:         return palette.separator
        case CSColor.hoverFill:         return palette.hoverFill
        case CSColor.selectionFill:     return palette.selectionFill
        case CSColor.selectionBorder:   return palette.selectionBorder
        case CSColor.success:           return palette.success
        case CSColor.warning:           return palette.warning
        case CSColor.error:             return palette.error
        case CSColor.info:              return palette.info
        case CSColor.graphWorkspace:    return palette.graphWorkspace
        case CSColor.graphFile:         return palette.graphFile
        case CSColor.graphSession:      return palette.graphSession
        case CSColor.graphExecution:    return palette.graphExecution
        case CSColor.graphMemory:       return palette.graphMemory
        case CSColor.graphIntelligence: return palette.graphIntelligence
        case CSColor.graphEvent:        return palette.graphEvent
        case CSColor.graphEdge:         return palette.graphEdge
        case CSColor.graphEdgeHighlight: return palette.graphEdgeHighlight
        case CSColor.graphEdgeAmbient:  return palette.graphEdgeAmbient
        case CSColor.graphHalo:         return palette.graphHalo
        case CSColor.graphCluster:      return palette.graphCluster
        case CSColor.graphFocus:        return palette.graphFocus
        case CSColor.sidebarSelectedFill: return palette.sidebarSelectedFill
        case CSColor.sidebarSelectedTint: return palette.sidebarSelectedTint
        default: return palette.textPrimary
        }
    }
}

/// Cache the most recent system-resolved color scheme so palette lookups
/// (which can run from a non-@MainActor context inside Canvas closures)
/// always return the right value. Updated on every RootEnvironment render.
@MainActor
private var activeResolvedScheme: ColorScheme = .light

private func currentPalette() -> ThemePalette {
    // Read from the active window's environment by walking the
    // appearance-mode key. We don't have a global singleton — every
    // top-level scene pushes its own environment — so a thread-local
    // cache filled in `RootEnvironment` is the simplest reliable path.
    MainActor.assumeIsolated {
        let mode = activeAppearanceMode
        let scheme: ColorScheme
        switch mode {
        case .system: scheme = activeResolvedScheme
        case .light:  scheme = .light
        case .dark:   scheme = .dark
        }
        return scheme == .dark ? darkPalette : lightPalette
    }
}

/// Thread-safe-ish holder for the current mode. Set from the root scene.
@MainActor
private var activeAppearanceMode: AppearanceMode = .system

@MainActor
final class AppearanceController: ObservableObject {
    static let shared = AppearanceController()
    @Published var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "cs.appearance")
            activeAppearanceMode = mode
        }
    }
    private init() {
        let stored = UserDefaults.standard.string(forKey: "cs.appearance")
        let initial = AppearanceMode(rawValue: stored ?? "system") ?? .system
        self.mode = initial
        activeAppearanceMode = initial
    }
}

// MARK: - Theme tokens

enum Theme {
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
    static let contentMaxWidth: CGFloat = 1280
    static let sidebarWidth: CGFloat = 232
    static let cardPadding: CGFloat = 16
    static let cardPaddingLarge: CGFloat = 20
    static let sectionGap: CGFloat = 22

    // MARK: Control heights
    enum Control {
        static let minHeightRegular: CGFloat = 24
        static let minHeightLarge: CGFloat = 32
        static let minHeightXLarge: CGFloat = 38
        static let fieldHeight: CGFloat = 30
        static let iconButton: CGFloat = 28
    }

    // MARK: Page header height
    static let pageHeaderHeight: CGFloat = 56

    // MARK: Animation
    static func spring(_ reduceMotion: Bool = false,
                       response: Double = 0.4,
                       damping: Double = 0.78) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: response, dampingFraction: damping)
    }
}

// MARK: - Typography

extension Font {
    static let csScreenTitle  = Font.system(size: 24, weight: .semibold, design: .default)
    static let csSectionTitle = Font.system(size: 17, weight: .semibold, design: .default)
    static let csCardTitle    = Font.system(size: 15, weight: .semibold, design: .default)
    static let csBody         = Font.system(size: 13, weight: .regular, design: .default)
    static let csSecondary    = Font.system(size: 13, weight: .regular, design: .default)
    static let csMetadata     = Font.system(size: 11, weight: .regular, design: .default)
    static let csEyebrowFont: Font = .system(size: 11, weight: .semibold, design: .default)
    static func csEyebrow(size: CGFloat = 11) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }
    static func csMetric(size: CGFloat = 28) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }
}

// MARK: - Foreground helpers

/// Reads a semantic text color from the environment palette.
/// This ensures the same token resolves to a light foreground in Dark
/// and a dark foreground in Light, and updates immediately when the
/// appearance changes (unlike the global Color.cs cache).
struct CSText: ViewModifier {
    let token: String
    @Environment(\.csPalette) var palette
    func body(content: Content) -> some View {
        content.foregroundStyle(palette.color(for: token))
    }
}

extension View {
    /// Applies a semantic text color.
    func csForeground(_ token: String) -> some View {
        modifier(CSText(token: token))
    }
}

// MARK: - ThemePalette token resolution

extension ThemePalette {
    func color(for token: String) -> Color {
        switch token {
        case CSColor.backdropTop:        return backdropTop
        case CSColor.backdropBottom:     return backdropBottom
        case CSColor.backdropAccent:     return backdropAccent
        case CSColor.surface:            return surface
        case CSColor.surfaceElevated:    return surfaceElevated
        case CSColor.surfaceSidebar:     return surfaceSidebar
        case CSColor.surfaceChrome:      return surfaceChrome
        case CSColor.surfaceHero:        return surfaceHero
        case CSColor.surfaceField:       return surfaceField
        case CSColor.textPrimary:        return textPrimary
        case CSColor.textSecondary:      return textSecondary
        case CSColor.textTertiary:       return textTertiary
        case CSColor.textOnAccent:       return textOnAccent
        case CSColor.border:             return border
        case CSColor.borderSubtle:       return borderSubtle
        case CSColor.separator:          return separator
        case CSColor.hoverFill:          return hoverFill
        case CSColor.selectionFill:      return selectionFill
        case CSColor.selectionBorder:    return selectionBorder
        case CSColor.success:            return success
        case CSColor.warning:            return warning
        case CSColor.error:              return error
        case CSColor.info:               return info
        case CSColor.graphWorkspace:     return graphWorkspace
        case CSColor.graphFile:          return graphFile
        case CSColor.graphSession:       return graphSession
        case CSColor.graphExecution:     return graphExecution
        case CSColor.graphMemory:        return graphMemory
        case CSColor.graphIntelligence:  return graphIntelligence
        case CSColor.graphEvent:         return graphEvent
        case CSColor.graphEdge:          return graphEdge
        case CSColor.graphEdgeHighlight: return graphEdgeHighlight
        case CSColor.graphEdgeAmbient:   return graphEdgeAmbient
        case CSColor.graphHalo:          return graphHalo
        case CSColor.graphCluster:       return graphCluster
        case CSColor.graphFocus:         return graphFocus
        case CSColor.sidebarSelectedFill: return sidebarSelectedFill
        case CSColor.sidebarSelectedTint: return sidebarSelectedTint
        default: return textPrimary
        }
    }
}

// MARK: - Root environment

/// Root view that injects the appearance/palette into the environment
/// and reacts to the user's theme choice.
struct RootEnvironment<Content: View>: View {
    @ObservedObject private var appearance = AppearanceController.shared
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: Content

    var body: some View {
        let resolved = appearance.mode.resolved(scheme: colorScheme)
        let palette = resolved == .dark ? darkPalette : lightPalette
        activeResolvedScheme = resolved
        return content
            .environment(\.csPalette, palette)
            .environment(\.csAppearanceMode, appearance.mode)
            .preferredColorScheme(appearance.mode == .system ? nil :
                                  (appearance.mode == .dark ? .dark : .light))
    }
}

// MARK: - Backdrop

struct ContentBackdrop: View {
    @Environment(\.csPalette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceTransparency || reduceMotion {
            Color.cs(CSColor.surface)
        } else {
            ZStack {
                LinearGradient(
                    colors: [palette.backdropTop, palette.backdropBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .overlay {
                    RadialGradient(
                        colors: [palette.backdropAccent.opacity(0.06), .clear],
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

struct ContentCard<Content: View>: View {
    var cornerRadius: CGFloat = Theme.cornerLarge
    var padding: CGFloat = Theme.cardPaddingLarge
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(
                Color.cs(CSColor.surface).opacity(0.88),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.04), radius: 10, y: 3)
    }
}

struct CompactCard<Content: View>: View {
    var cornerRadius: CGFloat = Theme.cornerRegular
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Theme.cardPadding)
            .background(
                Color.cs(CSColor.surface).opacity(0.88),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.03), radius: 8, y: 2)
    }
}

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

// MARK: - Liquid Glass Chrome (Apple, WWDC 2018 / Liquid Glass)

// Intentional, restrained glass. Navigation / chrome / floating
// controls are glass; content stays calm. Every surface respects
// Reduce Transparency / Reduce Motion and remains readable
// without blur.

struct LGChromeBackground: ViewModifier {
    var cornerRadius: CGFloat = Theme.cornerRegular
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content.background(
                    Color.cs(CSColor.surfaceChrome),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            } else {
                content.glassEffect(
                    interactive ? Glass.regular.interactive() : Glass.regular,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(reduceTransparency ? 0.04 : 0.07), radius: 12, y: 4)
    }
}

struct LGInspectorBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content.background(
                    Color.cs(CSColor.surfaceChrome),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
            } else {
                content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.14), radius: 24, y: 8)
    }
}

struct LGSidebarBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.csPalette) private var palette
    func body(content: Content) -> some View {
        content.background {
            if reduceTransparency {
                palette.surfaceSidebar
            } else {
                ZStack {
                    palette.surfaceSidebar.opacity(0.72)
                    Rectangle().fill(.ultraThinMaterial).opacity(0.92)
                }
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.cs(CSColor.separator).opacity(reduceTransparency ? 0.5 : 0.32))
                .frame(width: 0.5)
        }
    }
}

extension View {
    func lgChrome(cornerRadius: CGFloat = Theme.cornerRegular, interactive: Bool = false) -> some View {
        modifier(LGChromeBackground(cornerRadius: cornerRadius, interactive: interactive))
    }
    func lgInspector() -> some View { modifier(LGInspectorBackground()) }
    func lgSidebarBackground() -> some View { modifier(LGSidebarBackground()) }
}

// MARK: - Divider

struct Hairline: View {
    var opacity: Double = 1.0
    var body: some View {
        Rectangle()
            .fill(Color.cs(CSColor.separator).opacity(opacity))
            .frame(height: 0.5)
    }
}

// MARK: - Headers

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
                        .csForeground(CSColor.textTertiary)
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 10) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 20, weight: .semibold))
                            .csForeground(CSColor.info)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(.csScreenTitle)
                        .csForeground(CSColor.textPrimary)
                        .tracking(-0.3)
                        .accessibilityLabel(title)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .csForeground(CSColor.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var systemImageColor: Color? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .csForeground(CSColor.textSecondary)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.csEyebrow())
                .csForeground(CSColor.textSecondary)
                .textCase(.uppercase)
                .tracking(0.6)
            if let subtitle {
                Text("·")
                    .csForeground(CSColor.textTertiary)
                Text(subtitle)
                    .font(.caption)
                    .csForeground(CSColor.textTertiary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Page chrome

/// Single breadcrumb row that lives inside the content/header container and
/// aligns to the content grid. Never floats detached in the toolbar.
struct ContentBreadcrumb: View {
    let section: AppSection
    var activeWorkspace: Workspace? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text("ContextSphere")
                .font(.system(size: 11, weight: .medium))
                .csForeground(CSColor.textTertiary)
                .accessibilityHidden(true)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .csForeground(CSColor.textTertiary)
                .opacity(0.55)
                .accessibilityHidden(true)
            if let ws = activeWorkspace {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.cs(CSColor.textTertiary).opacity(0.85))
                        .accessibilityHidden(true)
                    Text(ws.name)
                        .font(.system(size: 11.5, weight: .regular))
                        .csForeground(CSColor.textSecondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .csForeground(CSColor.textTertiary)
                    .opacity(0.55)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 5) {
                Image(systemName: section.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.cs(CSColor.textSecondary))
                    .accessibilityHidden(true)
                Text(section.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .tracking(-0.1)
                    .csForeground(CSColor.textPrimary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(breadcrumbLabel)
    }

    private var breadcrumbLabel: String {
        if let ws = activeWorkspace { return "ContextSphere, \(ws.name), \(section.title)" }
        return "ContextSphere, \(section.title)"
    }
}

/// Consistent header chrome used by every page. Eyebrow → icon/title → subtitle
/// hierarchy, spacing 4/10/16, left-aligned to the content grid inside a soft
/// glass container. All pages should use this rather than ad-hoc HStacks.
struct StandardPageHeader<Content: View>: View {
    let section: AppSection
    var activeWorkspace: Workspace? = nil
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var eyebrow: String? = nil
    @ViewBuilder var trailing: Content

    init(section: AppSection,
         activeWorkspace: Workspace? = nil,
         title: String,
         subtitle: String? = nil,
         symbol: String? = nil,
         eyebrow: String? = nil,
         @ViewBuilder trailing: () -> Content) {
        self.section = section
        self.activeWorkspace = activeWorkspace
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.eyebrow = eyebrow
        self.trailing = trailing()
    }

    init(section: AppSection,
         activeWorkspace: Workspace? = nil,
         title: String,
         subtitle: String? = nil,
         symbol: String? = nil,
         eyebrow: String? = nil) where Content == EmptyView {
        self.init(section: section, activeWorkspace: activeWorkspace, title: title, subtitle: subtitle, symbol: symbol, eyebrow: eyebrow) { EmptyView() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ContentBreadcrumb(section: section, activeWorkspace: activeWorkspace)
            ScreenHeader(title, subtitle: subtitle, symbol: symbol, eyebrow: eyebrow) { trailing }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shared scaffold: ScrollView + content grid + safeAreaInset glass header.
/// Breadcrumb inside `header` is aligned to the same maxWidth grid as `content`.
struct PageScaffold<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: Theme.contentMaxWidth)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .safeAreaInset(edge: .top, spacing: 8) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: Theme.contentMaxWidth)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - States

struct EmptyStateView: View {
    let title: String
    var message: String?
    var symbol: String = "sparkles"
    var primaryAction: (label: String, perform: () -> Void)?
    var secondaryAction: (label: String, perform: () -> Void)?
    var details: [(String, String)]? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .light))
                .csForeground(CSColor.textTertiary)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .csForeground(CSColor.textPrimary)
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(.callout)
                        .csForeground(CSColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }
            if let details, !details.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                        Label(detail.1, systemImage: detail.0)
                            .font(.caption)
                            .csForeground(CSColor.textSecondary)
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

struct LoadingView: View {
    var label = "Loading…"

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.caption)
                .csForeground(CSColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

struct InlineLoading: View {
    var label = "Loading…"
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label)
                .font(.caption)
                .csForeground(CSColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Badges

struct CSStatusBadge: View {
    enum Kind {
        case success, warning, error, info, neutral
        var token: String {
            switch self {
            case .success: CSColor.success
            case .warning: CSColor.warning
            case .error:   CSColor.error
            case .info:    CSColor.info
            case .neutral: CSColor.textSecondary
            }
        }
        var symbol: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error:   "xmark.circle.fill"
            case .info:    "info.circle.fill"
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
        .csForeground(kind.token)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Color.cs(kind.token).opacity(0.14), in: Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

struct MetaChip: View {
    let text: String
    var systemImage: String? = nil
    var tint: String = CSColor.textSecondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.caption2)
        }
        .csForeground(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.cs(CSColor.textTertiary).opacity(0.10), in: Capsule(style: .continuous))
    }
}

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
                        .csForeground(CSColor.textSecondary)
                        .accessibilityHidden(true)
                }
                Text(label)
                    .font(.csEyebrow())
                    .csForeground(CSColor.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
            Text(value)
                .font(.csMetric(size: 24))
                .csForeground(CSColor.textPrimary)
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
                .csForeground(trend.isPositive ? CSColor.success : CSColor.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cs(CSColor.surfaceElevated), in: RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous)
                .strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}

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
        .foregroundStyle(isActive ? Color.accentColor : Color.cs(CSColor.textSecondary))
    }
}

struct HeroCard<Content: View>: View {
    var cornerRadius: CGFloat = Theme.cornerXLarge
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Theme.cardPaddingLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.cs(CSColor.surfaceHero).opacity(0.94),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.06), radius: 16, y: 6)
    }
}

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
                isSelected
                    ? Color.cs(CSColor.selectionFill)
                    : Color.clear,
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? Color.cs(CSColor.selectionBorder)
                            : Color.cs(CSColor.border),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .csForeground(isSelected ? CSColor.sidebarSelectedTint : CSColor.textPrimary)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Banner

struct StatusBanner: View {
    enum Style {
        case warning, error, info
        var token: String {
            switch self {
            case .warning: CSColor.warning
            case .error:   CSColor.error
            case .info:    CSColor.info
            }
        }
        var symbol: String {
            switch self {
            case .warning: "exclamationmark.triangle"
            case .error:   "xmark.octagon"
            case .info:    "info.circle"
            }
        }
    }

    let message: String
    var style: Style = .info
    var detail: String? = nil
    var primaryAction: (label: String, perform: () -> Void)? = nil
    var secondaryAction: (label: String, perform: () -> Void)? = nil

    var body: some View {
        let token = style.token
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: style.symbol)
                .font(.system(size: 14, weight: .semibold))
                .csForeground(token)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.callout.weight(.medium))
                    .csForeground(CSColor.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .csForeground(CSColor.textSecondary)
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
                .fill(Color.cs(token).opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous)
                .strokeBorder(Color.cs(token).opacity(0.35), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Hover / Selection

struct HoverRowModifier: ViewModifier {
    let isHovered: Bool
    let isSelected: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isSelected
                          ? Color.cs(CSColor.selectionFill)
                          : (isHovered ? Color.cs(CSColor.hoverFill) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? Color.cs(CSColor.selectionBorder) : .clear,
                                  lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func hoverRow(isHovered: Bool, isSelected: Bool, cornerRadius: CGFloat = Theme.cornerRegular) -> some View {
        modifier(HoverRowModifier(isHovered: isHovered, isSelected: isSelected, cornerRadius: cornerRadius))
    }
}

// MARK: - Legacy alias

extension Theme {
    static func card<Content: View>(_ content: Content, cornerRadius: CGFloat = 14) -> some View {
        content
            .padding(16)
            .background(Color.cs(CSColor.surface), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.cs(CSColor.border), lineWidth: 0.5)
            }
    }
}
