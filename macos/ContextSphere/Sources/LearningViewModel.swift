import Foundation

/// State and data flow for the Learning screen.
///
/// Exposes what ContextSphere has learned about how the user works:
/// learning statistics, learned preferences, behavioral patterns,
/// confidence trends and recommendation accuracy. All data comes from the
/// backend's adaptive learning system via `CoreBridge` (JSON-RPC) — this
/// screen only renders what the backend actually learned.
@MainActor
final class LearningViewModel: ObservableObject {

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var isFetching = false
    @Published private(set) var lastError: String?

    @Published private(set) var insights: LearningInsights?
    @Published private(set) var preferences: [UserPreference] = []
    @Published private(set) var patterns: [BehavioralPattern] = []

    // MARK: - Loading

    func initialLoadIfNeeded() async {
        guard state == .idle else { return }
        await refresh()
    }

    func refresh() async {
        if insights == nil { state = .loading }
        isFetching = true
        defer { isFetching = false }

        // Each RPC is independent — a failure in preferences or patterns must not
        // turn a valid insights payload into "unavailable". Conversely, a failed
        // insights fetch with no cached data is a genuine error that Retry must re-run.
        async let insightsResult: LearningInsights? = try? CoreBridge.shared.request(
            "get_learning_insights", as: LearningInsights.self)
        async let preferencesResult: [UserPreference]? = try? CoreBridge.shared.request(
            "get_user_preferences", as: [UserPreference].self)
        async let patternsResult: [BehavioralPattern]? = try? CoreBridge.shared.request(
            "get_behavioral_patterns", as: [BehavioralPattern].self)

        let (loadedInsights, loadedPreferences, loadedPatterns) = await (insightsResult, preferencesResult, patternsResult)

        var hadError = false
        if let loadedInsights {
            self.insights = loadedInsights
        } else if self.insights == nil {
            hadError = true
        }
        if let loadedPreferences { self.preferences = loadedPreferences }
        if let loadedPatterns { self.patterns = loadedPatterns }

        if hadError {
            // Genuine failure: no insights at all and the fetch failed.
            // Try one strong synchronous fetch to capture the error message for the UI.
            do {
                let strong: LearningInsights = try await CoreBridge.shared.request("get_learning_insights", as: LearningInsights.self)
                self.insights = strong
                self.preferences = (try? await CoreBridge.shared.request("get_user_preferences", as: [UserPreference].self)) ?? self.preferences
                self.patterns = (try? await CoreBridge.shared.request("get_behavioral_patterns", as: [BehavioralPattern].self)) ?? self.patterns
                lastError = nil
                state = .loaded
            } catch {
                let msg = error.localizedDescription
                lastError = msg
                state = .failed(msg)
                return
            }
        } else {
            lastError = nil
            state = .loaded
        }
    }
}

// MARK: - Presentation helpers

extension BehavioralPattern {
    var firstSeenDate: Date { firstSeen.isoDate ?? .distantPast }
    var lastSeenDate: Date { lastSeen.isoDate ?? .distantPast }
}

extension UserPreference {
    var lastUpdatedDate: Date { lastUpdated.isoDate ?? .distantPast }
}

extension ConfidenceTrend {
    var dateValue: Date { date.isoDate ?? .distantPast }
}