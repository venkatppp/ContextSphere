import SwiftUI
import AppKit

// MARK: - Navigation model

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard, workspaces, timeline
    case graph, search, memory, learning
    case performance, maintenance, recovery, settings

    var id: String { rawValue }

    var group: NavGroup {
        switch self {
        case .dashboard, .workspaces, .timeline: .workspace
        case .graph, .search, .memory, .learning: .intelligence
        case .performance, .maintenance, .recovery, .settings: .system
        }
    }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .workspaces: "Workspaces"
        case .timeline: "Timeline"
        case .graph: "Knowledge Graph"
        case .search: "Search"
        case .memory: "Memory"
        case .learning: "Learning"
        case .performance: "Performance"
        case .maintenance: "Maintenance"
        case .recovery: "Recovery"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "rectangle.grid.2x2"
        case .workspaces: "folder"
        case .timeline: "clock"
        case .graph: "point.3.connected.trianglepath.dotted"
        case .search: "magnifyingglass"
        case .memory: "brain.head.profile"
        case .learning: "graduationcap"
        case .performance: "gauge.with.dots.needle.67percent"
        case .maintenance: "wrench.and.screwdriver"
        case .recovery: "heart.text.square"
        case .settings: "gearshape"
        }
    }

    var shortcutKey: KeyEquivalent? {
        switch self {
        case .dashboard: "1"
        case .workspaces: "2"
        case .timeline: "3"
        case .graph: "4"
        case .search: "5"
        case .memory: "6"
        case .learning: "7"
        case .performance, .maintenance, .recovery, .settings: nil
        }
    }

    /// Compact label used in the sidebar.
    var compactTitle: String {
        switch self {
        case .graph: "Graph"
        default: title
        }
    }
}

enum NavGroup: String, CaseIterable, Identifiable, Hashable {
    case workspace, intelligence, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspace: "Workspace"
        case .intelligence: "Intelligence"
        case .system: "System"
        }
    }

    var symbol: String {
        switch self {
        case .workspace: "square.stack.3d.up"
        case .intelligence: "sparkles"
        case .system: "gearshape.2"
        }
    }

    var sections: [AppSection] {
        switch self {
        case .workspace: [.dashboard, .workspaces, .timeline]
        case .intelligence: [.graph, .search, .memory, .learning]
        case .system: [.performance, .maintenance, .recovery, .settings]
        }
    }
}

// MARK: - App router

/// Shared navigation and command state. The app menu, the command palette
/// and the sidebar all drive the same selection so keyboard commands and
/// mouse clicks stay in sync.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    @Published var selection: AppSection? = .dashboard
    @Published var showCommandPalette = false
    @Published var newWorkspaceRequest = false
    @Published var revealWorkspaceRequest: String?
    @Published var reloadRequest = false

    private init() {}
}

extension Notification.Name {
    static let workspacesDidChange = Notification.Name("workspacesDidChange")
    static let intelligenceDidChange = Notification.Name("intelligenceDidChange")
    static let workspaceHealthDidChange = Notification.Name("workspaceHealthDidChange")
}

// MARK: - App shell

struct AppShell: View {
    @StateObject private var router = AppRouter.shared
    @ObservedObject private var bridge = CoreBridge.shared
    @Environment(\.csPalette) private var palette
    @State private var workspaces: [Workspace] = []
    @State private var loaded = false
    @State private var loadFailed: String?
    @StateObject private var timeline = TimelineViewModel()
    @StateObject private var search = SearchViewModel()
    @StateObject private var graph = GraphViewModel()
    @StateObject private var memory = MemoryViewModel()
    @StateObject private var learning = LearningViewModel()
    @StateObject private var performance = PerformanceViewModel()
    @StateObject private var maintenance = MaintenanceViewModel()
    @StateObject private var recovery = RecoveryViewModel()
    @StateObject private var proactiveNotifier = ProactiveNotifier()
    @State private var workspaceReloadTask: Task<Void, Never>?
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 232, max: 280)
        } detail: {
            DetailHost(section: router.selection ?? .dashboard,
                       workspaces: workspaces,
                       loaded: loaded,
                       loadFailed: loadFailed,
                       timeline: timeline,
                       search: search,
                       graph: graph,
                       memory: memory,
                       learning: learning,
                       performance: performance,
                       maintenance: maintenance,
                       recovery: recovery,
                       onRevealWorkspace: revealWorkspace)
                .background(ContentBackdrop())
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar { toolbarContent }
        .sheet(isPresented: $router.showCommandPalette) {
            CommandPaletteView()
                .environmentObject(router)
        }
        .task { await registerEventSink() }
        .onChange(of: bridge.isRunning) { _, running in
            guard running, loaded else { return }
            NotificationCenter.default.post(name: .workspacesDidChange, object: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .workspacesDidChange)) { _ in
            workspaceReloadTask?.cancel()
            workspaceReloadTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await loadWorkspaces()
            }
        }
        .onChange(of: router.reloadRequest) { _, requested in
            guard requested else { return }
            router.reloadRequest = false
            Task { await loadWorkspaces() }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            SidebarHeader(activeWorkspace: activeWorkspace,
                          workspaces: workspaces,
                          onShowAll: {
                              router.selection = .workspaces
                          },
                          onSwitch: { workspace in
                              router.selection = .workspaces
                              router.revealWorkspaceRequest = workspace.id
                          })
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 10)
            Divider()
                .opacity(0.4)
                .padding(.bottom, 4)
            List(selection: $router.selection) {
                ForEach(NavGroup.allCases) { group in
                    Section {
                        ForEach(group.sections) { section in
                            SidebarRow(section: section)
                                .tag(section)
                                .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        SidebarGroupHeader(group: group)
                            .textCase(nil)
                    }
                    .listSectionSeparator(.hidden)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 0)
        }
        .background(palette.surfaceSidebar)
    }

    private func revealWorkspace(_ id: String) {
        router.selection = .workspaces
        router.revealWorkspaceRequest = id
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ToolbarBreadcrumb(section: router.selection ?? .dashboard,
                              activeWorkspace: activeWorkspace)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                router.showCommandPalette = true
            } label: {
                Label("Command Palette", systemImage: "command")
            }
            .help("Open the command palette (⌘K)")
            .accessibilityLabel("Open command palette")
        }
    }

    // MARK: - Data

    private var activeWorkspace: Workspace? {
        workspaces.first { $0.status == .active } ?? workspaces.first
    }

    @MainActor
    private func registerEventSink() async {
        CoreBridge.shared.onEvent = { event, payload in
            timeline.handle(event: event, payload: payload)
            search.handle(event: event, payload: payload)
            graph.handle(event: event, payload: payload)
            if event.hasPrefix("workspace:") {
                Task { @MainActor in
                    NotificationCenter.default.post(name: .workspacesDidChange, object: nil)
                }
            }
            if event == "prediction:updated" || event == "recommendation:updated"
                || event == "workflow:changed" {
                Task { @MainActor in
                    NotificationCenter.default.post(name: .intelligenceDidChange, object: nil)
                }
            }
            if event == "health:updated", let payload,
               let obj = try? JSONDecoder().decode([String: JSONValue].self, from: payload) {
                let workspaceId = obj.string("workspaceId") ?? ""
                let score = (obj["healthScore"] ?? .number(-1)).jsonObject as? Double ?? -1
                Task { @MainActor in
                    NotificationCenter.default.post(
                        name: .workspaceHealthDidChange, object: nil,
                        userInfo: ["workspaceId": workspaceId, "healthScore": score])
                }
            }
            if event == "proactive:notification" {
                let data = payload
                Task { @MainActor in await proactiveNotifier.deliver(data) }
            }
        }
        CoreBridge.shared.start()
        await loadWorkspaces()
    }

    private func loadWorkspaces() async {
        do {
            async let active: [Workspace] = CoreBridge.shared.request(
                "list_active_workspaces", as: [Workspace].self)
            async let archived: [Workspace] = CoreBridge.shared.request(
                "list_archived_workspaces", as: [Workspace].self)
            let (a, b) = try await (active, archived)
            workspaces = (a + b).sorted { $0.lastActiveAt > $1.lastActiveAt }
            timeline.setWorkspaces(workspaces)
            search.setWorkspaces(workspaces)
            graph.setWorkspaces(workspaces)
            memory.setWorkspaces(workspaces)
            loaded = true
        } catch {
            loadFailed = error.localizedDescription
        }
    }
}

// MARK: - Sidebar row

private struct SidebarRow: View {
    let section: AppSection
    @Environment(\.csPalette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: section.symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 18, alignment: .center)
                .csForeground(CSColor.textSecondary)
            Text(section.compactTitle)
                .font(.system(size: 13, weight: .regular))
                .csForeground(CSColor.textPrimary)
            Spacer(minLength: 4)
            if let key = section.shortcutKey {
                Text("⌘\(String(key.character))")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .csForeground(CSColor.textTertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(palette.textTertiary.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .accessibilityLabel(section.title)
        .accessibilityHint(shortcutHint)
    }

    private var shortcutHint: Text {
        if let key = section.shortcutKey {
            return Text("Shortcut ⌘\(String(key.character))")
        }
        return Text("")
    }
}

private struct SidebarGroupHeader: View {
    let group: NavGroup

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: group.symbol)
                .font(.system(size: 10, weight: .semibold))
                .csForeground(CSColor.textTertiary)
            Text(group.title.uppercased())
                .font(.csEyebrow(size: 10))
                .tracking(0.7)
                .csForeground(CSColor.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Sidebar header

/// Refined workspace switcher: clean folder icon, workspace name and a
/// subtle chevron — no crosshair, no heavy box. The compact affordance
/// keeps the navigation rail the visual priority.
private struct SidebarHeader: View {
    let activeWorkspace: Workspace?
    let workspaces: [Workspace]
    let onShowAll: () -> Void
    let onSwitch: (Workspace) -> Void
    @Environment(\.csPalette) private var palette

    private var headerSubtitle: String {
        if activeWorkspace?.rootPath?.isEmpty == false {
            return "Active context"
        }
        if workspaces.isEmpty {
            return "Create one to begin"
        }
        return "Pick a context"
    }

    var body: some View {
        Menu {
            if !workspaces.isEmpty {
                ForEach(workspaces.prefix(8)) { workspace in
                    Button {
                        onSwitch(workspace)
                    } label: {
                        Label(workspace.name,
                              systemImage: workspace.status == .active
                                ? "checkmark.circle.fill"
                                : "folder")
                    }
                }
                Divider()
                Button("All Workspaces…", action: onShowAll)
            } else {
                Button("Create your first workspace", action: onShowAll)
            }
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(activeWorkspace?.name ?? "No workspace")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .csForeground(CSColor.textPrimary)
                    Text(headerSubtitle)
                        .font(.system(size: 10))
                        .csForeground(CSColor.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .csForeground(CSColor.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous)
                    .fill(palette.hoverFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(activeWorkspace.map { "Active workspace: \($0.name)" } ?? "No workspace selected")
        .accessibilityHint("Open workspace switcher")
    }
}

// MARK: - Toolbar breadcrumb

/// Top-bar breadcrumb. Sits in the toolbar's principal slot and is fully
/// styled in the chrome. Workspace is a quiet, secondary piece of
/// metadata; the active page is the primary identity.
private struct ToolbarBreadcrumb: View {
    let section: AppSection
    let activeWorkspace: Workspace?
    @Environment(\.csPalette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            if let activeWorkspace {
                Text(activeWorkspace.name)
                    .font(.system(size: 12, weight: .regular))
                    .csForeground(CSColor.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .csForeground(CSColor.textTertiary)
            }
            Text(section.title)
                .font(.system(size: 13, weight: .semibold))
                .csForeground(CSColor.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            palette.surfaceChrome.opacity(0.6),
            in: Capsule(style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail host

struct DetailHost: View {
    let section: AppSection
    let workspaces: [Workspace]
    let loaded: Bool
    let loadFailed: String?
    let timeline: TimelineViewModel
    let search: SearchViewModel
    let graph: GraphViewModel
    let memory: MemoryViewModel
    let learning: LearningViewModel
    let performance: PerformanceViewModel
    let maintenance: MaintenanceViewModel
    let recovery: RecoveryViewModel
    let onRevealWorkspace: (String) -> Void

    var body: some View {
        Group {
            if !loaded {
                if let loadFailed {
                    EmptyStateView(
                        title: "Could not connect",
                        message: loadFailed,
                        symbol: "exclamationmark.triangle"
                    )
                } else {
                    LoadingView(label: "Connecting to ContextSphere core…")
                }
            } else {
                content
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .dashboard: DashboardView(workspaces: workspaces, onRevealWorkspace: onRevealWorkspace)
        case .workspaces: WorkspacesView(workspaces: workspaces, onWorkspacesChanged: { AppRouter.shared.reloadRequest = true })
        case .timeline: TimelineView(viewModel: timeline)
        case .graph: GraphScreen(viewModel: graph)
        case .search: SearchView(viewModel: search, onRevealWorkspace: onRevealWorkspace)
        case .memory: MemoryView(viewModel: memory)
        case .learning: LearningView(viewModel: learning)
        case .performance: PerformanceView(viewModel: performance)
        case .maintenance: MaintenanceView(viewModel: maintenance)
        case .recovery: RecoveryView(viewModel: recovery)
        case .settings: SettingsView()
        }
    }
}

// MARK: - Command palette

/// Spotlight-style command palette (⌘K). Lists every navigation section
/// plus quick actions. Presents as a native sheet, keyboard-first.
struct CommandPaletteView: View {
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var fieldFocused: Bool
    @State private var query = ""
    @State private var selection: Selection?

    private enum Selection: Identifiable, Hashable {
        case section(AppSection)
        case action(Action)

        var id: String {
            switch self {
            case .section(let section): "section:\(section.rawValue)"
            case .action(let action): "action:\(action.id)"
            }
        }
    }

    private enum Action: String, CaseIterable, Identifiable {
        case newWorkspace, refresh

        var id: String { rawValue }

        var title: String {
            switch self {
            case .newWorkspace: "New Workspace…"
            case .refresh: "Refresh Core"
            }
        }

        var symbol: String {
            switch self {
            case .newWorkspace: "folder.badge.plus"
            case .refresh: "arrow.clockwise"
            }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            searchField
            results
        }
        .padding(16)
        .frame(width: 540, height: 460)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, _ in
            if !filtered.contains(where: { $0.id == selection?.id }) {
                selection = filtered.first
            }
        }
        .background {
            Button("") { handleEscape() }
                .keyboardShortcut(.escape)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .csForeground(CSColor.textSecondary)
                .accessibilityHidden(true)
            TextField("Jump to anything…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($fieldFocused)
                .accessibilityLabel("Command palette")
            if !query.isEmpty {
                Button {
                    query = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .csForeground(CSColor.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear command palette")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
    }

    private var filtered: [Selection] {
        let sections: [Selection] = AppSection.allCases.map(Selection.section)
        let actions: [Selection] = Action.allCases.map(Selection.action)
        let all = sections + actions
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { item in
            switch item {
            case .section(let section):
                return section.title.localizedCaseInsensitiveContains(trimmed)
                    || section.group.title.localizedCaseInsensitiveContains(trimmed)
            case .action(let action):
                return action.title.localizedCaseInsensitiveContains(trimmed)
            }
        }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(filtered) { item in
                    Button {
                        activate(item)
                    } label: {
                        row(for: item)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityText(for: item))
                }
            }
            .padding(4)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
    }

    private func row(for item: Selection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(for: item))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected(item) ? Color.accentColor : Color.cs(CSColor.textSecondary))
                .frame(width: 20)
            Text(title(for: item))
                .font(.system(size: 13))
                .csForeground(CSColor.textPrimary)
            Spacer()
            if case .section(let section) = item, let shortcut = section.shortcutKey {
                Text("⌘\(String(shortcut.character))")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .csForeground(CSColor.textTertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.cs(CSColor.textTertiary).opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                .fill(selected(item) ? Color.cs(CSColor.selectionFill) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func selected(_ item: Selection) -> Bool {
        selection?.id == item.id
    }

    private func symbol(for item: Selection) -> String {
        switch item {
        case .section(let section): section.symbol
        case .action(let action): action.symbol
        }
    }

    private func title(for item: Selection) -> String {
        switch item {
        case .section(let section): section.title
        case .action(let action): action.title
        }
    }

    private func accessibilityText(for item: Selection) -> String {
        switch item {
        case .section(let section): "\(section.title), \(section.group.title) section"
        case .action(let action): action.title
        }
    }

    private func activate(_ item: Selection) {
        switch item {
        case .section(let section):
            router.selection = section
            dismiss()
        case .action(let action):
            switch action {
            case .newWorkspace:
                router.selection = .workspaces
                router.newWorkspaceRequest = true
                dismiss()
            case .refresh:
                CoreBridge.shared.reconnect()
                dismiss()
            }
        }
    }

    private func handleEscape() {
        if !query.isEmpty {
            query = ""
            fieldFocused = true
        } else {
            dismiss()
        }
    }
}
