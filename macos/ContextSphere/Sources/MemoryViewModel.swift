import Foundation

/// State and data flow for the Memory screen.
///
/// The model talks to the Rust core exclusively through `CoreBridge`
/// (JSON-RPC): store statistics, learning health, learned workflows and
/// families, failure patterns, memory search/filtering, detail + lineage,
/// recommendation feedback, retention (forget/archive) and lifecycle
/// actions. SwiftUI views never touch the bridge directly.
@MainActor
final class MemoryViewModel: ObservableObject {

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Outcome of a per-memory backend action (feedback / retention).
    enum ActionState: Equatable {
        case idle
        case working
        case done
        case failed(String)
    }

    /// Cap for `memory_search` results. The backend clamps further; the UI
    /// filters only this bounded set locally.
    static let searchLimit = 50

    // MARK: - Screen data

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var isFetching = false
    @Published private(set) var lastError: String?

    @Published private(set) var stats: MemoryStats?
    @Published private(set) var health: LearningHealth?
    @Published private(set) var aging: MemoryAgingSummary?
    @Published private(set) var indexStatus: VectorIndexStatus?
    @Published private(set) var storage: MemoryStorageStats?
    @Published private(set) var families: [WorkflowFamily] = []
    @Published private(set) var failurePatterns: [FailurePattern] = []

    @Published private(set) var hits: [MemoryHit] = []
    @Published private(set) var hasSearched = false

    // MARK: - Selection / detail

    @Published var selectedID: String?
    @Published private(set) var selectedRecord: ExecutionMemoryRecord?
    @Published private(set) var lineage: MemoryLineage?
    @Published private(set) var detailLoading = false
    @Published private(set) var detailError: String?

    // MARK: - Filters

    @Published var query = ""
    @Published var selectedKind: MemoryKind?
    @Published var selectedStatus: MemoryStatus?
    @Published var selectedWorkspaceID: String?
    private var searchTask: Task<Void, Never>?

    // MARK: - Actions

    @Published private(set) var feedbackState: [String: ActionState] = [:]
    @Published private(set) var retentionState: [String: ActionState] = [:]
    @Published private(set) var cleanupReport: CleanupReport?
    @Published private(set) var reindexResult: IndexResult?
    @Published private(set) var cleanupRunning = false
    @Published private(set) var reindexRunning = false

    // MARK: - Depth: duplicates / snapshots / transfer / compression

    /// Identical-memory groups detected by the core (`memory_duplicate_groups`).
    @Published private(set) var duplicateGroups: [MemoryDuplicateGroup] = []
    @Published private(set) var duplicatesLoading = false
    @Published private(set) var mergeRunning = false
    @Published private(set) var mergeResult: MergeResult?

    /// Stored snapshots, newest first (`memory_snapshot_list`).
    @Published private(set) var snapshots: [MemorySnapshot] = []
    @Published private(set) var snapshotsLoading = false
    @Published private(set) var snapshotRunning = false
    /// Last snapshot action outcome, surfaced inline.
    @Published private(set) var snapshotNotice: String?
    @Published private(set) var restoreResult: SnapshotRestoreResult?
    /// Snapshot id awaiting the user's restore confirmation.
    @Published var pendingRestoreSnapshotID: String?

    @Published private(set) var importExportRunning = false
    @Published private(set) var importResult: MemoryImportResult?
    /// Inline confirmation for export/import outcomes.
    @Published var transferNotice: String?

    @Published private(set) var compressRunning = false
    @Published private(set) var compressResult: CompressionResult?
    @Published private(set) var restoreCompressedState: [String: ActionState] = [:]

    private(set) var workspaces: [Workspace] = []

    // MARK: - Configuration

    func setWorkspaces(_ workspaces: [Workspace]) {
        self.workspaces = workspaces
        if selectedWorkspaceID != nil
            && !workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
            selectedWorkspaceID = nil
        }
    }

    func workspaceName(for id: String?) -> String? {
        guard let id else { return nil }
        return workspaces.first { $0.id == id }?.name
    }

    // MARK: - Loading

    func initialLoadIfNeeded() async {
        guard state == .idle else { return }
        await refresh()
    }

    /// Reloads the whole screen from the backend. Individual RPC failures
    /// degrade gracefully: overview payloads are optional, so one failed
    /// call never blanks the rest of the screen.
    func refresh() async {
        if hits.isEmpty { state = .loading }
        isFetching = true
        lastError = nil
        defer { isFetching = false }

        async let stats: MemoryStats? = try? CoreBridge.shared.request("memory_stats", as: MemoryStats.self)
        async let health: LearningHealth? = try? CoreBridge.shared.request("memory_learning_health", as: LearningHealth.self)
        async let aging: MemoryAgingSummary? = try? CoreBridge.shared.request("memory_aging_summary", as: MemoryAgingSummary.self)
        async let index: VectorIndexStatus? = try? CoreBridge.shared.request("memory_index_status", as: VectorIndexStatus.self)
        async let storage: MemoryStorageStats? = try? CoreBridge.shared.request("memory_storage_stats", as: MemoryStorageStats.self)
        async let families: [WorkflowFamily]? = try? CoreBridge.shared.request("memory_workflow_families", as: [WorkflowFamily].self)
        async let failures: [FailurePattern]? = try? CoreBridge.shared.request("memory_failure_patterns", as: [FailurePattern].self)
        async let duplicates: [MemoryDuplicateGroup]? = try? CoreBridge.shared.request("memory_duplicate_groups", as: [MemoryDuplicateGroup].self)
        async let snapshots: [MemorySnapshot]? = try? CoreBridge.shared.request("memory_snapshot_list", as: [MemorySnapshot].self)

        let results = await (stats, health, aging, index, storage, families, failures, duplicates, snapshots)
        self.stats = results.0 ?? self.stats
        self.health = results.1 ?? self.health
        self.aging = results.2 ?? self.aging
        self.indexStatus = results.3 ?? self.indexStatus
        self.storage = results.4 ?? self.storage
        self.families = results.5 ?? self.families
        self.failurePatterns = results.6 ?? self.failurePatterns
        self.duplicateGroups = results.7 ?? self.duplicateGroups
        self.snapshots = results.8 ?? self.snapshots

        do {
            try await searchNow()
            lastError = nil
            state = .loaded
        } catch {
            lastError = error.localizedDescription
            if hits.isEmpty {
                state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Search / filtering

    /// Debounced search triggered by typing in the query field.
    func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do {
                try await self?.searchNow()
                self?.lastError = nil
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    /// Fetches the bounded memory list honoring the active filters. An
    /// empty query returns the most recent records (the backend ranks
    /// everything at similarity 0 and sorts newest first).
    func searchNow() async throws {
        var params: [String: Any] = ["query": query, "limit": Self.searchLimit]
        if let selectedKind { params["kind"] = selectedKind.rawValue }
        if let selectedStatus { params["status"] = selectedStatus.rawValue }
        if let selectedWorkspaceID { params["workspace_id"] = selectedWorkspaceID }
        let page: [MemoryHit] = try await CoreBridge.shared.request(
            "memory_search", params: params, as: [MemoryHit].self)
        hits = page
        hasSearched = true
        if let selectedID, !hits.contains(where: { $0.record.id == selectedID }) {
            deselect()
        }
    }

    func filterChange() {
        selectedID = nil
        Task {
            do {
                try await searchNow()
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func clearFilters() {
        query = ""
        selectedKind = nil
        selectedStatus = nil
        selectedWorkspaceID = nil
        filterChange()
    }

    // MARK: - Selection / detail

    func select(_ hit: MemoryHit) {
        selectedID = hit.record.id
        selectedRecord = hit.record
        lineage = nil
        detailError = nil
        Task { await loadLineage(for: hit.record.id) }
    }

    func deselect() {
        selectedID = nil
        selectedRecord = nil
        lineage = nil
        detailError = nil
    }

    private func loadLineage(for id: String) async {
        detailLoading = true
        detailError = nil
        defer { detailLoading = false }
        do {
            lineage = try await CoreBridge.shared.request(
                "memory_lineage", params: ["memory_id": id], as: MemoryLineage?.self)
        } catch {
            detailError = error.localizedDescription
        }
    }

    // MARK: - Recommendation feedback

    func sendFeedback(for id: String, accepted: Bool) async {
        feedbackState[id] = .working
        do {
            try await CoreBridge.shared.call(
                "memory_recommendation_feedback",
                params: ["memory_id": id, "accepted": accepted])
            feedbackState[id] = .done
            await refreshOverviewOnly()
        } catch {
            feedbackState[id] = .failed(error.localizedDescription)
        }
    }

    // MARK: - Retention / forget

    /// Sets a record's retention policy. `Forget` marks the record
    /// expired; the backend removes expired records on the next cleanup
    /// pass. The UI never claims removal before the backend confirms it.
    func setRetention(for id: String, policy: RetentionPolicy) async {
        retentionState[id] = .working
        defer { retentionState[id] = .idle }
        do {
            try await CoreBridge.shared.call(
                "memory_set_retention",
                params: ["memory_id": id, "policy": policy.rawValue])
            await refresh()
        } catch {
            retentionState[id] = .failed(error.localizedDescription)
        }
    }

    // MARK: - Lifecycle actions

    func runCleanup() async {
        cleanupRunning = true
        defer { cleanupRunning = false }
        do {
            cleanupReport = try await CoreBridge.shared.request("memory_cleanup_now", as: CleanupReport.self)
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func reindex() async {
        reindexRunning = true
        defer { reindexRunning = false }
        do {
            reindexResult = try await CoreBridge.shared.request("memory_reindex", as: IndexResult.self)
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Depth: duplicates

    func refreshDuplicates() async {
        duplicatesLoading = true
        defer { duplicatesLoading = false }
        do {
            duplicateGroups = try await CoreBridge.shared.request(
                "memory_duplicate_groups", as: [MemoryDuplicateGroup].self)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Merges identical memories (the core keeps the best record of each
    /// group). Confirmation lives in the view; this only runs the RPC.
    func mergeDuplicates() async {
        mergeRunning = true
        defer { mergeRunning = false }
        do {
            mergeResult = try await CoreBridge.shared.request(
                "memory_merge_duplicates", as: MergeResult.self)
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Depth: snapshots

    func createSnapshot(label: String?) async {
        snapshotRunning = true
        defer { snapshotRunning = false }
        var params: [String: Any] = [:]
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { params["label"] = trimmed }
        do {
            _ = try await CoreBridge.shared.request(
                "memory_snapshot_create", params: params, as: MemorySnapshot.self)
            snapshotNotice = "Snapshot created"
            await refresh()
        } catch {
            snapshotNotice = "Could not create snapshot: \(error.localizedDescription)"
        }
    }

    func restoreSnapshot(_ id: String) async {
        pendingRestoreSnapshotID = nil
        snapshotRunning = true
        defer { snapshotRunning = false }
        do {
            restoreResult = try await CoreBridge.shared.request(
                "memory_snapshot_restore",
                params: ["snapshot_id": id],
                as: SnapshotRestoreResult.self)
            snapshotNotice = "Restored \(restoreResult?.recordsRestored ?? 0) records"
            deselect()
            await refresh()
        } catch {
            snapshotNotice = "Restore failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Depth: export / import

    /// Writes a full-store export to the chosen file. The save panel and
    /// confirmation live in the view; returns success for the inline notice.
    func exportToFile(at url: URL) async -> Bool {
        importExportRunning = true
        defer { importExportRunning = false }
        do {
            let payload = try await CoreBridge.shared.request(
                "memory_export_json", as: String.self)
            guard let data = payload.data(using: .utf8) else {
                lastError = "Export produced invalid text"
                return false
            }
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Imports an export payload previously written by `exportToFile`.
    func importFromFile(at url: URL) async {
        importExportRunning = true
        defer { importExportRunning = false }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            importResult = try await CoreBridge.shared.request(
                "memory_import_json", params: ["content": content], as: MemoryImportResult.self)
            await refresh()
        } catch {
            lastError = "Import failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Depth: compression

    func compressOversized() async {
        compressRunning = true
        defer { compressRunning = false }
        do {
            compressResult = try await CoreBridge.shared.request(
                "memory_compress_oversized", as: CompressionResult.self)
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Restores one compressed record from its preservation archive.
    func restoreCompressed(_ id: String) async {
        restoreCompressedState[id] = .working
        defer { restoreCompressedState[id] = nil }
        do {
            let restored = try await CoreBridge.shared.request(
                "memory_restore_compressed",
                params: ["memory_id": id],
                as: Bool.self)
            if restored {
                if selectedID == id { await loadLineage(for: id) }
                await refreshOverviewOnly()
            } else {
                lastError = "The core could not restore that memory"
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func refreshOverviewOnly() async {
        if let fresh = try? await CoreBridge.shared.request("memory_learning_health", as: LearningHealth.self) {
            health = fresh
        }
        if let fresh = try? await CoreBridge.shared.request("memory_stats", as: MemoryStats.self) {
            stats = fresh
        }
    }
}

// MARK: - Presentation helpers

extension ExecutionMemoryRecord {
    var createdAtDate: Date { createdAt.isoDate ?? .distantPast }
    var updatedAtDate: Date { updatedAt.isoDate ?? .distantPast }
    var retentionUntilDate: Date? { retentionUntil?.isoDate }
}

extension Double {
    /// Percent with one decimal, for confidence/accuracy readings.
    var percentString: String {
        formatted(.percent.precision(.fractionLength(1)))
    }
}