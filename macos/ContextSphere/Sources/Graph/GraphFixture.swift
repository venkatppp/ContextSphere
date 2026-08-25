import Foundation

// MARK: - Deterministic realistic fixture (prompt §18)

/// Builds a deterministic graph that mirrors a real ContextSphere workspace
/// so layout / rendering / focus can be validated without a live daemon
/// or a database migration. All IDs are stable strings; no UUID randomness.
///
/// Workspace: ContextSphere Development
/// Projects: Graph Architecture, UI Architecture
/// Apps: Xcode, Terminal, Safari, GitHub
/// Docs: Graph Research, Architecture Notes
/// Topics: GraphRAG, Temporal Graph, SwiftUI, Metal
/// Files: GraphEngine.swift, GraphRenderer.swift, Workspace.swift
/// Events: FileOpened, ResearchViewed, CodeModified
enum GraphFixture {

    static func contextSphereDevelopment() -> (nodes: [KgNode], edges: [KgEdge]) {
        // Stable IDs: type:entity
        func nid(_ type: GraphNodeType, _ entity: String) -> String { "\(type.rawValue):\(entity)" }

        let wsID = "ws-contextsphere-dev"
        let projGraph = "proj-graph-arch"
        let projUI = "proj-ui-arch"

        // Nodes
        var nodes: [KgNode] = []
        func makeNode(_ type: GraphNodeType, _ eid: String, _ title: String,
                      _ ws: String? = wsID, _ summary: String? = nil) -> KgNode {
            KgNode(nodeType: type, entityId: eid, title: title,
                   workspaceId: ws, summary: summary,
                   metadata: .object([:]), createdAt: "", updatedAt: "")
        }
        // Workspace
        nodes.append(makeNode(.workspace, wsID, "ContextSphere Development", nil, "Your computer understands what you're working on"))
        // Projects (modeled as file/workspace-adjacent nodes; in RC-8 they are file or workspace; we use file for projects)
        nodes.append(makeNode(.file, projGraph, "Graph Architecture", wsID, "Graph model, layout, renderer separation"))
        nodes.append(makeNode(.file, projUI, "UI Architecture", wsID, "Dashboard, timeline, workspaces"))
        // Applications (files with artifact type app via metadata)
        nodes.append(makeNode(.file, "app-xcode", "Xcode", wsID))
        nodes.append(makeNode(.file, "app-terminal", "Terminal", wsID))
        nodes.append(makeNode(.file, "app-safari", "Safari", wsID))
        nodes.append(makeNode(.file, "app-github", "GitHub", wsID))
        // Documents
        nodes.append(makeNode(.file, "doc-graph-research", "Graph Research", wsID, "Handshake Influence Dashboard study"))
        nodes.append(makeNode(.file, "doc-arch-notes", "Architecture Notes", wsID, "Event-sourced vs typed property graph"))
        // Topics (as memoryRecord nodes carrying topic semantics)
        nodes.append(makeNode(.memoryRecord, "topic-graphrag", "GraphRAG", wsID))
        nodes.append(makeNode(.memoryRecord, "topic-temporal", "Temporal Graph", wsID))
        nodes.append(makeNode(.memoryRecord, "topic-swiftui", "SwiftUI", wsID))
        nodes.append(makeNode(.memoryRecord, "topic-metal", "Metal", wsID))
        nodes.append(makeNode(.memoryRecord, "topic-liquid-glass", "Liquid Glass", wsID))
        // Files
        nodes.append(makeNode(.file, "file-graph-engine", "GraphEngine.swift", wsID, "src-tauri/src/graph/mod.rs"))
        nodes.append(makeNode(.file, "file-graph-renderer", "GraphRenderer.swift", wsID))
        nodes.append(makeNode(.file, "file-workspace", "Workspace.swift", wsID))
        nodes.append(makeNode(.file, "file-timeline", "Timeline.swift", wsID))
        // Events (as executions)
        nodes.append(makeNode(.execution, "evt-file-opened", "FileOpened: GraphEngine.swift", wsID))
        nodes.append(makeNode(.execution, "evt-research-viewed", "ResearchViewed: Handshake Dashboard", wsID))
        nodes.append(makeNode(.execution, "evt-code-modified", "CodeModified: GraphLayout", wsID))
        nodes.append(makeNode(.execution, "evt-meeting", "Meeting: Graph Review", wsID))
        // Memories / sessions
        nodes.append(makeNode(.memoryRecord, "mem-1", "Memory: Graph layout stabilized", wsID))
        nodes.append(makeNode(.autonomousSession, "sess-1", "Autonomous: Index workspace", wsID))

        // Edges — enough to make clustering meaningful
        var edges: [KgEdge] = []
        var eid = 0
        func link(_ srcType: GraphNodeType, _ src: String,
                  _ dstType: GraphNodeType, _ dst: String,
                  _ rel: GraphRelationshipType, _ w: Double, _ conf: Double = 1.0) {
            eid += 1
            edges.append(KgEdge(id: "e\(eid)",
                                sourceNodeType: srcType, sourceEntityId: src,
                                targetNodeType: dstType, targetEntityId: dst,
                                relationshipType: rel, weight: w, confidence: conf,
                                metadata: .object([:]), createdAt: "", updatedAt: ""))
        }
        // Workspace → Project
        link(.workspace, wsID, .file, projGraph, .contains, 0.95)
        link(.workspace, wsID, .file, projUI, .contains, 0.92)
        // Project → File
        link(.file, projGraph, .file, "file-graph-engine", .relatedTo, 0.9)
        link(.file, projGraph, .file, "file-graph-renderer", .relatedTo, 0.88)
        link(.file, projUI, .file, "file-workspace", .relatedTo, 0.85)
        link(.file, projUI, .file, "file-timeline", .relatedTo, 0.82)
        // File → Application
        link(.file, "file-graph-engine", .file, "app-xcode", .relatedTo, 0.8)
        link(.file, "file-graph-engine", .file, "app-github", .relatedTo, 0.6)
        link(.file, "file-workspace", .file, "app-xcode", .relatedTo, 0.75)
        link(.file, "file-timeline", .file, "app-safari", .relatedTo, 0.5)
        // File → Topic
        link(.file, "file-graph-engine", .memoryRecord, "topic-graphrag", .relatedTo, 0.7)
        link(.file, "file-graph-engine", .memoryRecord, "topic-temporal", .relatedTo, 0.65)
        link(.file, "file-graph-renderer", .memoryRecord, "topic-metal", .relatedTo, 0.75)
        link(.file, "file-graph-renderer", .memoryRecord, "topic-swiftui", .relatedTo, 0.9)
        link(.file, "file-workspace", .memoryRecord, "topic-swiftui", .relatedTo, 0.6)
        // Document → Topic
        link(.file, "doc-graph-research", .memoryRecord, "topic-graphrag", .relatedTo, 0.88)
        link(.file, "doc-graph-research", .memoryRecord, "topic-temporal", .relatedTo, 0.72)
        link(.file, "doc-arch-notes", .memoryRecord, "topic-temporal", .relatedTo, 0.8)
        // Topic → Topic
        link(.memoryRecord, "topic-graphrag", .memoryRecord, "topic-temporal", .relatedTo, 0.6)
        link(.memoryRecord, "topic-swiftui", .memoryRecord, "topic-metal", .relatedTo, 0.55)
        link(.memoryRecord, "topic-swiftui", .memoryRecord, "topic-liquid-glass", .relatedTo, 0.7)
        // Project → Project
        link(.file, projGraph, .file, projUI, .relatedTo, 0.65)
        // Workspace ↔ Documents
        link(.workspace, wsID, .file, "doc-graph-research", .contains, 0.7)
        link(.workspace, wsID, .file, "doc-arch-notes", .contains, 0.68)
        // Apps ↔ Topics (tool affinity)
        link(.file, "app-xcode", .memoryRecord, "topic-swiftui", .relatedTo, 0.75)
        link(.file, "app-safari", .memoryRecord, "topic-graphrag", .relatedTo, 0.55)
        // Events → Entities
        link(.execution, "evt-file-opened", .file, "file-graph-engine", .reportsOn, 0.9)
        link(.execution, "evt-research-viewed", .file, "doc-graph-research", .reportsOn, 0.85)
        link(.execution, "evt-code-modified", .file, "file-graph-engine", .reportsOn, 0.88)
        link(.execution, "evt-meeting", .file, projGraph, .reportsOn, 0.5)
        // Memory links
        link(.memoryRecord, "mem-1", .execution, "evt-code-modified", .derivedFrom, 0.9)
        link(.autonomousSession, "sess-1", .workspace, wsID, .runsIn, 0.8)
        link(.memoryRecord, "topic-liquid-glass", .file, "doc-arch-notes", .relatedTo, 0.62)

        return (nodes, edges)
    }

    /// Generates a synthetic graph of `nodeCount` nodes for performance testing.
    /// Edges are created at ~2.5× node count with stable deterministic wiring.
    /// Nodes are spread across 5 workspaces so clustering is realistic (prompt §16
    /// expects cluster-aware layout, not a single giant cluster).
    static func synthetic(nodeCount: Int) -> (nodes: [KgNode], edges: [KgEdge]) {
        var nodes: [KgNode] = []
        let wsCount = 5
        var wsIDs: [String] = []
        for w in 0..<wsCount {
            let wsID = "ws-synth-\(w)"
            wsIDs.append(wsID)
            nodes.append(KgNode(nodeType: .workspace, entityId: wsID, title: "Synthetic Workspace \(w)",
                                workspaceId: nil, summary: nil, metadata: .object([:]), createdAt: "", updatedAt: ""))
        }
        let types: [GraphNodeType] = [.file, .memoryRecord, .execution, .plannerReport, .autonomousSession]
        for i in 0..<max(0, nodeCount - wsCount) {
            let t = types[i % types.count]
            let eid = "synth-\(i)"
            let wsID = wsIDs[i % wsIDs.count]
            nodes.append(KgNode(nodeType: t, entityId: eid, title: "\(t.rawValue) \(i)",
                                workspaceId: wsID, summary: nil, metadata: .object([:]), createdAt: "", updatedAt: ""))
        }
        var edges: [KgEdge] = []
        let edgeCount = Int(Double(nodeCount) * 2.5)
        for i in 0..<edgeCount {
            // Deterministic pseudo-random pairing
            let a = nodes[(i * 17) % nodes.count]
            let b = nodes[(i * 31 + 7) % nodes.count]
            if a.id == b.id { continue }
            let w = 0.3 + Double((i * 13) % 70) / 100.0
            edges.append(KgEdge(id: "se\(i)",
                                sourceNodeType: a.nodeType, sourceEntityId: a.entityId,
                                targetNodeType: b.nodeType, targetEntityId: b.entityId,
                                relationshipType: .relatedTo, weight: min(w, 1.0), confidence: 0.9,
                                metadata: .object([:]), createdAt: "", updatedAt: ""))
        }
        // Ensure each workspace is connected to a couple of its members
        for (wIdx, wsID) in wsIDs.enumerated() {
            let members = nodes.filter { $0.workspaceId == wsID }
            for (j, m) in members.prefix(2).enumerated() {
                edges.append(KgEdge(id: "ws-e\(wIdx)-\(j)", sourceNodeType: .workspace, sourceEntityId: wsID,
                                    targetNodeType: m.nodeType, targetEntityId: m.entityId,
                                    relationshipType: .contains, weight: 0.9, confidence: 1.0,
                                    metadata: .object([:]), createdAt: "", updatedAt: ""))
            }
        }
        return (nodes, edges)
    }
}
