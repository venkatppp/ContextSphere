import Foundation
import SwiftUI

// MARK: - Canonical → Visual projection

/// The adapter layer that turns the current ContextSphere persistence
/// (`KgNode`/`KgEdge` from the Rust daemon) into a render-ready
/// visualization model WITHOUT touching the SQLite schema.
///
/// This is the `GraphVisualizationModel` from prompt §17 — the smallest
/// safe step before any bitemporal/assertion migration. It adds computed
/// semantics (importance, clusters, strengths) on top of the existing data
/// rather than replacing it.
///
/// Architecture (prompt §4):
///   ContextSphere Data → Canonical Graph → Projection → Layout → Render → Canvas
///   This file owns the first two arrows.
struct GraphVisualizationModel {
    /// One node as the visual layer sees it.
    struct VisualNode: Identifiable, Hashable {
        let id: String
        let entityId: String
        let nodeType: GraphNodeType
        let title: String
        let workspaceId: String?
        let summary: String?
        let metadata: JSONValue
        let createdAt: String
        let updatedAt: String
        /// Computed importance 0…1 (degree + type weight).
        let importance: Double
        /// Number of incident edges.
        let degree: Int
        /// Cluster assignment (workspace or orphan group).
        let clusterId: String
        var isWorkspace: Bool { nodeType == .workspace }
    }

    struct VisualEdge: Identifiable, Hashable {
        let id: String
        let sourceID: String
        let targetID: String
        let relationship: GraphRelationshipType
        let weight: Double
        let confidence: Double
        var strength: Double { weight * confidence }
        /// Structural vs semantic (used for edge decay semantics in RC-8 M2).
        var isStructural: Bool { relationship != .relatedTo }
    }

    struct VisualCluster: Identifiable, Hashable {
        let id: String
        let title: String
        let memberIDs: [String]
        let color: Color
    }

    /// How a Workspace appears visually (prompt §7). The semantic model
    /// is always a node; the visual model may treat it as a region/cluster.
    enum WorkspaceLens {
        case centralNode
        case clusterRegion
        case scopeHalo
        case contextualLens
    }

    let nodes: [VisualNode]
    let edges: [VisualEdge]
    let clusters: [VisualCluster]
    let workspaceLens: WorkspaceLens
    /// Adjacency for fast BFS / degree lookups.
    let adjacency: [String: Set<String>]

    var nodeByID: [String: VisualNode] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    }

    /// Nodes sorted by importance descending (for semantic zoom).
    var rankedNodes: [VisualNode] {
        nodes.sorted { $0.importance > $1.importance }
    }

    /// Relationships incident to a node, strongest first.
    func relationships(for nodeID: String) -> [(VisualNode, VisualEdge)] {
        let dict = nodeByID
        return edges.compactMap { edge in
            if edge.sourceID == nodeID, let target = dict[edge.targetID] { return (target, edge) }
            if edge.targetID == nodeID, let source = dict[edge.sourceID] { return (source, edge) }
            return nil
        }.sorted { $0.1.strength > $1.1.strength }
    }

    /// BFS distance from a focus node (nil = unreachable).
    func distances(from focusID: String) -> [String: Int] {
        guard nodeByID[focusID] != nil else { return [:] }
        var dist: [String: Int] = [focusID: 0]
        var queue = [focusID]
        var head = 0
        while head < queue.count {
            let cur = queue[head]; head += 1
            let d = dist[cur]!
            for nb in adjacency[cur] ?? [] where dist[nb] == nil {
                dist[nb] = d + 1
                queue.append(nb)
            }
        }
        return dist
    }

    // MARK: Adapter from daemon types

    static func fromDaemon(nodes: [KgNode], edges: [KgEdge],
                           lens: WorkspaceLens = .clusterRegion) -> GraphVisualizationModel {
        // Degree counts
        var degree: [String: Int] = [:]
        var adj: [String: Set<String>] = [:]
        for e in edges {
            degree[e.sourceID, default: 0] += 1
            degree[e.targetID, default: 0] += 1
            adj[e.sourceID, default: []].insert(e.targetID)
            adj[e.targetID, default: []].insert(e.sourceID)
        }
        let maxDegree = degree.values.max() ?? 1
        // Type weight: workspaces anchor clusters, memory/execution are secondary.
        func typeWeight(_ t: GraphNodeType) -> Double {
            switch t {
            case .workspace: 1.0
            case .file: 0.75
            case .memoryRecord: 0.8
            case .execution: 0.7
            case .plannerReport: 0.6
            case .autonomousSession: 0.65
            }
        }
        let visualNodes: [VisualNode] = nodes.map { n in
            let d = degree[n.id] ?? 0
            let normDegree = Double(d) / Double(maxDegree)
            let imp = min(1.0, normDegree * 0.7 + typeWeight(n.nodeType) * 0.3)
            let cluster = n.workspaceId ?? "orphan:\(n.nodeType.rawValue)"
            return VisualNode(id: n.id, entityId: n.entityId, nodeType: n.nodeType,
                              title: n.title, workspaceId: n.workspaceId,
                              summary: n.summary, metadata: n.metadata,
                              createdAt: n.createdAt, updatedAt: n.updatedAt,
                              importance: imp, degree: d, clusterId: cluster)
        }
        let visualEdges: [VisualEdge] = edges.map { e in
            VisualEdge(id: e.id, sourceID: e.sourceID, targetID: e.targetID,
                       relationship: e.relationshipType, weight: e.weight, confidence: e.confidence)
        }
        // Clusters by workspace
        var byCluster: [String: [String]] = [:]
        for n in visualNodes { byCluster[n.clusterId, default: []].append(n.id) }
        let palette: [Color] = [.indigo, .teal, .orange, .purple, .pink, .cyan, .green, .brown]
        let clusters: [VisualCluster] = byCluster
            .sorted { $0.key < $1.key }
            .enumerated()
            .map { idx, pair in
                VisualCluster(id: pair.key, title: pair.key, memberIDs: pair.value,
                              color: palette[idx % palette.count])
            }
        return GraphVisualizationModel(nodes: visualNodes, edges: visualEdges,
                                       clusters: clusters, workspaceLens: lens,
                                       adjacency: adj)
    }

    /// Empty model for previews / loading states.
    static let empty = GraphVisualizationModel(nodes: [], edges: [], clusters: [], workspaceLens: .clusterRegion, adjacency: [:])
}
