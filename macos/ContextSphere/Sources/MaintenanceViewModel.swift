import Foundation

@MainActor
final class MaintenanceViewModel: ObservableObject {
    enum State: Equatable { case idle, loading, loaded, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var isFetching = false
    @Published var integrity: IntegrityReport?
    @Published var backups: [BackupRun] = []
    @Published var pendingRestore: RestoreResult?
    @Published var lastOptimize: MaintenanceReport?
    @Published var lastError: String?

    func initialLoadIfNeeded() async {
        guard state == .idle else { return }
        await refresh()
    }

    func refresh() async {
        // Preserve previously loaded integrity when possible; only show loading when we have nothing.
        if integrity == nil { state = .loading }
        isFetching = true
        defer { isFetching = false }

        // Each RPC is independent — a failure in backups or pending must not turn
        // a valid integrity response into "unavailable", and an empty backups array
        // (no backups yet) is a valid empty state, not an error.
        var integ: IntegrityReport?
        var backs: [BackupRun]?
        var pending: RestoreResult?
        var pendingIsNil = false
        var integError: String?
        var backsError: String?
        var pendingError: String?

        // Integrity is essential; fetch first.
        do {
            integ = try await CoreBridge.shared.request("maintenance_integrity", as: IntegrityReport.self)
        } catch {
            integError = error.localizedDescription
            // "empty result" from a transport miss should be surfaced as a real error for integrity.
            if integError == "empty result" { integError = "Database health check returned no data — try Retry." }
        }
        // Backups: empty array is valid, not an error.
        do {
            backs = try await CoreBridge.shared.request("maintenance_backups", params: ["limit": 20], as: [BackupRun].self)
        } catch {
            let msg = error.localizedDescription
            if msg == "empty result" {
                backs = []
            } else {
                backsError = msg
            }
        }
        // Pending restore: null means no pending restore (valid empty), not an error.
        do {
            // Decode as optional; a JSON null becomes nil without error.
            let result: RestoreResult? = try await CoreBridge.shared.request("maintenance_pending_restore", as: RestoreResult?.self)
            pending = result
            pendingIsNil = (result == nil)
        } catch {
            let msg = error.localizedDescription
            if msg == "empty result" {
                // Backend returned no pending restore marker — treat as no pending restore, not failure.
                pending = nil
                pendingIsNil = true
            } else if msg.lowercased().contains("was not found") || msg.lowercased().contains("not found") {
                pending = nil
                pendingIsNil = true
            } else {
                pendingError = msg
            }
        }

        if let integ { integrity = integ }
        if let backs { backups = backs }
        // Only overwrite pendingRestore when we got a definitive result (object or explicit nil).
        // If pending fetch failed with a transport error, keep previous value and surface error.
        if pendingIsNil || pending != nil {
            pendingRestore = pending
        } else if pendingError == nil {
            // Explicit nil from successful decode
            pendingRestore = nil
        }

        if integrity != nil {
            state = .loaded
            // Surface the first non-nil error inline, but keep the screen loaded (graceful degradation).
            lastError = integError ?? backsError ?? pendingError
            if lastError == nil {
                // Clear prior error on full success.
                lastError = nil
            }
        } else {
            // Integrity is essential: without it the maintenance screen cannot show health.
            let msg = integError ?? backsError ?? pendingError ?? "empty result"
            lastError = msg
            state = .failed(msg)
        }
    }

    func runBackup() async {
        isFetching = true
        defer { isFetching = false }
        do {
            let _: BackupRun = try await CoreBridge.shared.request("maintenance_backup", as: BackupRun.self)
            await refresh()
        } catch { lastError = error.localizedDescription }
    }

    func runOptimize() async {
        isFetching = true
        defer { isFetching = false }
        do {
            let rep: MaintenanceReport = try await CoreBridge.shared.request("maintenance_optimize", as: MaintenanceReport.self)
            lastOptimize = rep
            await refresh()
        } catch { lastError = error.localizedDescription }
    }

    func stageRestore(id: Int64) async {
        isFetching = true
        defer { isFetching = false }
        do {
            let _: RestoreResult = try await CoreBridge.shared.request("maintenance_restore", params: ["backup_id": id], as: RestoreResult.self)
            await refresh()
        } catch { lastError = error.localizedDescription }
    }

    func cancelRestore() async {
        isFetching = true
        defer { isFetching = false }
        do {
            try await CoreBridge.shared.call("maintenance_cancel_restore")
            await refresh()
        } catch { lastError = error.localizedDescription }
    }
}
