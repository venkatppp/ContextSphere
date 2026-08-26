import SwiftUI

// MARK: - Render state (prompt §9)

/// GPU/render-friendly snapshot of what the Canvas should draw.
/// The renderer receives this and never queries SQLite, the view model,
/// or the layout engine directly.
struct GraphRenderState {
    struct RenderNode: Identifiable {
        let id: String
        let world: CGPoint
        let screen: CGPoint
        let radius: CGFloat
        let color: Color
        let opacity: Double
        let title: String
        let labelVisible: Bool
        let symbol: String
        let isSelected: Bool
        let isHovered: Bool
        let isFocused: Bool
        let importance: Double
        let clusterId: String
        let distance: Int?
        let activityIntensity: Double
        let isRecent: Bool
    }

    struct RenderEdge: Identifiable {
        let id: String
        let sourceScreen: CGPoint
        let targetScreen: CGPoint
        let weight: Double
        let strength: Double
        let opacity: Double
        let lineWidth: CGFloat
        let isHighlighted: Bool
        let isDimmed: Bool
        let style: EdgeStyle
        let activityIntensity: Double
        let isRecent: Bool
    }

    enum EdgeStyle { case solid, dashed, dotted }

    let nodes: [RenderNode]
    let edges: [RenderEdge]
    /// Cluster halos to draw behind nodes at overview zoom (optional).
    let clusterHulls: [(id: String, center: CGPoint, radius: CGFloat, color: Color, opacity: Double)]
    let semanticLevel: GraphCamera.SemanticLevel
    let cameraZoom: CGFloat
}

// MARK: - Builder

enum GraphEdgeDensity { case all, strong }

enum GraphRenderStateBuilder {
    static func build(model: GraphVisualizationModel,
                      positions: [String: CGPoint],
                      camera: GraphCamera,
                      selectedID: String?,
                      hoveredID: String?,
                      focusedID: String?,
                      edgeDensity: GraphEdgeDensity) -> GraphRenderState {
        let visibleWorld = camera.visibleWorldRect()
        let level = camera.semanticLevel
        // Focus distances (prompt §14)
        let distances: [String: Int] = focusedID.flatMap { model.distances(from: $0) } ?? [:]

        // Edge filtering
        let rawEdges = model.edges.filter { e in
            guard let s = positions[e.sourceID], let t = positions[e.targetID] else { return false }
            // Viewport culling for edges
            let r = CGRect(x: min(s.x, t.x), y: min(s.y, t.y),
                           width: abs(s.x - t.x), height: abs(s.y - t.y))
            if !visibleWorld.intersects(r) { return false }
            if case .strong = edgeDensity, e.weight < 0.5 { return false }
            return true
        }

        let clusterHulls: [(String, CGPoint, CGFloat, Color, Double)] = {
            guard level == .overview else { return [] }
            var hulls: [(String, CGPoint, CGFloat, Color, Double)] = []
            let byID = model.nodeByID
            for cluster in model.clusters where cluster.memberIDs.count > 2 {
                let pts = cluster.memberIDs.compactMap { positions[$0] }
                guard !pts.isEmpty else { continue }
                let cx = pts.map(\.x).reduce(0, +) / CGFloat(pts.count)
                let cy = pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
                let center = CGPoint(x: cx, y: cy)
                let maxDist = pts.map { hypot($0.x - cx, $0.y - cy) }.max() ?? 60
                // Temporal: active clusters more opaque / slightly larger
                let avgAct = cluster.memberIDs.compactMap { byID[$0]?.activityIntensity }.reduce(0, +) / Double(max(cluster.memberIDs.count, 1))
                let opacity = 0.06 + avgAct * 0.08 // 0.06 stale .. 0.14 recent
                let extra = CGFloat(avgAct * 8)
                hulls.append((cluster.id, camera.worldToScreen(center), maxDist * camera.zoom + 28 + extra, cluster.color, opacity))
            }
            return hulls
        }()

        // Nodes: viewport culling + LOD + temporal
        var renderNodes: [GraphRenderState.RenderNode] = []
        for vn in model.nodes {
            guard let w = positions[vn.id], visibleWorld.contains(w) else { continue }
            // Overview LOD: hide low-importance leaf nodes unless recent
            if level == .overview, !vn.isWorkspace, vn.importance < 0.45, vn.degree < 2, vn.activityIntensity < 0.4 {
                continue
            }
            let dist = distances[vn.id]
            let opacity: Double = {
                guard focusedID != nil else {
                    // Without focus, recent nodes are slightly more opaque at overview
                    if level == .overview, vn.isRecent { return 1.0 }
                    return 1.0
                }
                switch dist {
                case 0: return 1.0
                case 1: return 0.92
                case 2: return 0.62
                case nil: return 0.22
                default: return 0.18
                }
            }()
            let showLabel: Bool = {
                if vn.isWorkspace { return level != .overview }
                switch level {
                case .overview: return vn.importance > 0.75 || vn.isRecent
                case .normal: return vn.importance > 0.45 || vn.isRecent || vn.id == selectedID || vn.id == focusedID
                case .detailed: return true
                }
            }()
            let baseRadius = vn.nodeType.nodeRadius
            // Importance + recency scales radius: recent gets subtle +1.5
            let scaledRadius = baseRadius + CGFloat(vn.importance * 3.0) + CGFloat(vn.activityIntensity * 1.5)
            let screen = camera.worldToScreen(w)
            renderNodes.append(GraphRenderState.RenderNode(
                id: vn.id, world: w, screen: screen,
                radius: scaledRadius * camera.zoom,
                color: vn.nodeType.color, opacity: opacity,
                title: vn.title, labelVisible: showLabel,
                symbol: vn.nodeType.symbol,
                isSelected: vn.id == selectedID,
                isHovered: vn.id == hoveredID,
                isFocused: vn.id == focusedID,
                importance: vn.importance, clusterId: vn.clusterId,
                distance: dist,
                activityIntensity: vn.activityIntensity,
                isRecent: vn.isRecent))
        }

        // Sort so focused/selected draw on top
        renderNodes.sort { a, b in
            let rank: (GraphRenderState.RenderNode) -> Int = { n in
                if n.isFocused { return 3 }
                if n.isSelected { return 2 }
                if n.isHovered { return 1 }
                return 0
            }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.importance < b.importance
        }

        let renderEdges: [GraphRenderState.RenderEdge] = rawEdges.compactMap { e in
            guard let s = positions[e.sourceID], let t = positions[e.targetID] else { return nil }
            let sd = distances[e.sourceID]
            let td = distances[e.targetID]
            let isHighlighted = (sd == 0 && td == 1) || (sd == 1 && td == 0) || (sd == 0 && td == 0)
            let isDimmed: Bool = {
                guard focusedID != nil else { return false }
                return sd == nil && td == nil
            }()
            var baseOpacity = min(0.05 + e.strength * 0.42, 0.6)
            // Temporal: recent edges slightly more opaque
            if e.isRecent, level != .overview { baseOpacity = min(baseOpacity + 0.12, 0.75) }
            let opacity = isDimmed ? baseOpacity * 0.25 : (isHighlighted ? min(baseOpacity * 1.7, 0.85) : baseOpacity)
            var style: GraphRenderState.EdgeStyle = {
                if e.strength >= 0.7 { return .solid }
                if e.strength >= 0.4 { return .dashed }
                return .dotted
            }()
            // Temporal: recent dotted becomes dashed at normal+ to be visible
            if e.isRecent, style == .dotted, level != .overview { style = .dashed }
            if level == .overview, style == .dotted { return nil }
            var lw = max(0.5, CGFloat(e.strength) * 1.2) * min(camera.zoom, 1.2)
            if e.isRecent { lw += 0.4 } // subtle weight boost
            return GraphRenderState.RenderEdge(
                id: e.id,
                sourceScreen: camera.worldToScreen(s),
                targetScreen: camera.worldToScreen(t),
                weight: e.weight, strength: e.strength,
                opacity: opacity, lineWidth: lw,
                isHighlighted: isHighlighted, isDimmed: isDimmed, style: style,
                activityIntensity: e.activityIntensity, isRecent: e.isRecent)
        }

        return GraphRenderState(nodes: renderNodes, edges: renderEdges,
                                clusterHulls: clusterHulls,
                                semanticLevel: level, cameraZoom: camera.zoom)
    }
}
