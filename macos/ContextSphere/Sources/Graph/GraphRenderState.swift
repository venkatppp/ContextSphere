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
        let relevance: Double // 0…1 normalized Context Field score
        var isPrimary: Bool { relevance > 0.68 }
        var isSecondary: Bool { relevance > 0.38 && relevance <= 0.68 }
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
        let relevance: Double // max(relevance[source], relevance[target])
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
                      edgeDensity: GraphEdgeDensity,
                      relevance: [String: Double] = [:]) -> GraphRenderState {
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
                // Temporal + relevance: active & relevant clusters more prominent
                let avgAct = cluster.memberIDs.compactMap { byID[$0]?.activityIntensity }.reduce(0, +) / Double(max(cluster.memberIDs.count, 1))
                let avgRel = cluster.memberIDs.compactMap { relevance[$0] }.reduce(0, +) / Double(max(cluster.memberIDs.count, 1))
                // Hybrid: relevance 0.6+ makes hull slightly larger & more opaque
                let opacity = 0.06 + avgAct * 0.08 + avgRel * 0.05 // 0.06 .. ~0.19
                let extra = CGFloat(avgAct * 8 + avgRel * 10)
                hulls.append((cluster.id, camera.worldToScreen(center), maxDist * camera.zoom + 28 + extra, cluster.color, min(opacity, 0.20)))
            }
            return hulls
        }()

        // Nodes: viewport culling + LOD + temporal + relevance
        var renderNodes: [GraphRenderState.RenderNode] = []
        for vn in model.nodes {
            guard let w = positions[vn.id], visibleWorld.contains(w) else { continue }
            let rel = relevance[vn.id] ?? 0.45 // neutral if missing
            // Overview LOD: hide low-importance leaf nodes unless recent or highly relevant
            if level == .overview, !vn.isWorkspace, vn.importance < 0.45, vn.degree < 2,
               vn.activityIntensity < 0.4, rel < 0.55 {
                continue
            }
            let dist = distances[vn.id]
            let opacity: Double = {
                guard focusedID != nil else {
                    // No focus: relevance defines hierarchy — ambient still visible but subdued
                    // Primary 1.0, secondary ~0.88, ambient 0.62
                    if vn.isRecent && level == .overview { return 1.0 }
                    return 0.58 + rel * 0.42 // 0.58 .. 1.0
                }
                let base: Double
                switch dist {
                case 0: base = 1.0
                case 1: base = 0.92
                case 2: base = 0.62
                case nil: base = 0.22
                default: base = 0.18
                }
                // Relevance gently lifts ambient secondary context;
                // high relevance + old stays readable (0.22→0.45), low+old stays ambient (0.22→0.30)
                // high+recent was already strong via activity, now reinforced by relevance.
                if dist == nil {
                    if rel > 0.70 { return min(0.68, base + 0.35) } // promote highly relevant ambient to secondary
                    if rel > 0.45 { return base + rel * 0.22 } // modest lift
                    return base + rel * 0.10
                }
                // For focused and neighbor rings, relevance subtly modulates within tier
                return min(1.0, base + (rel - 0.5) * 0.14)
            }()
            let showLabel: Bool = {
                if vn.isWorkspace { return level != .overview }
                // Relevance drives label visibility: primary always, secondary at normal+, ambient only if focused/selected
                if rel > 0.68 { return level != .overview } // primary shows at normal & detailed
                switch level {
                case .overview: return vn.importance > 0.75 || vn.isRecent || rel > 0.75
                case .normal: return vn.importance > 0.45 || vn.isRecent || rel > 0.55 || vn.id == selectedID || vn.id == focusedID
                case .detailed: return true
                }
            }()
            let baseRadius = vn.nodeType.nodeRadius
            // Visual hierarchy: importance + recency + relevance (subtle, not neon)
            // Primary context = strongest (+2.8), secondary = readable (+1.2), ambient = baseline
            let relevanceBoost: CGFloat
            if rel > 0.68 { relevanceBoost = CGFloat((rel - 0.68) * 6.5) } // 0→2.1
            else if rel > 0.38 { relevanceBoost = CGFloat((rel - 0.38) * 2.0) } // 0→0.6
            else { relevanceBoost = CGFloat((rel - 0.38) * 0.8) } // -0.3 .. 0
            let scaledRadius = baseRadius + CGFloat(vn.importance * 3.0) + CGFloat(vn.activityIntensity * 1.5) + relevanceBoost
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
                isRecent: vn.isRecent,
                relevance: rel))
        }

        // Sort so focused/selected/primary draw on top; primary relevance lifts secondary above ambient
        renderNodes.sort { a, b in
            let rank: (GraphRenderState.RenderNode) -> Int = { n in
                if n.isFocused { return 4 }
                if n.isSelected { return 3 }
                if n.isPrimary { return 2 }
                if n.isHovered { return 1 }
                return 0
            }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            // Within same tier, higher relevance first so it paints last (on top)
            if abs(a.relevance - b.relevance) > 0.08 { return a.relevance < b.relevance }
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
            // Relevance of edge = max endpoint relevance (so relevant connections stand out)
            let rel = max(relevance[e.sourceID] ?? 0.45, relevance[e.targetID] ?? 0.45)
            var baseOpacity = min(0.05 + e.strength * 0.42, 0.6)
            // Temporal + relevance: recent or highly relevant edges slightly more opaque
            if e.isRecent, level != .overview { baseOpacity = min(baseOpacity + 0.12, 0.75) }
            if rel > 0.68, level != .overview { baseOpacity = min(baseOpacity + 0.10, 0.72) }
            else if rel > 0.50 { baseOpacity = min(baseOpacity + 0.05, 0.65) }
            // Ambient edges with low relevance become more subdued, not hidden
            if rel < 0.35, !isHighlighted { baseOpacity *= 0.85 }
            let opacity = isDimmed ? baseOpacity * 0.25 : (isHighlighted ? min(baseOpacity * 1.7, 0.85) : baseOpacity)
            var style: GraphRenderState.EdgeStyle = {
                if e.strength >= 0.7 { return .solid }
                if e.strength >= 0.4 { return .dashed }
                return .dotted
            }()
            // Relevance: highly relevant dotted becomes dashed so it remains readable
            if rel > 0.65, style == .dotted, level != .overview { style = .dashed }
            // Temporal: recent dotted becomes dashed
            if e.isRecent, style == .dotted, level != .overview { style = .dashed }
            if level == .overview, style == .dotted { return nil }
            // Relevance + temporal weight boost
            var lw = max(0.5, CGFloat(e.strength) * 1.2) * min(camera.zoom, 1.2)
            if e.isRecent { lw += 0.4 }
            if rel > 0.68 { lw += 0.5 }
            else if rel > 0.50 { lw += 0.2 }
            return GraphRenderState.RenderEdge(
                id: e.id,
                sourceScreen: camera.worldToScreen(s),
                targetScreen: camera.worldToScreen(t),
                weight: e.weight, strength: e.strength,
                opacity: opacity, lineWidth: lw,
                isHighlighted: isHighlighted, isDimmed: isDimmed, style: style,
                activityIntensity: e.activityIntensity, isRecent: e.isRecent, relevance: rel)
        }

        return GraphRenderState(nodes: renderNodes, edges: renderEdges,
                                clusterHulls: clusterHulls,
                                semanticLevel: level, cameraZoom: camera.zoom)
    }
}
