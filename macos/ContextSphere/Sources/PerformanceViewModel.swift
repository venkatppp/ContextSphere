import Foundation

@MainActor
final class PerformanceViewModel: ObservableObject {
    enum State: Equatable {
        case idle, loading, loaded, failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isFetching = false
    @Published var profile: ProfileSnapshot?
    @Published var startup: StartupProfile?
    @Published var diagnostics: DiagnosticsSnapshot?
    @Published var history: PerformanceHistory?
    @Published var optimizeResult: OptimizeResult?
    @Published var lastError: String?

    func initialLoadIfNeeded() async {
        guard state == .idle else { return }
        await refreshAll()
    }

    func refreshAll() async {
        state = .loading
        isFetching = true
        defer { isFetching = false }
        do {
            async let p: ProfileSnapshot = CoreBridge.shared.request("performance_profile", as: ProfileSnapshot.self)
            async let s: StartupProfile = CoreBridge.shared.request("performance_startup", as: StartupProfile.self)
            async let d: DiagnosticsSnapshot = CoreBridge.shared.request("performance_diagnostics", as: DiagnosticsSnapshot.self)
            async let h: PerformanceHistory = CoreBridge.shared.request("performance_history", params: ["limit": 20], as: PerformanceHistory.self)
            let (pp, ss, dd, hh) = try await (p, s, d, h)
            profile = pp
            startup = ss
            diagnostics = dd
            history = hh
            state = .loaded
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            if profile == nil { state = .failed(error.localizedDescription) } else { state = .loaded }
        }
    }

    func runBenchmark() async {
        isFetching = true
        defer { isFetching = false }
        do {
            let _: BenchmarkSuiteResult = try await CoreBridge.shared.request(
                "performance_benchmark",
                params: [:],
                as: BenchmarkSuiteResult.self,
                // Benchmarks run a full suite; give them headroom over the
                // default 60s request ceiling.
                timeout: 600)
            await refreshAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func runOptimize(apply: Bool) async {
        isFetching = true
        defer { isFetching = false }
        do {
            let res: OptimizeResult = try await CoreBridge.shared.request("performance_optimize", params: ["apply": apply], as: OptimizeResult.self)
            optimizeResult = res
            if apply { await refreshAll() }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
