import Foundation

@MainActor
final class RecoveryViewModel: ObservableObject {
    enum State: Equatable { case idle, loading, loaded, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var isFetching = false
    @Published var status: HealthSnapshot?
    @Published var history: RecoveryHistory?
    @Published var crashes: [CrashReport] = []
    @Published var latestCheckpoint: RecoveryJournalEntry?
    @Published var lastTick: UInt64?
    @Published var lastError: String?
    @Published var selfHealResult: SelfHealingReport?
    @Published var rollbackResult: RollbackResult?

    func initialLoadIfNeeded() async {
        guard state == .idle else { return }
        await refresh()
    }

    func refresh() async {
        state = .loading
        isFetching = true
        defer { isFetching = false }
        do {
            async let s: HealthSnapshot = CoreBridge.shared.request("recovery_status", as: HealthSnapshot.self)
            async let h: RecoveryHistory = CoreBridge.shared.request("recovery_history", params: ["limit": 20], as: RecoveryHistory.self)
            async let c: [CrashReport] = CoreBridge.shared.request("recovery_crash_reports", params: ["limit": 20], as: [CrashReport].self)
            async let j: RecoveryJournalEntry? = CoreBridge.shared.request("recovery_latest_checkpoint", as: RecoveryJournalEntry?.self)
            let ss = try await s
            let hh = try await h
            let cc = try await c
            let jj: RecoveryJournalEntry? = try? await CoreBridge.shared.request("recovery_latest_checkpoint", as: RecoveryJournalEntry.self)
            status = ss
            history = hh
            crashes = cc
            latestCheckpoint = jj
            state = .loaded
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            if status == nil { state = .failed(error.localizedDescription) }
        }
    }

    func runSelfHeal() async {
        isFetching = true
        defer { isFetching = false }
        do {
            let r: SelfHealingReport = try await CoreBridge.shared.request("recovery_self_heal", as: SelfHealingReport.self)
            selfHealResult = r
            await refresh()
        } catch { lastError = error.localizedDescription }
    }

    func runRollback() async {
        isFetching = true
        defer { isFetching = false }
        do {
            let r: RollbackResult = try await CoreBridge.shared.request("recovery_rollback", as: RollbackResult.self)
            rollbackResult = r
            await refresh()
        } catch { lastError = error.localizedDescription }
    }

    func tick() async {
        do {
            let t: UInt64 = try await CoreBridge.shared.request("recovery_tick", as: UInt64.self)
            lastTick = t
        } catch { lastError = error.localizedDescription }
    }
}
