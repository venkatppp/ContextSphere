import Foundation
import AppKit

/// State and data flow for the Search screen.
///
/// Follows the TimelineViewModel architecture: the view observes this
/// model; the model talks to the Rust core exclusively through
/// `CoreBridge` (JSON-RPC). Search runs on explicit submission (Return),
/// not per keystroke, and re-runs the current query when the daemon
/// emits `search:indexed`. Search history and saved searches live in the
/// Rust backend (`get_search_history`, `save_search`, …) — nothing is
/// stored locally.
@MainActor
final class SearchViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Daemon notification: the search index gained new content.
    static let searchIndexedEvent = "search:indexed"

    /// Result cap for one query (backend default is 20; bounded on
    /// purpose). History is capped too.
    private let resultLimit = 20
    private let historyLimit = 10

    @Published var query = ""
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var isSearching = false
    @Published private(set) var history: [String] = []
    @Published private(set) var savedSearches: [SavedSearch] = []
    @Published private(set) var lastError: String?
    /// Fetch failures for the Recent / Saved sections, so those panels
    /// never silently vanish.
    @Published private(set) var historyError: String?
    @Published private(set) var savedError: String?
    @Published var selectedResultID: String?
    /// Transient feedback for save/delete actions (auto-clears).
    @Published private(set) var notice: String?

    private(set) var workspaces: [Workspace] = []

    private var searchTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    // MARK: - Configuration

    func setWorkspaces(_ workspaces: [Workspace]) {
        self.workspaces = workspaces
    }

    func workspaceName(for result: SearchResult) -> String? {
        workspaces.first { $0.id == result.workspaceId }?.name
    }

    var selectedResult: SearchResult? {
        guard let selectedResultID else { return nil }
        return results.first { $0.id == selectedResultID }
    }

    // MARK: - Initial load

    func loadInitialData() async {
        await refreshHistory()
        await refreshSavedSearches()
    }

    // MARK: - Search execution

    func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        executeSearch(trimmed)
    }

    /// Restore a previous query and run it (history / saved-search click).
    func runQuery(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        query = trimmed
        executeSearch(trimmed)
    }

    func retry() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        executeSearch(trimmed)
    }

    private func executeSearch(_ q: String) {
        searchTask?.cancel()
        searchTask = Task { await performSearch(q) }
    }

    private func performSearch(_ q: String) async {
        isSearching = true
        state = .loading
        lastError = nil
        defer {
            isSearching = false
            searchTask = nil
        }
        do {
            let found: [SearchResult] = try await CoreBridge.shared.request(
                "search",
                params: [
                    "query": q,
                    "entity_types": ["workspace", "file"],
                    "limit": resultLimit,
                ],
                as: [SearchResult].self)
            guard !Task.isCancelled else { return }
            results = found
            selectedResultID = nil
            state = .loaded
            Task { await recordHistory(q) }
        } catch {
            guard !Task.isCancelled else { return }
            lastError = error.localizedDescription
            state = .failed(error.localizedDescription)
        }
    }

    /// The backend records history itself (`save_search_query`); we only
    /// report the executed query and refresh the display.
    private func recordHistory(_ q: String) async {
        try? await CoreBridge.shared.call("save_search_query", params: ["query": q])
        await refreshHistory()
    }

    // MARK: - Clearing

    func clearQuery() {
        searchTask?.cancel()
        query = ""
        results = []
        state = .idle
        lastError = nil
        selectedResultID = nil
    }

    // MARK: - History

    func refreshHistory() async {
        do {
            history = try await CoreBridge.shared.request(
                "get_search_history",
                params: ["limit": historyLimit],
                as: [String].self)
            historyError = nil
        } catch {
            // Non-fatal: the initial screen still works without history,
            // but the failure is surfaced instead of hiding the section.
            historyError = error.localizedDescription
        }
    }

    func clearHistory() async {
        do {
            try await CoreBridge.shared.call("clear_search_history")
            history = []
            historyError = nil
        } catch {
            showNotice("Could not clear history: \(error.localizedDescription)")
        }
    }

    // MARK: - Saved searches

    func refreshSavedSearches() async {
        do {
            savedSearches = try await CoreBridge.shared.request(
                "list_saved_searches", as: [SavedSearch].self)
            savedError = nil
        } catch {
            savedError = error.localizedDescription
        }
    }

    func saveCurrentQuery() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let _: SavedSearch = try await CoreBridge.shared.request(
                "save_search", params: ["query": trimmed], as: SavedSearch.self)
            await refreshSavedSearches()
            showNotice("Search saved")
        } catch {
            showNotice("Could not save search: \(error.localizedDescription)")
        }
    }

    func deleteSavedSearch(_ id: String) async {
        do {
            try await CoreBridge.shared.call("delete_saved_search", params: ["id": id])
            savedSearches.removeAll { $0.id == id }
        } catch {
            showNotice("Could not delete saved search: \(error.localizedDescription)")
        }
    }

    // MARK: - Result actions

    /// The absolute path of a file hit. For files the backend indexes
    /// `path_or_url` as the FTS title, so the title *is* the path;
    /// non-path titles simply fail gracefully downstream.
    func filePath(for result: SearchResult) -> String? {
        result.entityType == .file ? result.title : nil
    }

    /// Opens a file hit with AppKit, falling back to the core's
    /// `open_file` RPC for stale/unregistered paths. Returns success so
    /// the view can surface failures instead of failing silently.
    func openFile(_ result: SearchResult) async -> Bool {
        guard let path = filePath(for: result) else { return false }
        if NSWorkspace.shared.open(URL(fileURLWithPath: path)) { return true }
        do {
            try await CoreBridge.shared.call("open_file", params: ["path": path])
            return true
        } catch {
            showNotice("Could not open \(result.title): \(error.localizedDescription)")
            return false
        }
    }

    /// Reveals a file hit in Finder; surfaces failure as a notice.
    func revealInFinder(_ result: SearchResult) {
        guard let path = filePath(for: result) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - Workspace activation

    /// Activating a workspace hit really switches the daemon's active
    /// workspace (context tracking follows) before the view navigates.
    /// Returns whether the switch succeeded; failures surface via `notice`.
    func switchToWorkspace(_ id: String) async -> Bool {
        do {
            try await CoreBridge.shared.call("switch_workspace", params: ["id": id])
            if let name = workspaces.first(where: { $0.id == id })?.name {
                showNotice("Switched to \(name)")
            }
            return true
        } catch {
            showNotice("Could not switch workspace: \(error.localizedDescription)")
            return false
        }
    }

    private func showNotice(_ message: String) {
        noticeTask?.cancel()
        notice = message
        noticeTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    // MARK: - Live updates

    /// Entry point for daemon notifications routed by `AppShell`.
    func handle(event: String, payload: Data?) {
        guard event == Self.searchIndexedEvent else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        executeSearch(trimmed)
    }
}
