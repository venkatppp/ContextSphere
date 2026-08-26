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

    /// Page size for `list_workspace_timeline`. The backend clamps to
    /// 500 per request; deeper history is fetched with server-side
    /// offsets instead of one oversized query.
    private let pageSize = 250

    @Published private(set) var events: [TimelineEvent] = []
    @Published private(set) var groups: [DayGroup] = []
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var isFetching = false
    @Published private(set) var hasMore = false
    /// Recent work sessions for the selected workspace, computed by the
    /// core's SessionEngine from timeline events (`get_workspace_sessions`).
    @Published private(set) var sessions: [WorkspaceSession] = []
    @Published private(set) var selectedSessionID: String?
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
        selectedSessionID = nil
        lastError = nil
        Task {
            await fetch(append: false)
            await loadSessions()
        }
    }

    // MARK: - Sessions

    /// Selecting a session filters the feed to that session's window.
    func selectSession(_ id: String?) {
        guard let id else {
            clearSessionSelection()
            return
        }
        selectedSessionID = id == selectedSessionID ? nil : id
        recomputeGroups()
    }

    func clearSessionSelection() {
        selectedSessionID = nil
        recomputeGroups()
    }

    private func loadSessions() async {
        guard let workspaceId = selectedWorkspaceId else {
            sessions = []
            return
        }
        do {
            sessions = try await CoreBridge.shared.request(
                "get_workspace_sessions",
                params: ["workspace_id": workspaceId, "limit": 4],
                as: [WorkspaceSession].self)
        } catch {
            // Sessions are a summary layer; the feed still works without them.
            sessions = []
        }
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
        await loadSessions()
    }

    func refresh() async {
        lastError = nil
        await fetch(append: false)
        await loadSessions()
    }

    func loadMore() async {
        guard hasMore, !isFetching else { return }
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
            // Server-side offset pagination: each page skips everything
            // already loaded. Live events inserted at the top can shift
            // offsets between pages; `knownIds` dedupes any overlap.
            let offset = append ? events.count : 0
            let page: [TimelineEvent] = try await CoreBridge.shared.request(
                "list_workspace_timeline",
                params: [
                    "workspace_id": workspaceId,
                    "limit": pageSize,
                    "offset": offset,
                ],
                as: [TimelineEvent].self)
            if append {
                let fresh = page.filter { !knownIds.contains($0.id) }
                knownIds.formUnion(fresh.map(\.id))
                events.append(contentsOf: fresh)
            } else {
                knownIds = Set(page.map(\.id))
                events = page
            }
            hasMore = page.count == pageSize
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
        // A selected session narrows the feed to that session's window.
        let sessionWindow: (ClosedRange<Date>)? = {
            guard let id = selectedSessionID,
                let session = sessions.first(where: { $0.id == id }) else { return nil }
            let start = session.startedAt.isoDate ?? .distantPast
            let end = session.endedAt.isoDate ?? .distantFuture
            return start...end
        }()
        var buckets: [Date: [TimelineEvent]] = [:]
        for event in events
        where selectedType == nil || event.eventType == selectedType {
            let date = event.occurredAtDate
            if let window = sessionWindow, !window.contains(date) { continue }
            let day = calendar.startOfDay(for: date)
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
