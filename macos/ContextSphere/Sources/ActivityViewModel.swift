import SwiftUI
import Combine

// MARK: - Activity DTOs (mirror Rust ActivityOverviewDto, camelCase)

struct ActivityDaySummary: Decodable, Hashable {
    let date: String
    let activeSeconds: Int
    let focusSessions: Int
    let applications: Int
    let websites: Int
    let hasData: Bool
}

struct ActivityTimelineEvent: Decodable, Identifiable, Hashable {
    let id: String
    let time: String
    let app: String
    let appSymbol: String
    let title: String
    let subtitle: String
    let durationMinutes: Int?
}

struct ActivitySession: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let timeRange: String
    let appsDescription: String
    let detail: String
    let events: [ActivityTimelineEvent]
    let apps: Int
    let files: Int
    let webPages: Int
}

struct ActivityAppUsage: Decodable, Identifiable, Hashable {
    let id: String
    let app: String
    let displayName: String
    let minutes: Int
    let percent: Double
    let files: [ActivityFileUsage]
    let sessions: [String]
}

struct ActivityFileUsage: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let minutes: Int
}

struct ActivityWebUsage: Decodable, Identifiable, Hashable {
    let id: String
    let domain: String
    let title: String
    let minutes: Int
    let pages: Int
    let favicon: String
}

struct ActivityDonutSegment: Decodable, Identifiable, Hashable {
    let id: String
    let label: String
    let percent: Double
    let minutes: Int
}

struct WorkspaceCorrelation: Decodable, Hashable {
    let workspaceName: String
    let project: String
    let activeMinutes: Int
    let apps: [[StringOrInt]]
    let filesModified: Int
    let filesOpened: Int
    let webPages: Int
    let hasData: Bool

    // Custom decode for apps = [[String, Int]]
    // Rust sends Vec<(String, i64)> which serializes as array of 2-element arrays.
    // First try to decode as [[StringOrInt]] then convert.
}

enum StringOrInt: Decodable, Hashable {
    case string(String)
    case int(Int)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "expect string or int"))
    }
}

struct WhatHappened: Decodable, Identifiable, Hashable {
    let id: String
    let dateLabel: String
    let workspace: String
    let title: String
    let summary: String
    let detail: String?
    let apps: [[String]]
    let files: Int
    let sessions: Int
    let webPages: Int
    let outcome: String?
    let hasSufficientEvidence: Bool
}

struct RecentMemory: Decodable, Identifiable, Hashable {
    let id: String
    let dateLabel: String
    let title: String
    let subtitle: String
}

struct ActivityOverview: Decodable, Hashable {
    let day: ActivityDaySummary
    let sessions: [ActivitySession]
    let appUsages: [ActivityAppUsage]
    let webUsages: [ActivityWebUsage]
    let donut: [ActivityDonutSegment]
    let correlation: WorkspaceCorrelation
    let whatHappened: WhatHappened?
    let recentMemory: [RecentMemory]
    let isEmpty: Bool
    let emptyReason: String?
}

// MARK: - View Model

@MainActor
final class ActivityViewModel: ObservableObject {
    @Published var overview: ActivityOverview?
    @Published var isLoading = false
    @Published var error: String?
    @Published var selectedWorkspaceId: String? // nil = All Workspaces
    @Published var dateFilter: String = "Today"
    @Published var searchQuery: String = ""
    @Published var workspaces: [Workspace] = []

    private var cancellables = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?

    init() {
        // Debounce search
        $searchQuery
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        $dateFilter
            .removeDuplicates()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        $selectedWorkspaceId
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    func setWorkspaces(_ ws: [Workspace]) {
        workspaces = ws
    }

    func initialLoadIfNeeded() {
        guard overview == nil && !isLoading else { return }
        refresh()
    }

    func refresh() {
        loadTask?.cancel()
        loadTask = Task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            var params: [String: Any] = [:]
            if let ws = selectedWorkspaceId { params["workspace_id"] = ws }
            params["date_filter"] = dateFilter
            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                params["search_query"] = searchQuery
            }
            let ov: ActivityOverview = try await CoreBridge.shared.request(
                "get_activity_overview",
                params: params,
                as: ActivityOverview.self
            )
            overview = ov
            self.error = nil
        } catch {
            // If command not yet available (old build), show empty state honestly
            self.error = (error as NSError).localizedDescription
        }
    }

    func handle(event: String, payload: Data?) {
        // Timeline or workspace changes should refresh activity
        if event.hasPrefix("timeline:") || event.hasPrefix("workspace:") || event == "activity:recorded" {
            Task { await load() }
        }
    }
}

// MARK: - Helpers for WorkspaceCorrelation apps decoding

extension WorkspaceCorrelation {
    var appPairs: [(String, Int)] {
        var res: [(String, Int)] = []
        for arr in apps {
            if arr.count == 2 {
                if case .string(let name) = arr[0], case .int(let mins) = arr[1] {
                    res.append((name, mins))
                } else if case .string(let name) = arr[0], case .string(let minsStr) = arr[1], let mins = Int(minsStr) {
                    res.append((name, mins))
                }
            }
        }
        return res
    }
}
