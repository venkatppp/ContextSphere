import Foundation

// Codable mirrors of the Rust core's serde models (camelCase, exactly as
// the daemon serializes them). Keys are validated against src-tauri/src/models/*.

// MARK: - System

struct HealthStatus: Decodable {
    let ok: Bool
    let backendVersion: String
}

// MARK: - Workspaces

struct Workspace: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?
    let status: WorkspaceStatus
    let healthScore: Double
    let rootPath: String?
    let lastActiveAt: String
    let createdAt: String
    let updatedAt: String
}

enum WorkspaceStatus: String, Codable {
    case active, archived, pending
}

struct CreateWorkspaceInput: Encodable {
    let name: String
    let rootPath: String?
    let description: String?
}

struct UpdateWorkspaceInput: Encodable {
    let name: String?
    let description: String?
    let status: WorkspaceStatus?
}

// MARK: - Timeline

struct TimelineEvent: Decodable, Identifiable {
    let id: String
    let workspaceId: String
    let fileId: String?
    let eventType: TimelineEventType
    let occurredAt: String
    let metadata: [String: JSONValue]?
    let createdAt: String
}

enum TimelineEventType: String, Decodable, CaseIterable, Hashable {
    case create, open, close, edit, move, delete, commit, visit, screenshot
    case workspaceSwitch = "workspace_switch"

    var symbol: String {
        switch self {
        case .create: "plus.circle"
        case .open: "arrow.up.forward.circle"
        case .close: "xmark.circle"
        case .edit: "pencil.circle"
        case .move: "arrow.left.and.right.circle"
        case .delete: "trash.circle"
        case .commit: "checkmark.circle"
        case .visit: "eye.circle"
        case .screenshot: "camera.circle"
        case .workspaceSwitch: "arrow.triangle.swap"
        }
    }

    var title: String {
        switch self {
        case .create: "Created"
        case .open: "Opened"
        case .close: "Closed"
        case .edit: "Edited"
        case .move: "Moved"
        case .delete: "Deleted"
        case .commit: "Committed"
        case .visit: "Visited"
        case .screenshot: "Screenshot"
        case .workspaceSwitch: "Workspace switch"
        }
    }
}

// MARK: - Search

enum SearchEntityType: String, Decodable, Hashable {
    case workspace, file
}

/// One hit from the backend's FTS5 search (`search` RPC). `snippet` is a
/// BM25-ranked excerpt with `<b>…</b>` match-highlight markers; `rank` is
/// the raw FTS5 bm25() value (lower = better) and is deliberately not
/// surfaced in the UI.
struct SearchResult: Decodable, Identifiable, Hashable {
    let entityType: SearchEntityType
    let entityId: String
    let workspaceId: String
    let title: String
    let snippet: String
    let rank: Double

    var id: String { "\(entityType.rawValue):\(entityId)" }
}

/// A query persisted by `save_search`.
struct SavedSearch: Decodable, Identifiable, Hashable {
    let id: String
    let query: String
    let createdAt: String
}

// MARK: - Knowledge graph (RC-8)

/// The node vocabulary of the RC-8 knowledge graph (`graph_nodes`).
enum GraphNodeType: String, Decodable, Hashable, CaseIterable {
    case workspace, file
    case plannerReport = "planner_report"
    case execution
    case memoryRecord = "memory_record"
    case autonomousSession = "autonomous_session"
}

/// One node in the RC-8 knowledge graph. `metadata` is free-form JSON
/// (status, artifact type, evidence, …); `summary` for file nodes is the
/// file path. IDs are backend UUIDs and are never shown to the user.
struct KgNode: Decodable, Identifiable, Hashable {
    let nodeType: GraphNodeType
    let entityId: String
    let title: String
    let workspaceId: String?
    let summary: String?
    let metadata: JSONValue
    let createdAt: String
    let updatedAt: String

    var id: String { "\(nodeType.rawValue):\(entityId)" }
}

/// The relationship vocabulary of the RC-8 knowledge graph.
enum GraphRelationshipType: String, Decodable, Hashable {
    case contains
    case runsIn = "runs_in"
    case reportsOn = "reports_on"
    case derivedFrom = "derived_from"
    case relatedTo = "related_to"
}

/// One edge in the RC-8 knowledge graph (`graph_relationships`).
struct KgEdge: Decodable, Identifiable, Hashable {
    let id: String
    let sourceNodeType: GraphNodeType
    let sourceEntityId: String
    let targetNodeType: GraphNodeType
    let targetEntityId: String
    let relationshipType: GraphRelationshipType
    /// Strength of the relationship (0.0 to 1.0).
    let weight: Double
    /// Confidence in the relationship (0.0 to 1.0).
    let confidence: Double
    let metadata: JSONValue
    let createdAt: String
    let updatedAt: String

    var sourceID: String { "\(sourceNodeType.rawValue):\(sourceEntityId)" }
    var targetID: String { "\(targetNodeType.rawValue):\(targetEntityId)" }
}

/// BFS subgraph around a root node (`graph_subgraph`).
struct KgSubgraph: Decodable {
    let root: KgNode
    let nodes: [KgNode]
    let edges: [KgEdge]
}

/// Ranked hit from `graph_vector_search` / `graph_ranked_search` (RC-8 M4).
/// Score is normalized 0…1 (cosine 0…1 for vector, keyword+recency for ranked).
struct RankedSearchHit: Decodable {
    let node: KgNode
    let score: Double
    let method: String
    let reason: String
}

// MARK: - Knowledge graph (legacy `graph_edges` view)

/// Type of relationship in the legacy graph (`get_graph`).
enum GraphEdgeType: String, Decodable, Hashable {
    case coOccurrence = "co_occurrence"
    case semanticSimilarity = "semantic_similarity"
    case explicitReference = "explicit_reference"
    case derivation
}

/// Node in the legacy `get_graph` view (workspace/file aggregates).
struct GraphNode: Decodable, Identifiable, Hashable {
    let entityType: SearchEntityType
    let entityId: String
    let title: String
    let workspaceId: String

    var id: String { "\(entityType.rawValue):\(entityId)" }
}

/// Edge in the legacy `get_graph` view.
struct GraphEdge: Decodable, Identifiable, Hashable {
    let id: String
    let sourceEntityType: SearchEntityType
    let sourceEntityId: String
    let targetEntityType: SearchEntityType
    let targetEntityId: String
    let edgeType: GraphEdgeType
    let weight: Double
    let workspaceId: String
    let metadata: String?
    let createdAt: String
    let updatedAt: String
}

/// View of a graph section (`get_graph`): nodes + edges.
struct GraphView: Decodable {
    let nodes: [GraphNode]
    let edges: [GraphEdge]
}

// MARK: - Settings

/// LLM provider as serialized by the daemon (`LLMProviderType`,
/// `rename_all = "lowercase"`).
enum LLMProviderType: String, Codable, CaseIterable, Hashable {
    case openai
    case ollama
    case custom
}

/// LLM provider configuration (`llm_get_settings` / `llm_update_settings`).
/// The Rust struct carries no serde rename, so the wire keys are
/// snake_case; `CodingKeys` maps them to idiomatic Swift names.
struct LLMSettings: Codable, Hashable {
    var provider: LLMProviderType
    var baseUrl: String
    var apiKey: String
    var model: String
    var temperature: Double
    var maxTokens: Int
    var contextWindow: Int

    enum CodingKeys: String, CodingKey {
        case provider
        case baseUrl = "base_url"
        case apiKey = "api_key"
        case model
        case temperature
        case maxTokens = "max_tokens"
        case contextWindow = "context_window"
    }
}

/// One `security_config` row (`security_config` / `security_set_config`).
/// Only explicitly set keys are returned; unset keys fall back to the
/// backend's built-in defaults.
struct SecurityConfigEntry: Decodable, Identifiable, Hashable {
    let key: String
    let value: String
    let updatedAt: String

    var id: String { key }
}

// MARK: - Execution memory (RC-6)

/// What kind of execution produced a memory record (`MemoryKind`,
/// snake_case).
enum MemoryKind: String, Decodable, Hashable, CaseIterable {
    case execution
    case plannerReport = "planner_report"
    case autonomousSession = "autonomous_session"

    var title: String {
        switch self {
        case .execution: "Execution"
        case .plannerReport: "Planner report"
        case .autonomousSession: "Autonomous session"
        }
    }

    var symbol: String {
        switch self {
        case .execution: "terminal"
        case .plannerReport: "list.clipboard"
        case .autonomousSession: "sparkles.rectangle.stack"
        }
    }
}

/// Outcome of a remembered run (`MemoryStatus`, snake_case).
enum MemoryStatus: String, Decodable, Hashable, CaseIterable {
    case success, failed, cancelled

    var title: String {
        switch self {
        case .success: "Succeeded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

/// Retention policy of a memory record (`RetentionPolicy`, snake_case).
enum RetentionPolicy: String, Decodable, Hashable, CaseIterable {
    case permanent, temporary, archived, expired

    var title: String {
        switch self {
        case .permanent: "Permanent"
        case .temporary: "Temporary"
        case .archived: "Archived"
        case .expired: "Expired"
        }
    }
}

/// Structured outcome accounting stored on every memory record.
struct MemoryOutcome: Decodable, Hashable {
    let steps: Int
    let completed: Int
    let replaced: Int
    let replanCount: Int
    let retriesUsed: Int
    let plansAttempted: Int
    let durationSeconds: Int

    enum CodingKeys: String, CodingKey {
        case steps, completed, replaced
        case replanCount = "replan_count"
        case retriesUsed = "retries_used"
        case plansAttempted = "plans_attempted"
        case durationSeconds = "duration_seconds"
    }
}

// MARK: - Execution memory records

/// One task of an execution plan (`PlanTask`). The conditional gate
/// (`condition`) is intentionally not modeled: it never appears in the
/// memory screen's rendering.
struct MemoryPlanTask: Decodable, Hashable {
    let id: String
    let description: String
    let dependencies: [String]
    let estimatedMinutes: Int
    let requiredFiles: [String]
    let toolName: String?
    let completed: Bool

    enum CodingKeys: String, CodingKey {
        case id, description, dependencies, completed
        case estimatedMinutes = "estimated_minutes"
        case requiredFiles = "required_files"
        case toolName = "tool_name"
    }
}

/// A reusable plan remembered with a run (`ExecutionPlan`).
struct MemoryPlan: Decodable, Hashable {
    let id: String
    let workspaceId: String?
    let goal: String
    let tasks: [MemoryPlanTask]
    let estimatedDurationMinutes: Int
    let requiredFiles: [String]
    let checkpoints: [String]
    let confidence: Double
    let reasoning: String
    let status: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, goal, tasks, confidence, reasoning, status, checkpoints
        case workspaceId = "workspace_id"
        case estimatedDurationMinutes = "estimated_duration_minutes"
        case requiredFiles = "required_files"
        case createdAt = "created_at"
    }
}

/// One durable memory row (`ExecutionMemoryRecord`). IDs are backend
/// UUIDs and are never shown to the user.
struct ExecutionMemoryRecord: Decodable, Hashable {
    let id: String
    let kind: MemoryKind
    let sourceId: String
    let workspaceId: String?
    let goal: String
    let status: MemoryStatus
    let plan: MemoryPlan?
    let steps: [String]
    let reasoning: [String]
    let toolsUsed: [String]
    let failedSteps: [String]
    let error: String?
    let outcome: MemoryOutcome
    let replayCount: Int
    let createdAt: String
    let updatedAt: String
    let retention: RetentionPolicy
    let retentionUntil: String?
    let archivedAt: String?
    let expiredAt: String?
    let summary: String?
    let compressedAt: String?
    let version: Int
    let parentId: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, goal, status, plan, steps, reasoning, error, outcome
        case sourceId = "source_id"
        case workspaceId = "workspace_id"
        case toolsUsed = "tools_used"
        case failedSteps = "failed_steps"
        case replayCount = "replay_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case retention
        case retentionUntil = "retention_until"
        case archivedAt = "archived_at"
        case expiredAt = "expired_at"
        case summary
        case compressedAt = "compressed_at"
        case version
        case parentId = "parent_id"
    }
}

/// A ranked memory hit: the record plus its goal similarity (0..1).
struct MemoryHit: Decodable, Hashable {
    let record: ExecutionMemoryRecord
    let similarity: Double
}

/// One reason a confidence score is what it is (`ExplanationReason`).
struct ExplanationReason: Decodable, Hashable {
    let factor: String
    let impact: Double
    let description: String
}

/// Aggregate statistics about the memory store (`MemoryStats`).
struct MemoryStats: Decodable, Hashable {
    let totalRecords: Int
    let successful: Int
    let failed: Int
    let cancelled: Int
    let executions: Int
    let plannerReports: Int
    let autonomousSessions: Int
    let totalReplays: Int
    let learnedWorkflows: Int

    enum CodingKeys: String, CodingKey {
        case successful, failed, cancelled, executions
        case totalRecords = "total_records"
        case plannerReports = "planner_reports"
        case autonomousSessions = "autonomous_sessions"
        case totalReplays = "total_replays"
        case learnedWorkflows = "learned_workflows"
    }
}

// MARK: - Memory learning (RC-6 M3/M4)

/// One day of success history (`SuccessTrend`).
struct SuccessTrend: Decodable, Hashable {
    let date: String
    let successes: Int
    let failures: Int
    let successRate: Double

    enum CodingKeys: String, CodingKey {
        case date, successes, failures
        case successRate = "success_rate"
    }
}

/// Aggregate workflow quality metrics (`WorkflowQuality`).
struct WorkflowQuality: Decodable, Hashable {
    let workflowCount: Int
    let avgSuccessRate: Double
    let avgPlanConfidence: Double
    let avgDurationSeconds: Int
    let replayAdoptionRate: Double
    let replayPerRun: Double

    enum CodingKeys: String, CodingKey {
        case workflowCount = "workflow_count"
        case avgSuccessRate = "avg_success_rate"
        case avgPlanConfidence = "avg_plan_confidence"
        case avgDurationSeconds = "avg_duration_seconds"
        case replayAdoptionRate = "replay_adoption_rate"
        case replayPerRun = "replay_per_run"
    }
}

/// How well the memory store is being used (`MemoryUtilization`).
struct MemoryUtilization: Decodable, Hashable {
    let totalRecords: Int
    let activeRecords: Int
    let agingRecords: Int
    let archivedRecords: Int
    let avgFreshness: Double
    let utilizationRatio: Double
    let workflowsPerRecord: Double

    enum CodingKeys: String, CodingKey {
        case totalRecords = "total_records"
        case activeRecords = "active_records"
        case agingRecords = "aging_records"
        case archivedRecords = "archived_records"
        case avgFreshness = "avg_freshness"
        case utilizationRatio = "utilization_ratio"
        case workflowsPerRecord = "workflows_per_record"
    }
}

/// Learning health payload (`LearningHealth`) — how confident the system
/// is in its memories and how good its workflows are.
struct LearningHealth: Decodable, Hashable {
    let confidenceAverage: Double
    let confidenceSuccessful: Double
    let acceptanceRate: Double
    let workflowQuality: WorkflowQuality
    let successTrends: [SuccessTrend]
    let memoryUtilization: MemoryUtilization
    let scoreAverage: Double

    enum CodingKeys: String, CodingKey {
        case successTrends = "success_trends"
        case confidenceAverage = "confidence_average"
        case confidenceSuccessful = "confidence_successful"
        case acceptanceRate = "acceptance_rate"
        case workflowQuality = "workflow_quality"
        case memoryUtilization = "memory_utilization"
        case scoreAverage = "score_average"
    }
}

/// Fresh / aging / archived buckets (`MemoryAgingSummary`).
struct MemoryAgingSummary: Decodable, Hashable {
    let totalRecords: Int
    let freshRecords: Int
    let agingRecords: Int
    let archivedRecords: Int
    let avgFreshness: Double
    let oldestDays: Int
    let newestDays: Int

    enum CodingKeys: String, CodingKey {
        case totalRecords = "total_records"
        case freshRecords = "fresh_records"
        case agingRecords = "aging_records"
        case archivedRecords = "archived_records"
        case avgFreshness = "avg_freshness"
        case oldestDays = "oldest_days"
        case newestDays = "newest_days"
    }
}

/// A workflow learned from repeated executions (`LearnedWorkflow`).
struct LearnedWorkflow: Decodable, Hashable {
    let goalFingerprint: String
    let goal: String
    let successCount: Int
    let failureCount: Int
    let bestPlan: MemoryPlan?
    let lastSuccessAt: String?

    enum CodingKeys: String, CodingKey {
        case goal
        case goalFingerprint = "goal_fingerprint"
        case successCount = "success_count"
        case failureCount = "failure_count"
        case bestPlan = "best_plan"
        case lastSuccessAt = "last_success_at"
    }
}

/// A family of related workflows learned by clustering (`WorkflowFamily`).
struct WorkflowFamily: Decodable, Hashable {
    let familyId: Int
    let name: String
    let memberCount: Int
    let goals: [String]
    let sharedTools: [String]
    let totalSuccesses: Int
    let totalFailures: Int
    let avgDurationSeconds: Int
    let avgConfidence: Double

    enum CodingKeys: String, CodingKey {
        case name, goals
        case familyId = "family_id"
        case memberCount = "member_count"
        case sharedTools = "shared_tools"
        case totalSuccesses = "total_successes"
        case totalFailures = "total_failures"
        case avgDurationSeconds = "avg_duration_seconds"
        case avgConfidence = "avg_confidence"
    }
}

/// A detected failure pattern over remembered runs (`FailurePattern`).
struct FailurePattern: Decodable, Hashable {
    let patternType: FailurePatternType
    let goal: String
    let goalFingerprint: String
    let description: String
    let severity: Double
    let occurrences: Int
    let lastSeen: String
    let avgPlanConfidence: Double?

    enum CodingKeys: String, CodingKey {
        case goal, description, severity, occurrences
        case patternType = "pattern_type"
        case goalFingerprint = "goal_fingerprint"
        case lastSeen = "last_seen"
        case avgPlanConfidence = "avg_plan_confidence"
    }
}

/// Kinds of failure patterns (`FailurePatternType`, snake_case).
enum FailurePatternType: String, Decodable, Hashable {
    case repeatedFailure = "repeated_failure"
    case unstableWorkflow = "unstable_workflow"
    case lowConfidencePlan = "low_confidence_plan"

    var title: String {
        switch self {
        case .repeatedFailure: "Repeated failure"
        case .unstableWorkflow: "Unstable workflow"
        case .lowConfidencePlan: "Low-confidence plan"
        }
    }
}

/// Status of the vector index and embedding cache (`VectorIndexStatus`).
struct VectorIndexStatus: Decodable, Hashable {
    let totalRecords: Int
    let indexed: Int
    let pending: Int
    let provider: String
    let dimensions: Int
    let lastIndexedAt: String?
    let cacheSize: Int
    let cacheCapacity: Int
    let cacheHits: Int
    let cacheMisses: Int
    let cacheHitRate: Double

    enum CodingKeys: String, CodingKey {
        case provider, dimensions, pending, indexed
        case totalRecords = "total_records"
        case lastIndexedAt = "last_indexed_at"
        case cacheSize = "cache_size"
        case cacheCapacity = "cache_capacity"
        case cacheHits = "cache_hits"
        case cacheMisses = "cache_misses"
        case cacheHitRate = "cache_hit_rate"
    }
}

/// Outcome of an index pass (`IndexResult`).
struct IndexResult: Decodable, Hashable {
    let requested: Int
    let indexed: Int
    let failed: Int
    let skipped: Int
}

/// Outcome of one cleanup pass (`CleanupReport`).
struct CleanupReport: Decodable, Hashable {
    let expiredMarked: Int
    let removedExpired: Int
    let removedDuplicateArchives: Int
    let removedOrphanedVectors: Int
    let compressed: Int
    let ranAt: String

    enum CodingKeys: String, CodingKey {
        case compressed
        case expiredMarked = "expired_marked"
        case removedExpired = "removed_expired"
        case removedDuplicateArchives = "removed_duplicate_archives"
        case removedOrphanedVectors = "removed_orphaned_vectors"
        case ranAt = "ran_at"
    }
}

/// Storage statistics (`MemoryStorageStats`).
struct MemoryStorageStats: Decodable, Hashable {
    let databaseSizeBytes: Int
    let vectorIndexSizeBytes: Int
    let cacheEntries: Int
    let cacheSizeBytes: Int
    let cacheCapacity: Int
    let cacheOccupancy: Int
    let archivedMemories: Int
    let expiredMemories: Int
    let temporaryMemories: Int
    let permanentMemories: Int
    let snapshots: Int
    let snapshotSizeBytes: Int
    let compressedRecords: Int
    let compressionArchiveCount: Int

    enum CodingKeys: String, CodingKey {
        case snapshots
        case databaseSizeBytes = "database_size_bytes"
        case vectorIndexSizeBytes = "vector_index_size_bytes"
        case cacheEntries = "cache_entries"
        case cacheSizeBytes = "cache_size_bytes"
        case cacheCapacity = "cache_capacity"
        case cacheOccupancy = "cache_occupancy"
        case archivedMemories = "archived_memories"
        case expiredMemories = "expired_memories"
        case temporaryMemories = "temporary_memories"
        case permanentMemories = "permanent_memories"
        case snapshotSizeBytes = "snapshot_size_bytes"
        case compressedRecords = "compressed_records"
        case compressionArchiveCount = "compression_archive_count"
    }
}

/// One node in a memory lineage (`LineageNode`).
struct LineageNode: Decodable, Hashable {
    let id: String
    let goal: String
    let status: MemoryStatus
    let retention: RetentionPolicy
    let version: Int
    let createdAt: String
    let relation: LineageRelation?

    enum CodingKeys: String, CodingKey {
        case id, goal, status, retention, version
        case createdAt = "created_at"
        case relation
    }
}

/// How one lineage edge relates its two memories (`LineageRelation`).
enum LineageRelation: String, Decodable, Hashable {
    case parent
    case merged
}

/// The full lineage of one memory (`MemoryLineage`).
struct MemoryLineage: Decodable, Hashable {
    let memoryId: String
    let rootId: String?
    let version: Int
    let ancestors: [LineageNode]
    let children: [LineageNode]
    let mergedInto: [LineageNode]
    let mergedIntoId: String?

    enum CodingKeys: String, CodingKey {
        case version, ancestors, children
        case memoryId = "memory_id"
        case rootId = "root_id"
        case mergedInto = "merged_into"
        case mergedIntoId = "merged_into_id"
    }
}

// MARK: - Adaptive learning

/// A personal preference learned from user behavior (`UserPreference`).
struct UserPreference: Decodable, Hashable {
    let id: String
    let preferenceType: PreferenceType
    let key: String
    let value: JSONValue
    let confidence: Double
    let evidenceCount: Int
    let lastUpdated: String

    enum CodingKeys: String, CodingKey {
        case id, key, value, confidence
        case preferenceType = "preference_type"
        case evidenceCount = "evidence_count"
        case lastUpdated = "last_updated"
    }
}

/// Type of preference (`PreferenceType`, snake_case).
enum PreferenceType: String, Decodable, Hashable {
    case workspaceSwitching = "workspace_switching"
    case fileAccess = "file_access"
    case timeOfDay = "time_of_day"
    case technology
    case recommendationCategory = "recommendation_category"
    case workflow

    var title: String {
        switch self {
        case .workspaceSwitching: "Workspace switching"
        case .fileAccess: "File access"
        case .timeOfDay: "Time of day"
        case .technology: "Technology"
        case .recommendationCategory: "Recommendation category"
        case .workflow: "Workflow"
        }
    }
}

/// A behavioral pattern learned from history (`BehavioralPattern`).
struct BehavioralPattern: Decodable, Hashable {
    let id: String
    let patternType: PatternType
    let description: String
    let conditions: JSONValue
    let frequency: Double
    let confidence: Double
    let occurrences: Int
    let firstSeen: String
    let lastSeen: String

    enum CodingKeys: String, CodingKey {
        case id, description, conditions, frequency, confidence, occurrences
        case patternType = "pattern_type"
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
    }
}

/// Type of behavioral pattern (`PatternType`, snake_case).
enum PatternType: String, Decodable, Hashable {
    case sequentialFiles = "sequential_files"
    case workspaceSwitching = "workspace_switching"
    case timeBased = "time_based"
    case workflowTransition = "workflow_transition"
    case focusSession = "focus_session"

    var title: String {
        switch self {
        case .sequentialFiles: "Sequential files"
        case .workspaceSwitching: "Workspace switching"
        case .timeBased: "Time based"
        case .workflowTransition: "Workflow transition"
        case .focusSession: "Focus session"
        }
    }
}

/// Confidence trend over time (`ConfidenceTrend`).
struct ConfidenceTrend: Decodable, Hashable {
    let date: String
    let avgConfidence: Double
    let adjustmentCount: Int

    enum CodingKeys: String, CodingKey {
        case date
        case avgConfidence = "avg_confidence"
        case adjustmentCount = "adjustment_count"
    }
}

/// Accuracy per recommendation category (`CategoryAccuracy`).
struct CategoryAccuracy: Decodable, Hashable {
    let category: String
    let accuracy: Double
    let total: Int
    let accepted: Int
}

/// Recommendation accuracy metrics (`RecommendationAccuracy`).
struct RecommendationAccuracy: Decodable, Hashable {
    let categoryAccuracy: [CategoryAccuracy]
    let overallAccuracy: Double
    let totalRecommendations: Int

    enum CodingKeys: String, CodingKey {
        case overallAccuracy = "overall_accuracy"
        case categoryAccuracy = "category_accuracy"
        case totalRecommendations = "total_recommendations"
    }
}

/// Learning statistics and metrics (`LearningStats`).
struct LearningStats: Decodable, Hashable {
    let totalFeedbackCount: Int
    let acceptedCount: Int
    let rejectedCount: Int
    let acceptanceRate: Double
    let totalPreferences: Int
    let totalPatterns: Int
    let avgConfidenceAdjustment: Double
    let lastLearningUpdate: String

    enum CodingKeys: String, CodingKey {
        case acceptanceRate = "acceptance_rate"
        case totalFeedbackCount = "total_feedback_count"
        case acceptedCount = "accepted_count"
        case rejectedCount = "rejected_count"
        case totalPreferences = "total_preferences"
        case totalPatterns = "total_patterns"
        case avgConfidenceAdjustment = "avg_confidence_adjustment"
        case lastLearningUpdate = "last_learning_update"
    }
}

/// Learning insights for the dashboard (`LearningInsights`).
struct LearningInsights: Decodable, Hashable {
    let stats: LearningStats
    let topPreferences: [UserPreference]
    let recentPatterns: [BehavioralPattern]
    let confidenceTrends: [ConfidenceTrend]
    let recommendationAccuracy: RecommendationAccuracy

    enum CodingKeys: String, CodingKey {
        case stats
        case topPreferences = "top_preferences"
        case recentPatterns = "recent_patterns"
        case confidenceTrends = "confidence_trends"
        case recommendationAccuracy = "recommendation_accuracy"
    }
}

// MARK: - Dashboard intelligence

/// What the predictive engine expects to happen next (`get_predictions_summary`).
struct PredictionsSummary: Decodable, Hashable {
    let nextWorkspace: WorkspacePrediction?
    let nextFiles: [FilePrediction]
    let nextActions: [ActionPrediction]
    let sessionContinuation: SessionContinuationPrediction?

    enum CodingKeys: String, CodingKey {
        case nextWorkspace
        case nextFiles
        case nextActions
        case sessionContinuation
    }
}

struct WorkspacePrediction: Decodable, Hashable {
    let workspaceId: String
    let workspaceName: String
    let confidence: Double
    let reason: String
    let predictedAt: String

    enum CodingKeys: String, CodingKey {
        case workspaceId
        case workspaceName
        case confidence
        case reason
        case predictedAt
    }
}

struct FilePrediction: Decodable, Hashable, Identifiable {
    let filePath: String
    let workspaceId: String
    let confidence: Double
    let reason: String

    var id: String { filePath }

    enum CodingKeys: String, CodingKey {
        case filePath
        case workspaceId
        case confidence
        case reason
    }
}

struct ActionPrediction: Decodable, Hashable, Identifiable {
    let actionType: String
    let description: String
    let confidence: Double
    let reason: String

    var id: String { "\(actionType):\(description)" }

    enum CodingKeys: String, CodingKey {
        case actionType
        case description
        case confidence
        case reason
    }
}

struct SessionContinuationPrediction: Decodable, Hashable {
    let willContinue: Bool
    let confidence: Double
    let estimatedDurationSeconds: Int
    let reason: String

    enum CodingKeys: String, CodingKey {
        case willContinue
        case confidence
        case estimatedDurationSeconds
        case reason
    }
}

/// One actionable recommendation (`get_workspace_recommendations`). The
/// backend's `action` payload is an internally-tagged enum; the dashboard
/// only needs the decision fields, so `action` is intentionally ignored.
struct Recommendation: Decodable, Identifiable, Hashable {
    let id: String
    let workspaceId: String
    let category: String
    let priority: String
    let title: String
    let description: String
    let confidence: Double
    let impact: Double
    let effort: Double
    let generatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, category, priority, title, description, confidence, impact, effort
        case workspaceId = "workspace_id"
        case generatedAt = "generated_at"
    }
}

/// What a workspace looked like when the user last left it
/// (`copilot_get_resume_context`).
struct ResumeContext: Decodable, Hashable {
    let workspaceId: String
    let lastActive: String
    let unfinishedWork: [UnfinishedWork]
    let openFiles: [String]
    let activeBranch: String?
    let previousConversationId: String?

    enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case lastActive = "last_active"
        case unfinishedWork = "unfinished_work"
        case openFiles = "open_files"
        case activeBranch = "active_branch"
        case previousConversationId = "previous_conversation_id"
    }
}

struct UnfinishedWork: Decodable, Hashable, Identifiable {
    let description: String
    let filePath: String?
    let detectedAt: String
    let confidence: Double

    var id: String { "\(description):\(filePath ?? "")" }

    enum CodingKeys: String, CodingKey {
        case description
        case filePath = "file_path"
        case detectedAt = "detected_at"
        case confidence
    }
}

/// Corrected mirror of the backend `RuntimeHealth` (`get_runtime_health`).
/// The Rust struct serializes camelCase, and `status` is the enum string
/// `Healthy` / `Degraded` / `Unhealthy`.
struct RuntimeHealth: Decodable, Hashable {
    let status: String
    let workersActive: Int
    let cacheHitRate: Double
    let eventThroughput: Int
    let uptimeSeconds: Int
    let components: [RuntimeComponentMetrics]
    let checkedAt: String

    var isHealthy: Bool { status.lowercased() == "healthy" }
}

struct RuntimeComponentMetrics: Decodable, Hashable, Identifiable {
    let name: String
    let status: String
    let lastExecution: String?
    let executionCount: Int
    let errorCount: Int
    let avgExecutionTimeMs: Double

    var id: String { name }

    var isHealthy: Bool { status.lowercased() == "healthy" }
}

// MARK: - Maintenance (RC-10 M3)

/// Mirrors the backend `BackupRun` ledger row (`maintenance_backups`).
/// `kind` / `status` stay strings — the view only compares them against
/// the snake_case enum values the backend serializes.
struct BackupRun: Decodable, Hashable, Identifiable {
    let id: Int64
    let kind: String
    let status: String
    let path: String
    let sizeBytes: Int64
    let checksum: String
    let detail: String
    let durationMs: Int64
    let startedAt: String
    let completedAt: String
}

/// One parsed PRAGMA verdict (`integrity_check` / `quick_check`).
struct IntegrityLines: Decodable, Hashable {
    let ok: Bool
    let lines: [String]
}

/// The full PRAGMA battery for one database file.
struct IntegrityChecks: Decodable, Hashable {
    let databaseSizeBytes: Int64
    let pageCount: Int64
    let pageSize: Int64
    let freelistCount: Int64
    let journalMode: String
    let integrity: IntegrityLines
    let quickCheck: IntegrityLines
    let foreignKeyCheck: [String]
}

/// Complete integrity report (`maintenance_integrity`).
struct IntegrityReport: Decodable, Hashable {
    let checkedAt: String
    let dbPath: String
    let main: IntegrityChecks
    let ok: Bool
}

/// Result of a staged restore (`maintenance_restore`,
/// `maintenance_pending_restore`). The swap happens on next launch.
struct RestoreResult: Decodable, Hashable {
    let ok: Bool
    let message: String
    let backupPath: String
    let stagedPath: String
    let appliesOnNextLaunch: Bool
    let validated: IntegrityChecks
}

/// Result of a maintenance pass (`maintenance_optimize`).
struct MaintenanceReport: Decodable, Hashable {
    let checkedAt: String
    let freelistBefore: Int64
    let freelistAfter: Int64
    let freedPages: Int64
    let sizeBeforeBytes: Int64
    let sizeAfterBytes: Int64
    let recoveredBytes: Int64
    let vacuumRan: Bool
    let checkpointedFrames: Int64
}

// MARK: - Performance (RC-10 M1)

/// Per-operation profiler aggregate (`performance_profile`).
struct ProfileAggregate: Decodable, Hashable, Identifiable {
    let category: String
    let name: String
    let count: UInt64
    let avgMs: Double
    let minMs: UInt64
    let maxMs: UInt64
    let p95Ms: Double

    var id: String { "\(category):\(name)" }
}

/// One measured operation sample.
struct ProfileSample: Decodable, Hashable, Identifiable {
    let id: Int64
    let category: String
    let name: String
    let durationMs: UInt64
    let metadata: JSONValue?
    let occurredAt: String
}

/// Point-in-time profiler view.
struct ProfileSnapshot: Decodable, Hashable {
    let capturedAt: String
    let aggregates: [ProfileAggregate]
    let recent: [ProfileSample]
    let slowest: [ProfileSample]
}

/// One timed startup phase.
struct StartupStage: Decodable, Hashable, Identifiable {
    let name: String
    let label: String
    let durationMs: UInt64
    let startedAt: String

    var id: String { name }
}

/// Full report of one application launch (`performance_startup`).
struct StartupProfile: Decodable, Hashable {
    let runId: String
    let totalMs: UInt64
    let stages: [StartupStage]
    let recordedAt: String
}

/// One measured micro-benchmark within a suite run.
struct BenchmarkResult: Decodable, Hashable, Identifiable {
    let id: Int64
    let name: String
    let operation: String
    let category: String
    let iterations: UInt32
    let durationMs: UInt64
    let throughputPerSec: Double?
    let ok: Bool
    let payload: JSONValue?
    let createdAt: String
}

/// Result of running one or more benchmark suites (`performance_benchmark`).
struct BenchmarkSuiteResult: Decodable, Hashable {
    let suiteName: String
    let benchmarks: [BenchmarkResult]
    let totalDurationMs: UInt64
    let ranAt: String
}

struct CpuUsage: Decodable, Hashable {
    let usagePercent: Double
    let cores: Int
    let cpuParallelism: Int
}

struct MemoryUsage: Decodable, Hashable {
    let totalBytes: UInt64
    let usedBytes: UInt64
    let percent: Double
}

struct DbUsage: Decodable, Hashable {
    let sizeBytes: UInt64
    let path: String
}

struct CacheUsage: Decodable, Hashable {
    let runtimeEntries: Int
    let runtimeHitRate: Double
    let graphCacheEntries: UInt64
    let graphCacheSizeBytes: UInt64
}

/// One background worker's observable state.
struct WorkerInfo: Decodable, Hashable, Identifiable {
    let name: String
    let status: String
    let executionCount: UInt64
    let errorCount: UInt64
    let avgExecutionTimeMs: Double
    let lastExecution: String?

    var id: String { name }
}

struct ThreadUsage: Decodable, Hashable {
    let totalThreads: Int
    let processCount: Int
}

/// Whole-application + machine snapshot (`performance_diagnostics`).
struct DiagnosticsSnapshot: Decodable, Hashable {
    let capturedAt: String
    let cpu: CpuUsage
    let memory: MemoryUsage
    let db: DbUsage
    let cache: CacheUsage
    let workers: [WorkerInfo]
    let threads: ThreadUsage
}

/// One actionable finding from the optimizer analysis.
struct OptimizationRecommendation: Decodable, Hashable, Identifiable {
    let id: String
    let category: String
    /// `info` | `warning` | `critical`.
    let severity: String
    let title: String
    let detail: String
    /// The safe remediation to apply, when one exists (enum or
    /// externally-tagged map on the backend).
    let action: JSONValue?
}

/// Output of an optimizer run (`performance_optimize`).
struct OptimizeResult: Decodable, Hashable {
    let recommendations: [OptimizationRecommendation]
    /// Recommendation ids whose action was applied.
    let applied: [String]
    let analyzedAt: String
}

/// Combined recent history (`performance_history`).
struct PerformanceHistory: Decodable, Hashable {
    let profiles: [ProfileSample]
    let benchmarks: [BenchmarkResult]
    let startups: [StartupProfile]
}

// MARK: - Recovery (RC-10 M2)

/// One append-only reliability event.
struct RecoveryJournalEntry: Decodable, Hashable, Identifiable {
    let id: Int64
    /// snake_case enum string (`checkpoint`, `heartbeat`, …).
    let entryType: String
    let scope: String
    let entity: String
    let state: String
    let payload: JSONValue?
    let checksum: String
    let createdAt: String
}

/// One detected crash.
struct CrashReport: Decodable, Hashable, Identifiable {
    let id: Int64
    let component: String
    /// snake_case enum string (`panic`, `timeout`, …).
    let crashType: String
    /// `error` | `critical`.
    let severity: String
    let message: String
    let stackTrace: String
    let metadata: JSONValue?
    let wasRecovered: Bool
    let recoveredAt: String?
    let reportedAt: String
}

/// One monitored worker's persisted health row.
struct WorkerHealth: Decodable, Hashable, Identifiable {
    let id: Int64
    let worker: String
    /// snake_case enum string (`healthy`, `stalled`, …).
    let status: String
    let lastHeartbeat: String
    let consecutiveMisses: UInt64
    let executionCount: UInt64
    let errorCount: UInt64
    let lastError: String
    let details: JSONValue?
    let updatedAt: String
}

/// Point-in-time aggregate health view (`recovery_status`).
struct HealthSnapshot: Decodable, Hashable {
    let capturedAt: String
    let status: String
    /// `0..=100`, derived from worker liveness.
    let overallScore: Double
    let workers: [WorkerHealth]
    let issues: [String]
    let details: JSONValue?
}

/// One completed recovery run (audit row).
struct RecoveryRun: Decodable, Hashable, Identifiable {
    let id: Int64
    let runId: String
    let trigger: String
    let outcome: String
    /// `success` | `partial` | `failed`.
    let status: String
    let actions: [String]
    let recoveredJobs: [String]
    let rolledBackTo: Int64?
    let errors: [String]
    let durationMs: UInt64
    let startedAt: String
    let completedAt: String
}

/// Result of a rollback operation (`recovery_rollback`).
struct RollbackResult: Decodable, Hashable {
    let rolledBackTo: Int64?
    let restored: [String]
    let ok: Bool
    let message: String
}

/// Combined history for the recovery surface (`recovery_history`).
struct RecoveryHistory: Decodable, Hashable {
    let runs: [RecoveryRun]
    let crashes: [CrashReport]
    let journal: [RecoveryJournalEntry]
}

/// What the self-healing service did on one pass (`recovery_self_heal`).
struct SelfHealingReport: Decodable, Hashable {
    let executed: [String]
    let failed: [String]
    let healedWorkers: [String]
    let ranAt: String
}

// MARK: - Smart resume sessions

/// Mirror of the backend `SessionSummary` (`get_smart_resume_session`) —
/// the most recent working session, used to drive "Resume last session".
struct SessionSummary: Decodable, Hashable {
    let workspaceId: String
    let workspaceName: String
    let startedAt: String
    let endedAt: String
    let durationSeconds: Int
    let fileCount: Int
    let languages: [String]
    let productivityScore: Double
    let scoreFactors: [SessionScoreFactor]
    let recentEvents: [SessionEventSummary]
}

struct SessionScoreFactor: Decodable, Hashable {
    let name: String
    let weight: Double
    let value: Double
    let reason: String
}

struct SessionEventSummary: Decodable, Hashable {
    let occurredAt: String
    let eventType: String
    let fileName: String?
    let description: String
}

// MARK: - Daily briefing (analytics)

/// Mirror of the backend `ActivitySummary`.
struct ActivitySummary: Decodable, Hashable {
    let timeRange: String
    let durationSeconds: Int
    let sessionCount: Int
    let workspaceCount: Int
    let fileCount: Int64
    let editCount: Int64
    let commitCount: Int64
    let primaryLanguage: String?
}

/// Mirror of the backend `WorkspaceDaySummary`.
struct WorkspaceDaySummary: Decodable, Hashable {
    let workspaceId: String
    let workspaceName: String
    let durationSeconds: Int
    let sessionCount: Int
    let editCount: Int64
}

/// Mirror of the backend `DailyBriefing` (`get_daily_briefing`).
struct DailyBriefing: Decodable, Hashable {
    let greeting: String
    let summary: ActivitySummary
    let mostActiveWorkspace: WorkspaceDaySummary?
    let longestFocusSession: Int?
    let primaryLanguage: String?
    let insights: [String]
    let suggestions: [String]
}

// MARK: - Recommendation explanation (semantic reasoning)

/// Mirror of the backend `Evidence` supporting a prediction.
struct ExplanationEvidence: Decodable, Hashable, Identifiable {
    let source: String
    let description: String
    let confidence: Double
    let data: JSONValue?

    var id: String { "\(source):\(description)" }
}

/// Mirror of the backend `ExplainablePrediction`
/// (`explain_recommendation`).
struct ExplainablePrediction: Decodable, Hashable {
    let predictionType: String
    let value: JSONValue?
    let confidence: Double
    let explanation: String
    let supportingEvidence: [ExplanationEvidence]
    let sourceEngines: [String]
    let relatedDocuments: [String]
    let createdAt: String
}

// MARK: - Proactive notifications

/// Mirror of the backend `ProactiveNotification` — delivered live as a
/// `proactive:notification` daemon event.
struct ProactiveNotificationPayload: Decodable, Hashable, Identifiable {
    let id: String
    let workspaceId: String?
    /// snake_case enum string (`resume_work`, `unfinished_work`, …).
    let notificationType: String
    let title: String
    let message: String
    /// lowercase enum string (`low`, `medium`, `high`, `critical`).
    let priority: String
    let suggestedActions: [String]
    let dismissible: Bool
    let dismissed: Bool
    let createdAt: String

    var isHighPriority: Bool { priority == "high" || priority == "critical" }
}

// MARK: - Workspace health (intelligence)

/// Mirror of the backend `HealthMetric`.
struct HealthMetric: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    let value: Double
    let idealValue: Double?
    let unit: String
}

/// Mirror of the backend `HealthFactor`.
struct HealthFactor: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    let description: String
    /// 0.0 – 1.0.
    let score: Double
    let weight: Double
    let metrics: [HealthMetric]
}

/// Mirror of the backend `WorkspaceHealth`
/// (`get_workspace_health`; history returns the same type per day).
struct WorkspaceHealthReport: Decodable, Hashable, Identifiable {
    let workspaceId: String
    /// 0.0 – 1.0, where 1.0 is healthiest.
    let overallScore: Double
    let factors: [HealthFactor]
    let calculatedAt: String
    /// Trend vs previous assessment (positive = improving).
    let trend: Double?

    var id: String { calculatedAt }
}

// MARK: - Utility

extension String {
    /// ISO-8601 date as serialized by chrono (RFC 3339). Chrono omits the
    /// fractional part when sub-second precision is zero (`AutoSi`), so a
    /// non-fractional fallback keeps whole-second timestamps parseable.
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatterWholeSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    var isoDate: Date? {
        String.isoFormatter.date(from: self)
            ?? String.isoFormatterWholeSeconds.date(from: self)
    }

    var relativeTime: String {
        guard let date = isoDate else { return self }
        return date.formatted(.relative(presentation: .named))
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    /// Extracts a string member from a raw JSON payload (e.g. the `path`
    /// in a timeline event's `metadata`).
    func string(_ key: String) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        return value
    }
}

extension Date {
    var isoString: String {
        ISO8601DateFormatter().string(from: self)
    }
}