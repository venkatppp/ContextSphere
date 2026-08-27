import Foundation
import CoreGraphics

/// Summary struct matching the Rust `GraphSyncSummary` for decoding
/// `graph:updated` event payloads from the daemon.
private struct GraphSyncSummary: Decodable {
    let createdNodes: Int
    let updatedNodes: Int
    let createdEdges: Int
    let updatedEdges: Int
    let totalNodes: Int
    let totalEdges: Int
}

/// State and data flow for the Context Graph screen.
///
/// Follows the established architecture: `GraphView` observes this model;
/// the model talks to the Rust core exclusively through `CoreBridge`
/// (JSON-RPC) using the existing `get_graph`, `graph_search` and
/// `graph_subgraph` APIs. Layout runs off the main thread; the graph
/// itself is bounded by the backend (subgraph extraction caps at 100
/// nodes, depth at 4 hops).
@MainActor
final class GraphViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Edge-density filter for the canvas.
    enum EdgeDensity: String, CaseIterable, Identifiable {
        case all, strong
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All relationships"
            case .strong: "Strong only"
            }
        }
    }

    private static let subgraphDepth = 2
    private static let searchLimit: UInt32 = 20
    /// Whole-graph render budget: nodes fetched for the unfiltered view.
    /// Layout, hit testing and Canvas all stay O(caps), never O(store).
    private static let wholeGraphNodeCap: UInt32 = 400
    private static let wholeGraphEdgeCap: UInt32 = 1_200

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var nodes: [KgNode] = []
    @Published private(set) var edges: [KgEdge] = []
    @Published private(set) var lastError: String?
    @Published var selectedNodeID: String?
    @Published var showInspector = false
    @Published var edgeDensity: EdgeDensity = .all

    // MARK: - Context field (prompt §6, §14)

    /// Focus node for the "Context Field" — when set, the graph reorganizes
    /// radially around it and unrelated regions are de-emphasized. `nil` =
    /// global/clustered view.
    @Published var contextFocusID: String?
    @Published var isUsingFixture = false
    /// Whole-graph loads are bounded; when the store exceeds the caps the
    /// status bar says so instead of silently dropping data.
    @Published private(set) var isTruncated = false
    @Published private(set) var totalNodeCount = 0
    /// Last layout pass duration in ms (for the debug overlay / benchmarks).
    @Published private(set) var lastLayoutDurationMs: Double = 0

    /// Relevance field — normalized 0…1 per node, inspectable via breakdowns.
    /// Computed from focus, distance, importance, temporal, workspace, semantic.
    /// O(n+m), updated on graph/focus/workspace changes; small temporal bumps
    /// only affect visual hierarchy, not layout, to preserve mental map.
    @Published private(set) var relevanceScores: [String: Double] = [:]
    @Published private(set) var relevanceBreakdowns: [String: GraphRelevance.Breakdown] = [:]
    var relevanceProfile: GraphRelevance.Profile = .hybrid
    /// Semantic scores from existing retrieval (graph_vector_search → ranked fallback).
    /// 0…1 per nodeID; empty = no semantic signal. Populated once per
    /// focus/search change (bounded top-K 20, cached), not per node → no O(n²).
    private var semanticScores: [String: Double] = [:]
    private var semanticTask: Task<Void, Never>?
    private var lastSemanticQuery: String?

    /// Adapter: current daemon data → visual model without DB migration (prompt §17).
    var visualizationModel: GraphVisualizationModel {
        GraphVisualizationModel.fromDaemon(nodes: nodes, edges: edges)
    }

    /// Inspectable normalized relevance 0…1 for a node (for inspector/debug).
    func relevance(for nodeID: String) -> Double { relevanceScores[nodeID] ?? 0 }
    func relevanceBreakdown(for nodeID: String) -> GraphRelevance.Breakdown? { relevanceBreakdowns[nodeID] }

    /// Recomputes relevance scores O(n+m). Call on focus/workspace/graph changes.
    /// Small temporal bumps only update scores (visual hierarchy) without
    /// triggering a full relayout, preserving mental map.
    private func computeRelevance() {
        let result = GraphRelevance.compute(
            model: visualizationModel,
            focusID: contextFocusID ?? focusedNodeID,
            activeWorkspaceID: selectedWorkspaceId,
            semanticScores: semanticScores,
            profile: relevanceProfile)
        relevanceScores = result.scores
        relevanceBreakdowns = result.breakdowns
    }

    // MARK: - Semantic adapter (existing retrieval → relevance)

    /// Fetches semantic scores for a free-text query via the daemon's existing
    /// vector/FTS stack (graph_vector_search, threshold 0.20, top 20). Cached
    /// per query, debounced 220 ms, bounded — never O(n²).
    private func fetchSemantic(for query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            semanticScores = [:]
            computeRelevance()
            return
        }
        guard trimmed != lastSemanticQuery else { return }
        lastSemanticQuery = trimmed
        semanticTask?.cancel()
        semanticTask = Task {
            // Debounce: coalesce rapid focus/search changes.
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            let scores = await GraphSemanticAdapter.fetchScores(for: trimmed)
            guard !Task.isCancelled else { return }
            self.semanticScores = scores
            self.computeRelevance()
            // Semantic affects layout as a gentle field bias; nudge positions
            // incrementally without destroying cluster structure.
            if self.contextFocusID != nil || self.focusedNodeID != nil {
                self.relayout(anchorID: self.contextFocusID ?? self.focusedNodeID, incremental: true)
            }
        }
    }

    /// Focus-driven semantic context: uses focused entity's title/summary as query.
    /// Example: focus = GraphRenderer.swift → semantically near GraphLayout.swift,
    /// GraphCamera.swift, Canvas, Metal. Only one RPC per focus change, top 20.
    private func fetchSemanticForFocus(_ focusID: String?) {
        guard let focusID, let node = registry[focusID] ?? nodes.first(where: { $0.id == focusID }) else {
            // No focus → clear semantic scores so field falls back to
            // structural/temporal/workspace only; still visible but not central.
            semanticScores = [:]
            lastSemanticQuery = nil
            computeRelevance()
            return
        }
        // Build query from node's title (+ summary prefix). This reuses
        // existing embeddings (node titles were embedded at index time) — no
        // new embedding system, no DB change. Disconnected semantic matches
        // remain projection-level relevance (no permanent edge).
        let query = node.title + (node.summary.map { " " + String($0.prefix(80)) } ?? "")
        fetchSemantic(for: query)
    }

    // Search (graph_search)
    @Published var searchQuery = ""
    @Published private(set) var searchResults: [KgNode] = []
    @Published private(set) var isSearching = false
    @Published private(set) var searchError: String?
    /// Node to highlight after a search pick; increments to retrigger the
    /// view's focus animation.
    @Published private(set) var focusNonce = 0
    @Published private(set) var focusedNodeID: String?

    @Published private(set) var isExpanding = false

    /// Workspace context (the "current workspace" of the app). `nil`
    /// means the whole graph.
    @Published var selectedWorkspaceId: String?

    /// Layout positions in world coordinates (stable node identity).
    @Published private(set) var positions: [String: CGPoint] = [:]
    /// Incremented after every layout pass so the view can refit/refresh.
    @Published private(set) var layoutGeneration = 0

    private(set) var workspaces: [Workspace] = []
    private var registry: [String: KgNode] = [:]
    private var edgeSet: Set<String> = []
    private var loadTask: Task<Void, Never>?
    private var layoutTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var pendingFocus: (id: String, nonce: Int)?

    var selectedNode: KgNode? {
        guard let selectedNodeID else { return nil }
        return nodes.first { $0.id == selectedNodeID }
    }

    func workspaceName(for node: KgNode) -> String? {
        guard let workspaceId = node.workspaceId else { return nil }
        return workspaces.first { $0.id == workspaceId }?.name
    }

    /// Workspace display name; `nil` for the whole-graph view.
    var contextName: String? {
        guard let selectedWorkspaceId else { return nil }
        return workspaces.first { $0.id == selectedWorkspaceId }?.name
    }

    func workspaceName(id: String?) -> String? {
        guard let id else { return nil }
        return workspaces.first { $0.id == id }?.name
    }

    /// Constant-time node lookup by id (hit testing, focus, search merge).
    func node(for id: String) -> KgNode? { registry[id] }

    /// Relationships incident to a node (for the inspector).
    func relationships(for nodeID: String) -> [(KgNode, KgEdge)] {
        edges.compactMap { edge in
            if edge.sourceID == nodeID, let target = registry[edge.targetID] {
                return (target, edge)
            }
            if edge.targetID == nodeID, let source = registry[edge.sourceID] {
                return (source, edge)
            }
            return nil
        }
        .sorted { $0.1.weight > $1.1.weight }
    }

    var visibleEdges: [KgEdge] {
        switch edgeDensity {
        case .all: edges
        case .strong: edges.filter { $0.weight >= 0.5 }
        }
    }

    // MARK: - Configuration

    func setWorkspaces(_ workspaces: [Workspace]) {
        self.workspaces = workspaces
        let previous = selectedWorkspaceId
        if selectedWorkspaceId == nil
            || !workspaces.contains(where: { $0.id == selectedWorkspaceId }) {
            selectedWorkspaceId = workspaces.first(where: { $0.status == .active })?.id
                ?? workspaces.first?.id
        }
        // If workspace roster changed, clear stale focus/selection that no longer exists.
        let changed = previous != selectedWorkspaceId
        if changed {
            clearStaleSelectionIfNeeded()
            // Workspace context changed (e.g., active workspace switched externally or deleted) — reload graph
            // to reflect new context rather than leaving stale nodes/edges visible.
            if state != .idle {
                loadGraph()
            }
        } else if let focus = contextFocusID, registry[focus] == nil, nodes.first(where: { $0.id == focus }) == nil {
            // Workspace list unchanged but focused node may have been deleted elsewhere.
            // Keep the focus ID until next load verifies it; layout will handle missing gracefully.
        }
    }

    func selectWorkspace(_ id: String?) {
        guard id != selectedWorkspaceId else { return }
        // Switching context must not leave stale focus/selection from previous workspace.
        contextFocusID = nil
        focusedNodeID = nil
        selectedNodeID = nil
        pendingFocus = nil
        semanticScores = [:]
        lastSemanticQuery = nil
        semanticTask?.cancel()
        selectedWorkspaceId = id
        loadGraph()
    }

    /// Clears focus/selection that references nodes no longer in the registry
    /// (deleted workspace/file). Called after workspace roster changes.
    private func clearStaleSelectionIfNeeded() {
        if let focused = contextFocusID, registry[focused] == nil && nodes.first(where: { $0.id == focused }) == nil {
            contextFocusID = nil
            focusedNodeID = nil
        }
        if let selected = selectedNodeID, registry[selected] == nil && nodes.first(where: { $0.id == selected }) == nil {
            selectedNodeID = nil
            showInspector = false
        }
        semanticScores = [:]
        lastSemanticQuery = nil
    }

    /// Whether an error string indicates a missing KG node (stale/deleted ID).
    private func isNotFoundError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("was not found") || lower.contains("not found") || lower.contains("graph node with id")
    }

    // MARK: - Loading

    func initialLoadIfNeeded() {
        guard state == .idle else { return }
        loadGraph()
    }

    func refresh() {
        loadGraph()
    }

    func retry() {
        // Genuine retry: cancel any in-flight work, clear stale errors, reload.
        loadTask?.cancel()
        searchTask?.cancel()
        semanticTask?.cancel()
        lastError = nil
        searchError = nil
        loadGraph()
    }

    /// Loads the graph for the current workspace context:
    /// 1. `get_graph` (legacy node registry for the context).
    /// 2. `graph_subgraph` around the workspace node (the real RC-8
    ///    relationships), merged and deduplicated — but a missing KG node
    ///    must not fail the whole graph (stale/deleted IDs, unsynced workspace).
    /// With no workspace context, uses paged KG APIs with legacy fallback.
    private func loadGraph() {
        loadTask?.cancel()
        loadTask = Task {
            state = .loading
            lastError = nil
            searchResults = []
            searchQuery = ""
            searchError = nil
            do {
                if let workspaceID = selectedWorkspaceId {
                    try await loadWorkspaceGraph(workspaceID)
                } else {
                    try await loadWholeGraph()
                }
                // Validate focus/selection still exist after load; stale IDs are cleared, not fatal.
                if let focus = contextFocusID, registry[focus] == nil {
                    contextFocusID = nil
                    focusedNodeID = nil
                }
                if let sel = selectedNodeID, registry[sel] == nil {
                    selectedNodeID = nil
                    showInspector = false
                }
                isUsingFixture = false
                state = .loaded
                // Also clear lastError on success so stale "not found" doesn't linger.
                lastError = nil
                relayout(anchorID: workspaceNodeID)
            } catch {
                guard !Task.isCancelled else { return }
                let msg = error.localizedDescription
                // Distinguish genuine empty (handled as .loaded with 0 nodes) from transport/decode failures.
                // If the error is "not found" for a workspace node, treat as empty graph for that workspace
                // rather than a global failure — the legacy view already supplies nodes when available.
                if isNotFoundError(msg), selectedWorkspaceId != nil {
                    // Try legacy-only view as fallback: if we have any nodes from get_graph, show them.
                    if !nodes.isEmpty {
                        lastError = nil
                        state = .loaded
                        isUsingFixture = false
                        if let focus = contextFocusID, registry[focus] == nil {
                            contextFocusID = nil
                            focusedNodeID = nil
                        }
                        relayout(anchorID: workspaceNodeID)
                        return
                    }
                }
                lastError = msg
                state = .failed(msg)
            }
        }
    }

    private var workspaceNodeID: String? {
        guard let id = selectedWorkspaceId else { return nil }
        return "\(GraphNodeType.workspace.rawValue):\(id)"
    }

    private func loadWorkspaceGraph(_ workspaceID: String) async throws {
        registry.removeAll()
        edgeSet.removeAll()
        edges.removeAll()

        // 1. Legacy registry (`get_graph`). This must succeed; it is the source of truth
        //    for workspace/file aggregates even when the KG has not yet synced.
        let view: GraphView = try await CoreBridge.shared.request(
            "get_graph",
            params: ["workspace_id": workspaceID],
            as: GraphView.self)
        for legacyNode in view.nodes {
            registry[legacyNode.id] = legacyNode.toKgNode()
        }
        for legacyEdge in view.edges {
            mergeEdge(legacyEdge.toKgEdge())
        }

        // 2. RC-8 subgraph around the workspace node — best-effort. A missing KG node
        //    (workspace never synced, deleted, or pruned) must not crash the whole graph.
        do {
            let subgraph: KgSubgraph = try await CoreBridge.shared.request(
                "graph_subgraph",
                params: [
                    "node_type": GraphNodeType.workspace.rawValue,
                    "entity_id": workspaceID,
                    "depth": Self.subgraphDepth,
                ],
                as: KgSubgraph.self)
            mergeSubgraph(subgraph)
        } catch {
            let msg = error.localizedDescription
            if isNotFoundError(msg) {
                // KG workspace node missing — expected before first sync or after deletion.
                // Keep legacy nodes/edges; do not surface as a user-visible error.
                // Optionally trigger a background sync hint via lastError = nil.
            } else {
                // Non-not-found errors (transport/timeout) are surfaced subtly but do not
                // blank the graph when legacy data is available.
                lastError = msg
            }
        }
        nodes = registry.values.sorted {
            ($0.workspaceId ?? "", $0.title) < ($1.workspaceId ?? "", $1.title)
        }
        edges = edges.sorted { $0.weight > $1.weight }
        totalNodeCount = registry.count
        isTruncated = false
    }

    /// Loads the unfiltered view through the backend's paged APIs so the
    /// query itself stays bounded (`get_graph` with no workspace would
    /// return the entire store). Truncation is surfaced, never hidden.
    /// Paged requests are independent — a failure in one does not blank the other;
    /// an empty KG falls back to the legacy projection.
    private func loadWholeGraph() async throws {
        registry.removeAll()
        edgeSet.removeAll()
        edges.removeAll()

        var nodePage: GraphNodePage?
        var edgePage: GraphEdgePage?
        var nodeError: String?
        var edgeError: String?

        do {
            nodePage = try await CoreBridge.shared.request(
                "graph_nodes_page",
                params: ["limit": Self.wholeGraphNodeCap],
                as: GraphNodePage.self)
        } catch {
            nodeError = error.localizedDescription
        }
        do {
            edgePage = try await CoreBridge.shared.request(
                "graph_edges_page",
                params: ["limit": Self.wholeGraphEdgeCap],
                as: GraphEdgePage.self)
        } catch {
            edgeError = error.localizedDescription
        }

        // If both paged calls failed, fall back to legacy or throw.
        if nodePage == nil && edgePage == nil {
            if let msg = nodeError ?? edgeError {
                // If legacy fallback also fails, propagate the original error.
                let view: GraphView = try await CoreBridge.shared.request(
                    "get_graph", as: GraphView.self)
                for legacyNode in view.nodes {
                    registry[legacyNode.id] = legacyNode.toKgNode()
                }
                for legacyEdge in view.edges {
                    mergeEdge(legacyEdge.toKgEdge())
                }
                totalNodeCount = registry.count
                isTruncated = false
                if registry.isEmpty {
                    lastError = msg
                }
            } else {
                // Should not happen: both nil but no error captured.
                let view: GraphView = try await CoreBridge.shared.request(
                    "get_graph", as: GraphView.self)
                for legacyNode in view.nodes {
                    registry[legacyNode.id] = legacyNode.toKgNode()
                }
                for legacyEdge in view.edges {
                    mergeEdge(legacyEdge.toKgEdge())
                }
                totalNodeCount = registry.count
                isTruncated = false
            }
        } else if let page = nodePage, page.nodes.isEmpty {
            // Empty KG (nothing synced yet): fall back to the legacy
            // projection so first-run users still see their workspaces.
            let view: GraphView = try await CoreBridge.shared.request(
                "get_graph", as: GraphView.self)
            for legacyNode in view.nodes {
                registry[legacyNode.id] = legacyNode.toKgNode()
            }
            for legacyEdge in view.edges {
                mergeEdge(legacyEdge.toKgEdge())
            }
            isTruncated = false
            totalNodeCount = registry.count
            if let msg = edgeError { lastError = msg }
        } else {
            if let page = nodePage {
                totalNodeCount = page.total
                // Consistency check: total vs returned count + hasMore must align.
                isTruncated = page.hasMore || (edgePage?.hasMore ?? false)
                for kgNode in page.nodes {
                    registry[kgNode.id] = kgNode
                }
            }
            if let page = edgePage {
                if nodePage == nil {
                    totalNodeCount = registry.count
                    isTruncated = page.hasMore
                }
                for kgEdge in page.edges {
                    mergeEdge(kgEdge)
                }
            }
            // Surface non-fatal paged errors as subtle lastError, not a full failure.
            if let msg = nodeError ?? edgeError, !registry.isEmpty {
                lastError = msg
            } else if let msg = nodeError ?? edgeError, registry.isEmpty {
                throw NSError(domain: "Graph", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
            }
        }
        nodes = registry.values.sorted {
            ($0.workspaceId ?? "", $0.title) < ($1.workspaceId ?? "", $1.title)
        }
        edges = edges.sorted { $0.weight > $1.weight }
    }

    // MARK: - Expansion

    /// Expands the selected node's neighborhood via `graph_subgraph`,
    /// merging new nodes/edges without reloading the whole graph.
    func expandSelectedNode() {
        guard let node = selectedNode else { return }
        expand(node)
    }

    func expand(_ node: KgNode) {
        guard !isExpanding else { return }
        // Stale ID check before RPC: if node no longer in registry, clear selection.
        guard registry[node.id] != nil else {
            lastError = "That item no longer exists — it may have been deleted."
            if selectedNodeID == node.id { selectedNodeID = nil; showInspector = false }
            if contextFocusID == node.id { contextFocusID = nil; focusedNodeID = nil }
            return
        }
        isExpanding = true
        let anchorID = node.id
        Task {
            defer { isExpanding = false }
            do {
                let subgraph: KgSubgraph = try await CoreBridge.shared.request(
                    "graph_subgraph",
                    params: [
                        "node_type": node.nodeType.rawValue,
                        "entity_id": node.entityId,
                        "depth": Self.subgraphDepth,
                    ],
                    as: KgSubgraph.self)
                guard !Task.isCancelled else { return }
                mergeSubgraph(subgraph)
                nodes = registry.values.sorted {
                    ($0.workspaceId ?? "", $0.title) < ($1.workspaceId ?? "", $1.title)
                }
                edges = edges.sorted { $0.weight > $1.weight }
                lastError = nil
                relayout(anchorID: anchorID, incremental: true)
            } catch {
                let msg = error.localizedDescription
                if isNotFoundError(msg) {
                    // Stale/deleted node: prune it and clear focus if needed, don't fail whole graph.
                    registry.removeValue(forKey: node.id)
                    nodes = registry.values.filter { registry[$0.id] != nil }.sorted {
                        ($0.workspaceId ?? "", $0.title) < ($1.workspaceId ?? "", $1.title)
                    }
                    edges.removeAll { $0.sourceID == node.id || $0.targetID == node.id }
                    edgeSet = Set(edges.map(\.id))
                    if contextFocusID == node.id { contextFocusID = nil; focusedNodeID = nil }
                    if selectedNodeID == node.id { selectedNodeID = nil; showInspector = false }
                    lastError = "That item is no longer available — it may have been deleted or not yet synced."
                } else {
                    lastError = msg
                }
            }
        }
    }

    private func mergeSubgraph(_ subgraph: KgSubgraph) {
        mergeNode(subgraph.root)
        for node in subgraph.nodes { mergeNode(node) }
        for edge in subgraph.edges { mergeEdge(edge) }
    }

    private func mergeNode(_ node: KgNode) {
        if let existing = registry[node.id] {
            // Keep the richer title (never regress to an empty one).
            if existing.title.isEmpty && !node.title.isEmpty {
                registry[node.id] = node
            }
        } else {
            registry[node.id] = node
        }
    }

    private func mergeEdge(_ edge: KgEdge) {
        guard registry[edge.sourceID] != nil, registry[edge.targetID] != nil else { return }
        if edgeSet.insert(edge.id).inserted {
            edges.append(edge)
        }
    }

    // MARK: - Selection / Focus

    func selectNode(_ id: String?) {
        selectedNodeID = id
        if id != nil { showInspector = true }
    }

    /// Sets the Context Field focus. Triggers a radial relayout around the
    /// node and animates the camera via the view's `focusNonce`.
    /// Also fetches semantic neighbors (one vector query, top 20) for this
    /// focus so structurally disconnected but semantically related nodes can
    /// appear as temporary relevance (no permanent edge).
    func setContextFocus(_ id: String?) {
        guard contextFocusID != id else { return }
        contextFocusID = id
        if let id {
            focusedNodeID = id
            selectedNodeID = id
            showInspector = true
            focusNonce += 1
        }
        relayout(anchorID: id ?? workspaceNodeID, incremental: false, focusID: id)
        fetchSemanticForFocus(id)
    }

    func clearContextFocus() {
        contextFocusID = nil
        relayout(anchorID: workspaceNodeID, incremental: false, focusID: nil)
        fetchSemanticForFocus(nil)
    }

    /// Clears a transient inline warning (stale subgraph/edge) without reloading.
    func clearTransientError() {
        lastError = nil
    }

    func toggleContextFocus(_ id: String) {
        if contextFocusID == id { clearContextFocus() } else { setContextFocus(id) }
    }

    // MARK: - Search (graph_search)

    func submitSearch() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        // Semantic relevance for the query — bounded top-K, cached, no O(n²).
        // Uses existing graph_vector_search (cosine 0…1) with threshold 0.20;
        // missing → 0, never fakes scores.
        fetchSemantic(for: trimmed)
        searchTask?.cancel()
        searchTask = Task { await performSearch(trimmed) }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchQuery = ""
        searchResults = []
        searchError = nil
    }

    private func performSearch(_ query: String) async {
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        do {
            let results: [KgNode] = try await CoreBridge.shared.request(
                "graph_search",
                params: ["query": query, "limit": Self.searchLimit],
                as: [KgNode].self)
            guard !Task.isCancelled else { return }
            searchResults = results
        } catch {
            guard !Task.isCancelled else { return }
            searchError = error.localizedDescription
            searchResults = []
        }
    }

    /// Focuses the graph on a found entity: select it, center the view,
    /// and make sure it is part of the displayed graph (merging its
    /// subgraph if it is not already present).
    /// Search result temporarily becomes the Context Field focus and
    /// reorganizes the field around it without destroying graph state
    /// (nodes/edges preserved, only relevance-biased positions shift).
    func focusSearchResult(_ node: KgNode) {
        clearSearch()
        let isKnown = registry[node.id] != nil
        if !isKnown {
            mergeNode(node)
            nodes = registry.values.sorted {
                ($0.workspaceId ?? "", $0.title) < ($1.workspaceId ?? "", $1.title)
            }
        }
        // Reuse existing focus mechanism so relevance field, layout and
        // visual hierarchy all respond consistently.
        setContextFocus(node.id)
    }

    /// The view confirms it has animated to the requested focus.
    func consumeFocusRequest() {
        pendingFocus = nil
    }

    // MARK: - Live updates

    /// Entry point for daemon notifications routed by `AppShell`.
    /// Handles `timeline:event_added`, `graph:edge_added`, and `graph:updated`.
    func handle(event: String, payload: Data?) {
        guard let payload else { return }
        if event == "timeline:event_added" {
            handleTimelineEventAdded(payload)
        } else if event == "graph:edge_added" {
            handleGraphEdgeAdded(payload)
        } else if event == "graph:updated" {
            handleGraphUpdated(payload)
        }
    }

    private func handleTimelineEventAdded(_ payload: Data) {
        do {
            let timelineEvent = try JSONDecoder().decode(TimelineEvent.self, from: payload)
            guard let selectedWorkspaceId else { return }
            guard timelineEvent.workspaceId == selectedWorkspaceId else { return }

            // Map file ID to a KgNode; bump recency on every event so the graph
            // shows live activity without a full reload (prompt §17: in-memory projection).
            guard let fileId = timelineEvent.fileId else { return }
            let fileNodeId = "\(GraphNodeType.file.rawValue):\(fileId)"
            let ts = timelineEvent.occurredAt
            if var existing = registry[fileNodeId] {
                // Refresh recency — reuse existing title/metadata but stamp now.
                existing = KgNode(nodeType: existing.nodeType, entityId: existing.entityId,
                                  title: existing.title, workspaceId: existing.workspaceId,
                                  summary: existing.summary, metadata: existing.metadata,
                                  createdAt: existing.createdAt, updatedAt: ts)
                registry[fileNodeId] = existing
            } else {
                let fileNode = KgNode(
                    nodeType: .file,
                    entityId: fileId,
                    title: "File \(fileId)",
                    workspaceId: selectedWorkspaceId,
                    summary: nil,
                    metadata: .object([:]),
                    createdAt: ts,
                    updatedAt: ts)
                registry[fileNodeId] = fileNode
            }
            nodes = registry.values.sorted { ($0.workspaceId ?? "", $0.title) < ($1.workspaceId ?? "", $1.title) }

            // Emit a weak edge from the workspace node to this file (if workspace node exists).
            let workspaceNodeId = "\(GraphNodeType.workspace.rawValue):\(selectedWorkspaceId)"
            if registry[workspaceNodeId] != nil {
                let edgeId = "ws-\(selectedWorkspaceId)-file-\(fileId)"
                if edgeSet.insert(edgeId).inserted {
                    let newEdge = KgEdge(
                        id: edgeId,
                        sourceNodeType: .workspace,
                        sourceEntityId: selectedWorkspaceId,
                        targetNodeType: .file,
                        targetEntityId: fileId,
                        relationshipType: .relatedTo,
                        weight: 1.0,
                        confidence: 1.0,
                        metadata: .object([:]),
                        createdAt: ts,
                        updatedAt: ts)
                    edges.append(newEdge)
                }
            }

            recomputeLayoutIfNeeded()
        } catch {
            lastError = "Failed to decode timeline event: \(error.localizedDescription)"
        }
    }

    private func handleGraphEdgeAdded(_ payload: Data) {
        do {
            let jsonObject = try JSONSerialization.jsonObject(with: payload, options: [])
            guard let dictionary = jsonObject as? [String: Any],
                let sourceId = dictionary["sourceId"] as? String,
                let targetId = dictionary["targetId"] as? String,
                let weightValue = dictionary["weight"] as? Double
                else { return }

            // Ensure both nodes exist in registry - stamp as recent.
            let nowISO = ISO8601DateFormatter().string(from: Date())
            if registry[sourceId] == nil {
                let sourceNode = KgNode(
                    nodeType: .file,
                    entityId: sourceId,
                    title: sourceId,
                    workspaceId: selectedWorkspaceId ?? "",
                    summary: nil,
                    metadata: .object([:]),
                    createdAt: nowISO,
                    updatedAt: nowISO)
                registry[sourceId] = sourceNode
            }
            if registry[targetId] == nil {
                let targetNode = KgNode(
                    nodeType: .file,
                    entityId: targetId,
                    title: targetId,
                    workspaceId: selectedWorkspaceId ?? "",
                    summary: nil,
                    metadata: .object([:]),
                    createdAt: nowISO,
                    updatedAt: nowISO)
                registry[targetId] = targetNode
            }
            nodes = registry.values.sorted { ($0.workspaceId ?? "", $0.title) < ($1.workspaceId ?? "", $1.title) }

            let edgeId = "\(sourceId)-\(targetId)"
            if edgeSet.insert(edgeId).inserted {
                let newEdge = KgEdge(
                    id: edgeId,
                    sourceNodeType: sourceId.contains(":workspace") ? .workspace : .file,
                    sourceEntityId: sourceId.components(separatedBy: ":").last ?? sourceId,
                    targetNodeType: targetId.contains(":workspace") ? .workspace : .file,
                    targetEntityId: targetId.components(separatedBy: ":").last ?? targetId,
                    relationshipType: .relatedTo,
                    weight: weightValue,
                    confidence: 1.0,
                    metadata: .object([:]),
                    createdAt: nowISO,
                    updatedAt: nowISO)
                edges.append(newEdge)
            }

            recomputeLayoutIfNeeded()
        } catch {
            lastError = "Failed to decode graph edge added payload: \(error.localizedDescription)"
        }
    }

    private func handleGraphUpdated(_ payload: Data) {
        do {
            _ = try JSONDecoder().decode(GraphSyncSummary.self, from: payload)
            // Summary only has counts; trigger a full refresh so the graph
            // picks up any new nodes/edges that have appeared since the last sync.
            lastError = nil
            Task { @MainActor in
                self.refresh()
            }
        } catch {
            lastError = "Failed to decode graph update summary: \(error.localizedDescription)"
        }
    }

    private func recomputeLayoutIfNeeded() {
        guard !nodes.isEmpty else { return }
        // Small defer so the UI has consumed the new node/edge before layout.
        Task { @MainActor in
            relayout(anchorID: selectedWorkspaceId ?? workspaceNodeID, incremental: true)
        }
    }

    // MARK: - Layout

    /// Recomputes layout positions. Uses the hybrid `GraphLayoutEngine`
    /// (cluster + force + radial focus) so the Context Field can
    /// reorganize around a focal entity (prompt §6) without touching
    /// the persistence layer. Relevance is a continuous spatial field that
    /// nudges highly relevant nodes inward while preserving workspace clusters.
    private func relayout(anchorID: String? = nil, incremental: Bool = false, focusID: String? = nil) {
        let effectiveFocus = focusID ?? contextFocusID
        computeRelevance()
        let relevanceSnap = relevanceScores
        layoutTask?.cancel()
        let model = visualizationModel
        let visible = visibleEdges
        let nodesSnap = nodes
        let edgesSnap = visible
        let existing = incremental ? positions : [:]
        let start = CFAbsoluteTimeGetCurrent()
        layoutTask = Task {
            let result: [String: CGPoint]
            if effectiveFocus != nil {
                result = GraphLayoutEngine.layout(model: model, existing: existing,
                                                  anchorID: anchorID, focusID: effectiveFocus,
                                                  relevance: relevanceSnap)
            } else {
                // Hybrid workspace-cluster + relevance: relevance gently biases
                // cluster placement when no explicit focus exists, using the
                // active workspace as implicit focus inside GraphRelevance.
                let inputs = nodesSnap.map { node in
                    GraphLayout.NodeInput(id: node.id, nodeType: node.nodeType,
                                          workspaceId: node.workspaceId, entityId: node.entityId,
                                          isWorkspace: node.nodeType == .workspace)
                }
                let edgeInputs = edgesSnap.map {
                    GraphLayout.EdgeInput(source: $0.sourceID, target: $0.targetID, weight: $0.weight)
                }
                result = GraphLayout.layout(nodes: inputs, edges: edgeInputs,
                                             existing: existing, anchorID: anchorID,
                                             relevance: relevanceSnap)
            }
            guard !Task.isCancelled else { return }
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            self.lastLayoutDurationMs = elapsed
            self.positions = result
            self.layoutGeneration += 1
        }
    }

    /// Deterministic full relayout from scratch (reset button).
    func resetLayout() {
        if contextFocusID != nil {
            clearContextFocus()
        } else {
            relayout(anchorID: workspaceNodeID)
        }
    }

    // MARK: - Fixture & Benchmark (no DB, prompt §17–§18)

    /// Loads the deterministic ContextSphere Development fixture (prompt §18)
    /// into the view model without hitting the daemon — useful for previews,
    /// layout benchmarking, and validating the Context Field without live data.
    func loadFixture() {
        loadTask?.cancel()
        let (fnodes, fedges) = GraphFixture.contextSphereDevelopment()
        registry.removeAll()
        edgeSet.removeAll()
        var newEdges: [KgEdge] = []
        for n in fnodes { registry[n.id] = n }
        for e in fedges where registry[e.sourceID] != nil && registry[e.targetID] != nil {
            if edgeSet.insert(e.id).inserted { newEdges.append(e) }
        }
        edges = newEdges
        nodes = Array(registry.values).sorted { ($0.workspaceId ?? "", $0.title) < ($1.workspaceId ?? "", $1.title) }
        state = .loaded
        isUsingFixture = true
        relayout(anchorID: nodes.first { $0.nodeType == .workspace }?.id)
    }

    /// Loads a synthetic graph of `count` nodes for performance testing (prompt §16).
    func loadSyntheticFixture(count: Int) {
        loadTask?.cancel()
        let (snodes, sedges) = GraphFixture.synthetic(nodeCount: count)
        registry.removeAll()
        edgeSet.removeAll()
        for n in snodes { registry[n.id] = n }
        edges = sedges.filter { registry[$0.sourceID] != nil && registry[$0.targetID] != nil }
        for e in edges { edgeSet.insert(e.id) }
        nodes = Array(registry.values).sorted { $0.title < $1.title }
        state = .loaded
        isUsingFixture = true
        relayout(anchorID: snodes.first?.id)
    }

    /// Returns layout timing for the current graph (ms). Used by the debug overlay.
    func benchmarkLayout() -> Double {
        let model = visualizationModel
        let start = CFAbsoluteTimeGetCurrent()
        _ = GraphLayoutEngine.layout(model: model, existing: [:], anchorID: nil, focusID: nil)
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    // MARK: - Node presentation

    /// Relationship counts for a node, ordered by count (descending).
    func relationshipBreakdown(for nodeID: String) -> [(type: GraphRelationshipType, count: Int)] {
        var counts: [GraphRelationshipType: Int] = [:]
        for edge in edges where edge.sourceID == nodeID || edge.targetID == nodeID {
            counts[edge.relationshipType, default: 0] += 1
        }
        return counts
            .map { (type: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }
}

// MARK: - Legacy → RC-8 normalization

private extension GraphNode {
    func toKgNode() -> KgNode {
        KgNode(nodeType: entityType == .workspace ? .workspace : .file,
               entityId: entityId,
               title: title,
               workspaceId: workspaceId,
               summary: nil,
               metadata: .object([:]),
               createdAt: "",
               updatedAt: "")
    }
}

private extension GraphEdge {
    func toKgEdge() -> KgEdge {
        let relationship: GraphRelationshipType
        switch edgeType {
        case .coOccurrence, .semanticSimilarity: relationship = .relatedTo
        case .explicitReference: relationship = .reportsOn
        case .derivation: relationship = .derivedFrom
        }
        return KgEdge(id: id,
                      sourceNodeType: sourceEntityType == .workspace ? .workspace : .file,
                      sourceEntityId: sourceEntityId,
                      targetNodeType: targetEntityType == .workspace ? .workspace : .file,
                      targetEntityId: targetEntityId,
                      relationshipType: relationship,
                      weight: weight,
                      confidence: weight,
                      metadata: .object([:]),
                      createdAt: createdAt,
                      updatedAt: updatedAt)
    }
}