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
        state = .loading
        isFetching = true
        defer { isFetching = false }
        do {
            async let integ: IntegrityReport = CoreBridge.shared.request("maintenance_integrity", as: IntegrityReport.self)
            async let backs: [BackupRun] = CoreBridge.shared.request("maintenance_backups", params: ["limit": 20], as: [BackupRun].self)
            // pending may be null; decode as optional.
            async let pending: RestoreResult? = CoreBridge.shared.request("maintenance_pending_restore", as: RestoreResult?.self)
            let (i, b, p) = try await (integ, backs, pending)
            integrity = i
            backups = b
            pendingRestore = p
            state = .loaded
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            if integrity == nil { state = .failed(error.localizedDescription) }
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
