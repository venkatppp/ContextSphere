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
    /// Last layout pass duration in ms (for the debug overlay / benchmarks).
    @Published private(set) var lastLayoutDurationMs: Double = 0

    /// Adapter: current daemon data → visual model without DB migration (prompt §17).
    var visualizationModel: GraphVisualizationModel {
        GraphVisualizationModel.fromDaemon(nodes: nodes, edges: edges)
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
        if selectedWorkspaceId == nil
            || !workspaces.contains(where: { $0.id == selectedWorkspaceId }) {
            selectedWorkspaceId = workspaces.first(where: { $0.status == .active })?.id
                ?? workspaces.first?.id
        }
    }

    func selectWorkspace(_ id: String?) {
        guard id != selectedWorkspaceId else { return }
        selectedWorkspaceId = id
        loadGraph()
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
        loadGraph()
    }

    /// Loads the graph for the current workspace context:
    /// 1. `get_graph` (legacy node registry for the context).
    /// 2. `graph_subgraph` around the workspace node (the real RC-8
    ///    relationships), merged and deduplicated.
    /// With no workspace context, `get_graph` over the whole graph.
    private func loadGraph() {
        loadTask?.cancel()
        loadTask = Task {
            state = .loading
            lastError = nil
            searchResults = []
            searchQuery = ""
            do {
                if let workspaceID = selectedWorkspaceId {
                    try await loadWorkspaceGraph(workspaceID)
                } else {
                    try await loadWholeGraph()
                }
                state = .loaded
                relayout(anchorID: workspaceNodeID)
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error.localizedDescription
                state = .failed(error.localizedDescription)
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

        // 1. Legacy registry (`get_graph` — the graph_get_graph API).
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

        // 2. RC-8 subgraph around the workspace node (bounded by backend).
        let subgraph: KgSubgraph = try await CoreBridge.shared.request(
            "graph_subgraph",
            params: [
                "node_type": GraphNodeType.workspace.rawValue,
                "entity_id": workspaceID,
                "depth": Self.subgraphDepth,
            ],
            as: KgSubgraph.self)
        mergeSubgraph(subgraph)
        nodes = registry.values.sorted {
            ($0.workspaceId ?? "", $0.title) < ($1.workspaceId ?? "", $1.title)
        }
    }

    private func loadWholeGraph() async throws {
        registry.removeAll()
        edgeSet.removeAll()
        let view: GraphView = try await CoreBridge.shared.request(
            "get_graph", as: GraphView.self)
        for legacyNode in view.nodes {
            registry[legacyNode.id] = legacyNode.toKgNode()
        }
        for legacyEdge in view.edges {
            mergeEdge(legacyEdge.toKgEdge())
        }
        nodes = registry.values.sorted {
            ($0.workspaceId ?? "", $0.title) < ($1.workspaceId ?? "", $1.title)
        }
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
                lastError = nil
                relayout(anchorID: anchorID, incremental: true)
            } catch {
                lastError = error.localizedDescription
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
    }

    func clearContextFocus() {
        contextFocusID = nil
        relayout(anchorID: workspaceNodeID, incremental: false, focusID: nil)
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
    func focusSearchResult(_ node: KgNode) {
        clearSearch()
        let isKnown = registry[node.id] != nil
        if !isKnown {
            mergeNode(node)
            nodes = registry.values.sorted {
                ($0.workspaceId ?? "", $0.title) < ($1.workspaceId ?? "", $1.title)
            }
            relayout(anchorID: node.id, incremental: true)
        }
        focusedNodeID = node.id
        selectedNodeID = node.id
        showInspector = true
        focusNonce += 1
        pendingFocus = (node.id, focusNonce)
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
    /// the persistence layer.
    private func relayout(anchorID: String? = nil, incremental: Bool = false, focusID: String? = nil) {
        let effectiveFocus = focusID ?? contextFocusID
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
                                                  anchorID: anchorID, focusID: effectiveFocus)
            } else {
                let inputs = nodesSnap.map { node in
                    GraphLayout.NodeInput(id: node.id, nodeType: node.nodeType,
                                          workspaceId: node.workspaceId, entityId: node.entityId,
                                          isWorkspace: node.nodeType == .workspace)
                }
                let edgeInputs = edgesSnap.map {
                    GraphLayout.EdgeInput(source: $0.sourceID, target: $0.targetID, weight: $0.weight)
                }
                result = GraphLayout.layout(nodes: inputs, edges: edgeInputs,
                                             existing: existing, anchorID: anchorID)
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