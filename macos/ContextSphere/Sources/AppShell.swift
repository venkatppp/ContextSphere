import SwiftUI

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
    /// Intelligence panels should refresh (payload: none). Emitted on
    /// `prediction:updated` / `recommendation:updated`.
    static let intelligenceDidChange = Notification.Name("intelligenceDidChange")
    /// Workspace health changed (userInfo: workspaceId, healthScore).
    static let workspaceHealthDidChange = Notification.Name("workspaceHealthDidChange")
}

// MARK: - App shell

struct AppShell: View {
    @StateObject private var router = AppRouter.shared
    /// Observed so the sidebar footer and reconnect handling react to
    /// daemon lifecycle changes.
    @ObservedObject private var bridge = CoreBridge.shared
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

    var body: some View {
        NavigationSplitView {
            sidebar
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
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                workspaceContextMenu
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
        .sheet(isPresented: $router.showCommandPalette) {
            CommandPaletteView()
                .environmentObject(router)
        }
        .task {
            // Register the event sink before the daemon can emit anything.
            CoreBridge.shared.onEvent = { event, payload in
                // Existing timeline/search live updates + graph live updates
                timeline.handle(event: event, payload: payload)
                search.handle(event: event, payload: payload)
                graph.handle(event: event, payload: payload)
                // Workspace live events — debounced reload to avoid storms
                if event.hasPrefix("workspace:") {
                    Task { @MainActor in
                        NotificationCenter.default.post(name: .workspacesDidChange, object: nil)
                    }
                }
                // Intelligence refresh nudges (debounced on the receiver).
                if event == "prediction:updated" || event == "recommendation:updated"
                    || event == "workflow:changed" {
                    Task { @MainActor in
                        NotificationCenter.default.post(name: .intelligenceDidChange, object: nil)
                    }
                }
                // Live workspace health updates carry the fresh score.
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
                // Proactive engine output → native macOS notifications.
                if event == "proactive:notification" {
                    let data = payload
                    Task { @MainActor in await proactiveNotifier.deliver(data) }
                }
            }
            CoreBridge.shared.start()
            await loadWorkspaces()
        }
        // After an automatic daemon restart, refresh global state; screens
        // reload on demand via their own tasks/refresh actions.
        .onChange(of: bridge.isRunning) { _, running in
            guard running, loaded else { return }
            NotificationCenter.default.post(name: .workspacesDidChange, object: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .workspacesDidChange)) { _ in
            workspaceReloadTask?.cancel()
            workspaceReloadTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s debounce
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

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $router.selection) {
            ForEach(NavGroup.allCases) { group in
                Section(group.title) {
                    ForEach(group.sections) { section in
                        Label(section.title, systemImage: section.symbol)
                            .tag(section)
                            .accessibilityLabel(section.title)
                    }
                }
                .listSectionSeparator(.automatic)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            CoreStatusFooter(isRunning: bridge.isRunning,
                             isReconnecting: bridge.isReconnecting,
                             version: bridge.backendVersion) {
                bridge.reconnect()
            }
        }
    }

    /// Reveals a workspace in the Workspaces master list without switching
    /// the daemon's active workspace.
    private func revealWorkspace(_ id: String) {
        router.selection = .workspaces
        router.revealWorkspaceRequest = id
    }

    // MARK: Toolbar

    @ViewBuilder
    private var workspaceContextMenu: some View {
        if let workspace = activeWorkspace {
            Menu {
                ForEach(workspaces) { workspace in
                    Button(workspace.name) {
                        router.selection = .workspaces
                        router.revealWorkspaceRequest = workspace.id
                    }
                }
                Divider()
                Button("All Workspaces…") {
                    router.selection = .workspaces
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.tint)
                    Text(workspace.name)
                        .font(.callout.weight(.medium))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Workspace: \(workspace.name). Choose another workspace")
        }
    }

    private var activeWorkspace: Workspace? {
        workspaces.first { $0.status == .active } ?? workspaces.first
    }

    private func loadWorkspaces() async {
        do {
            async let active: [Workspace] = CoreBridge.shared.request(
                "list_active_workspaces", as: [Workspace].self)
            async let archived: [Workspace] = CoreBridge.shared.request(
                "list_archived_workspaces", as: [Workspace].self)
            let (a, b) = try await (active, archived)
            workspaces = (a + b).sorted { $0.lastActiveAt > $1.lastActiveAt }
            // Propagate to view models that cache workspace names
            timeline.setWorkspaces(workspaces)
            search.setWorkspaces(workspaces)
            graph.setWorkspaces(workspaces)
            memory.setWorkspaces(workspaces)
            loaded = true
        } catch {
            loadFailed = error.localizedDescription
        }
    }

    func reloadWorkspaces() {
        Task { await loadWorkspaces() }
    }
}

struct CoreStatusFooter: View {
    let isRunning: Bool
    var isReconnecting: Bool = false
    let version: String?
    /// Manual recovery affordance, shown while offline.
    var onReconnect: (() -> Void)? = nil

    private var statusColor: Color {
        isRunning ? .green : (isReconnecting ? .orange : .red)
    }

    private var statusText: String {
        if isRunning { return "Core online" }
        return isReconnecting ? "Core reconnecting…" : "Core offline"
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let version {
                Text("· \(version)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if !isRunning, let onReconnect {
                Button("Retry", action: onReconnect)
                    .buttonStyle(.link)
                    .font(.caption2)
                    .help("Restart the core daemon")
                    .accessibilityLabel("Retry core connection")
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isRunning
                            ? "ContextSphere core online\(version.map { ", version \($0)" } ?? "")"
                            : "ContextSphere core offline\(isReconnecting ? ", reconnecting" : "")")
    }
}

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
                    EmptyStateView(title: "Could not connect",
                                   message: loadFailed,
                                   symbol: "exclamationmark.triangle")
                } else {
                    LoadingView()
                }
            } else {
                content
            }
        }
        .frame(minWidth: 680, minHeight: 520)
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
        VStack(spacing: 14) {
            searchField
            results
        }
        .padding(16)
        .frame(width: 480, height: 420)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { newQuery, _ in
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
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Commands, sections, actions…", text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .accessibilityLabel("Command palette")
            if !query.isEmpty {
                Button {
                    query = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear command palette")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            LazyVStack(alignment: .leading, spacing: 2) {
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
                .foregroundStyle(selected(item) ? Color.accentColor : .secondary)
                .frame(width: 20)
            Text(title(for: item))
                .font(.callout)
            Spacer()
            if case .section(let section) = item, let shortcut = section.shortcutKey {
                Text("⌘\(String(shortcut.character))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected(item) ? Color.accentColor.opacity(0.14) : Color.clear)
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
                // Real recovery: restarts the daemon if it is down or
                // wedged, instead of only probing health.
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