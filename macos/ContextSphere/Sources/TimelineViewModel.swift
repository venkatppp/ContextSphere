import Foundation

/// State and data flow for the Timeline screen.
///
/// `TimelineView` observes this model; the model talks to the Rust core
/// exclusively through `CoreBridge` (JSON-RPC), and reacts to daemon
/// notifications (e.g. `timeline:event_added`) for live updates.
@MainActor
final class TimelineViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    struct DayGroup: Identifiable {
        let day: Date
        let label: String
        let events: [TimelineEvent]
        var id: Date { day }
    }

    /// Daemon notification carrying a serialized `TimelineEvent`.
    static let eventAddedEvent = "timeline:event_added"

    /// Page sizes for `list_workspace_timeline`. The backend clamps to
    /// 500; loading "more" moves to the next tier instead of unbounded
    /// history.
    private let pageSizes = [100, 250, 500]

    @Published private(set) var events: [TimelineEvent] = []
    @Published private(set) var groups: [DayGroup] = []
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var isFetching = false
    @Published private(set) var hasMore = false
    /// Non-fatal error (e.g. a background refresh failed while content is
    /// already on screen). Cleared on the next successful fetch.
    @Published private(set) var lastError: String?
    @Published var selectedType: TimelineEventType?

    private(set) var workspaces: [Workspace] = []
    private(set) var selectedWorkspaceId: String?

    private var knownIds: Set<String> = []
    private var pageIndex = 0

    // MARK: - Configuration

    func setWorkspaces(_ workspaces: [Workspace]) {
        self.workspaces = workspaces
        if selectedWorkspaceId == nil
            || !workspaces.contains(where: { $0.id == selectedWorkspaceId }) {
            selectedWorkspaceId = workspaces.first?.id
        }
    }

    func selectWorkspace(_ id: String?) {
        guard id != selectedWorkspaceId else { return }
        selectedWorkspaceId = id
        pageIndex = 0
        lastError = nil
        Task { await fetch(append: false) }
    }

    func selectType(_ type: TimelineEventType?) {
        selectedType = type
        recomputeGroups()
    }

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceId }
    }

    func workspaceName(for event: TimelineEvent) -> String? {
        workspaces.first { $0.id == event.workspaceId }?.name
    }

    /// Events visible after the type filter, i.e. what the header count
    /// reports.
    var displayedEventCount: Int {
        groups.reduce(0) { $0 + $1.events.count }
    }

    // MARK: - Loading

    func initialLoadIfNeeded() async {
        guard state == .idle else { return }
        await fetch(append: false)
    }

    func refresh() async {
        pageIndex = 0
        lastError = nil
        await fetch(append: false)
    }

    func loadMore() async {
        guard hasMore, !isFetching, pageIndex < pageSizes.count - 1 else { return }
        pageIndex += 1
        await fetch(append: true)
    }

    private func fetch(append: Bool) async {
        guard let workspaceId = selectedWorkspaceId else {
            events = []
            knownIds = []
            hasMore = false
            state = .loaded
            recomputeGroups()
            return
        }

        if events.isEmpty {
            state = .loading
        }
        isFetching = true
        defer { isFetching = false }

        do {
            let limit = pageSizes[pageIndex]
            let page: [TimelineEvent] = try await CoreBridge.shared.request(
                "list_workspace_timeline",
                params: ["workspace_id": workspaceId, "limit": limit],
                as: [TimelineEvent].self)
            if append {
                let fresh = page.filter { !knownIds.contains($0.id) }
                knownIds.formUnion(fresh.map(\.id))
                events.append(contentsOf: fresh)
            } else {
                knownIds = Set(page.map(\.id))
                events = page
            }
            hasMore = page.count == limit && pageIndex < pageSizes.count - 1
            lastError = nil
            state = .loaded
        } catch {
            lastError = error.localizedDescription
            if events.isEmpty {
                state = .failed(error.localizedDescription)
            }
        }
        recomputeGroups()
    }

    // MARK: - File actions

    /// `open_file` RPC fallback for paths NSWorkspace could not open
    /// directly (e.g. stale or non-registered). Failures surface in the
    /// same inline banner as refresh errors.
    func openViaCoreFallback(_ path: String) async {
        do {
            try await CoreBridge.shared.call("open_file", params: ["path": path])
        } catch {
            lastError = "Could not open \(path): \(error.localizedDescription)"
        }
    }

    // MARK: - Live updates

    /// Entry point for daemon notifications routed by `AppShell`.
    func handle(event: String, payload: Data?) {
        guard event == Self.eventAddedEvent, let payload else { return }
        guard let newEvent = try? JSONDecoder().decode(TimelineEvent.self, from: payload) else {
            return
        }
        guard !knownIds.contains(newEvent.id) else { return }
        knownIds.insert(newEvent.id)
        guard let selectedWorkspaceId, newEvent.workspaceId == selectedWorkspaceId else { return }
        if let selectedType, newEvent.eventType != selectedType { return }
        events.insert(newEvent, at: 0)
        recomputeGroups()
    }

    // MARK: - Grouping

    private func recomputeGroups() {
        let calendar = Calendar.current
        var buckets: [Date: [TimelineEvent]] = [:]
        for event in events where selectedType == nil || event.eventType == selectedType {
            let day = calendar.startOfDay(for: event.occurredAtDate)
            buckets[day, default: []].append(event)
        }
        groups = buckets.keys.sorted(by: >).map { day in
            DayGroup(
                day: day,
                label: Self.dayLabel(for: day, calendar: calendar),
                events: buckets[day]!.sorted { $0.occurredAtDate > $1.occurredAtDate }
            )
        }
    }

    private static func dayLabel(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if calendar.isDate(day, equalTo: .now, toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }
}
