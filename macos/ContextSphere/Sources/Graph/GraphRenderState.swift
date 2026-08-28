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
        let displayTitle: String
        let labelVisible: Bool
        let symbol: String
        let isSelected: Bool
        let isHovered: Bool
        let isFocused: Bool
        let isWorkspace: Bool
        let importance: Double
        let clusterId: String
        let distance: Int?
        let activityIntensity: Double
        let isRecent: Bool
        let relevance: Double
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
        let relevance: Double
    }

    enum EdgeStyle { case solid, dashed, dotted }

    let nodes: [RenderNode]
    let edges: [RenderEdge]
    let clusterHulls: [(id: String, center: CGPoint, radius: CGFloat, color: Color, opacity: Double)]
    let semanticLevel: GraphCamera.SemanticLevel
    let cameraZoom: CGFloat
}

// MARK: - Builder

enum GraphEdgeDensity { case all, strong }

@MainActor
enum GraphRenderStateBuilder {
    @MainActor
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
        let distances: [String: Int] = focusedID.flatMap { model.distances(from: $0) } ?? [:]

        // Edge filtering
        let rawEdges = model.edges.filter { e in
            guard let s = positions[e.sourceID], let t = positions[e.targetID] else { return false }
            let r = CGRect(x: min(s.x, t.x), y: min(s.y, t.y),
                           width: abs(s.x - t.x), height: abs(s.y - t.y))
            if !visibleWorld.intersects(r) { return false }
            if case .strong = edgeDensity, e.weight < 0.5 { return false }
            return true
        }

        // Cluster hulls (overview) — restrained, palette-tinted
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
                let avgAct = cluster.memberIDs.compactMap { byID[$0]?.activityIntensity }.reduce(0, +) / Double(max(cluster.memberIDs.count, 1))
                let avgRel = cluster.memberIDs.compactMap { relevance[$0] }.reduce(0, +) / Double(max(cluster.memberIDs.count, 1))
                let opacity = 0.04 + avgAct * 0.06 + avgRel * 0.04
                let extra = CGFloat(avgAct * 6 + avgRel * 8)
                hulls.append((cluster.id, camera.worldToScreen(center), maxDist * camera.zoom + 30 + extra, cluster.color, min(opacity, 0.16)))
            }
            return hulls
        }()

        // Resolve colors from the current palette at build time
        let palette = GraphPaletteCache.palette()

        // First pass: build render nodes so we can dedupe labels
        var renderNodes: [GraphRenderState.RenderNode] = []
        for vn in model.nodes {
            guard let w = positions[vn.id], visibleWorld.contains(w) else { continue }
            let rel = relevance[vn.id] ?? 0.45
            if level == .overview, !vn.isWorkspace, vn.importance < 0.45, vn.degree < 2,
               vn.activityIntensity < 0.4, rel < 0.55 {
                continue
            }
            let dist = distances[vn.id]
            let opacity: Double = {
                guard focusedID != nil else {
                    if vn.isRecent && level == .overview { return 1.0 }
                    return 0.55 + rel * 0.45
                }
                let base: Double
                switch dist {
                case 0: base = 1.0
                case 1: base = 0.92
                case 2: base = 0.62
                case nil: base = 0.20
                default: base = 0.16
                }
                if dist == nil {
                    if rel > 0.70 { return min(0.60, base + 0.38) }
                    if rel > 0.45 { return base + rel * 0.22 }
                    return base + rel * 0.10
                }
                if dist == 1 {
                    return min(1.0, base + (rel - 0.5) * 0.38)
                }
                if dist == 2 {
                    return min(0.88, base + (rel - 0.5) * 0.32)
                }
                return min(1.0, base + (rel - 0.5) * 0.14)
            }()
            let baseRadius = vn.nodeType.nodeRadius
            let relevanceBoost: CGFloat
            if dist == 0 {
                relevanceBoost = 4.0 + CGFloat((rel) * 1.2)
            } else if rel > 0.68 { relevanceBoost = CGFloat((rel - 0.68) * 6.5) }
            else if rel > 0.38 { relevanceBoost = CGFloat((rel - 0.38) * 2.0) }
            else { relevanceBoost = CGFloat((rel - 0.38) * 0.8) }
            let scaledRadius = baseRadius + CGFloat(vn.importance * 3.0) + CGFloat(vn.activityIntensity * 1.5) + relevanceBoost
            let screen = camera.worldToScreen(w)
            let color = palette.color(for: vn.nodeType.colorToken)
            renderNodes.append(GraphRenderState.RenderNode(
                id: vn.id, world: w, screen: screen,
                radius: scaledRadius * camera.zoom,
                color: color, opacity: opacity,
                title: vn.title,
                displayTitle: GraphLabelFormatter.displayTitle(for: vn),
                labelVisible: false, // resolved below with collision pass
                symbol: vn.nodeType.symbol,
                isSelected: vn.id == selectedID,
                isHovered: vn.id == hoveredID,
                isFocused: vn.id == focusedID,
                isWorkspace: vn.isWorkspace,
                importance: vn.importance, clusterId: vn.clusterId,
                distance: dist,
                activityIntensity: vn.activityIntensity,
                isRecent: vn.isRecent,
                relevance: rel))
        }

        // Label collision pass: only show labels for nodes whose label
        // bounding box doesn't overlap another visible label or any node
        // disc. Selected / focused / hovered / primary always pass.
        let isDense = model.nodes.count > 200
        let labelBox: (GraphRenderState.RenderNode) -> CGRect = { n in
            let text = n.displayTitle
            let charWidth: CGFloat = 6.4
            let width = min(170, max(28, CGFloat(text.count) * charWidth + 14))
            let height: CGFloat = 14
            return CGRect(x: n.screen.x - width / 2, y: n.screen.y + n.radius + 4,
                          width: width, height: height)
        }
        var taken: [CGRect] = []
        // Sort so primary/selected/hovered get first dibs
        let ordered = renderNodes.sorted { a, b in
            func rank(_ n: GraphRenderState.RenderNode) -> Int {
                if n.isFocused { return 4 }
                if n.isSelected { return 3 }
                if n.isPrimary { return 2 }
                if n.isHovered { return 1 }
                return 0
            }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if abs(a.relevance - b.relevance) > 0.06 { return a.relevance > b.relevance }
            return a.importance > b.importance
        }
        var labeledIDs: Set<String> = []
        for n in ordered {
            // Always show for primary categories
            let alwaysShow: Bool
            if n.isWorkspace {
                alwaysShow = level != .overview
            } else if n.relevance > 0.68 {
                alwaysShow = level != .overview
            } else {
                switch level {
                case .overview: alwaysShow = n.importance > 0.75 || n.isRecent || n.relevance > 0.75
                case .normal:   alwaysShow = n.importance > 0.45 || n.isRecent || n.relevance > 0.55 || n.isSelected || n.isFocused
                case .detailed: alwaysShow = isDense ? (n.relevance > 0.55 || n.isRecent || n.isSelected || n.isFocused) : true
                }
            }
            let alwaysShowFinal: Bool = alwaysShow || n.isHovered || n.isSelected || n.isFocused
            guard alwaysShowFinal else { continue }
            let box = labelBox(n)
            var collides = false
            for prior in taken {
                if prior.intersects(box) { collides = true; break }
            }
            if !collides {
                labeledIDs.insert(n.id)
                taken.append(box)
            }
        }
        // Apply back
        renderNodes = renderNodes.map { n in
            var copy = n
            copy = GraphRenderState.RenderNode(
                id: n.id, world: n.world, screen: n.screen, radius: n.radius,
                color: n.color, opacity: n.opacity, title: n.title,
                displayTitle: n.displayTitle, labelVisible: labeledIDs.contains(n.id),
                symbol: n.symbol, isSelected: n.isSelected, isHovered: n.isHovered,
                isFocused: n.isFocused, isWorkspace: n.isWorkspace,
                importance: n.importance, clusterId: n.clusterId,
                distance: n.distance, activityIntensity: n.activityIntensity,
                isRecent: n.isRecent, relevance: n.relevance)
            return copy
        }

        // Final z-order sort
        renderNodes.sort { a, b in
            let rank: (GraphRenderState.RenderNode) -> Int = { n in
                if n.isFocused { return 4 }
                if n.isSelected { return 3 }
                if n.isPrimary { return 2 }
                if n.isHovered { return 1 }
                return 0
            }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
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
            let rel = max(relevance[e.sourceID] ?? 0.45, relevance[e.targetID] ?? 0.45)
            var baseOpacity = min(0.05 + e.strength * 0.42, 0.6)
            if e.isRecent, level != .overview { baseOpacity = min(baseOpacity + 0.12, 0.75) }
            if rel > 0.68, level != .overview { baseOpacity = min(baseOpacity + 0.10, 0.72) }
            else if rel > 0.50 { baseOpacity = min(baseOpacity + 0.05, 0.65) }
            if rel < 0.35, !isHighlighted { baseOpacity *= 0.85 }
            let opacity = isDimmed ? baseOpacity * 0.25 : (isHighlighted ? min(baseOpacity * 1.7, 0.85) : baseOpacity)
            var style: GraphRenderState.EdgeStyle = {
                if e.strength >= 0.7 { return .solid }
                if e.strength >= 0.4 { return .dashed }
                return .dotted
            }()
            if rel > 0.65, style == .dotted, level != .overview { style = .dashed }
            if e.isRecent, style == .dotted, level != .overview { style = .dashed }
            if level == .overview, style == .dotted { return nil }
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

// MARK: - Palette cache

/// Resolved palette for the current environment, captured on the main
/// actor at render time. Reading from the environment inside a Canvas
/// closure is unreliable, so we cache and refresh at the SwiftUI layer.
struct GraphPalette {
    let graphWorkspace: Color
    let graphFile: Color
    let graphSession: Color
    let graphExecution: Color
    let graphMemory: Color
    let graphIntelligence: Color
    let graphEvent: Color
    let graphEdge: Color
    let graphEdgeHighlight: Color
    let graphEdgeAmbient: Color
    let graphHalo: Color
    let graphCluster: Color
    let graphFocus: Color

    func color(for token: String) -> Color {
        switch token {
        case CSColor.graphWorkspace:    graphWorkspace
        case CSColor.graphFile:         graphFile
        case CSColor.graphSession:      graphSession
        case CSColor.graphExecution:    graphExecution
        case CSColor.graphMemory:       graphMemory
        case CSColor.graphIntelligence: graphIntelligence
        case CSColor.graphEvent:        graphEvent
        case CSColor.graphEdge:         graphEdge
        case CSColor.graphEdgeHighlight: graphEdgeHighlight
        case CSColor.graphEdgeAmbient:  graphEdgeAmbient
        case CSColor.graphHalo:         graphHalo
        case CSColor.graphCluster:      graphCluster
        case CSColor.graphFocus:        graphFocus
        default:                        graphFile
        }
    }
}

@MainActor
enum GraphPaletteCache {
    static func palette() -> GraphPalette {
        // Tokens are resolved against the cached appearance at the
        // time the SwiftUI body renders, then frozen into the render
        // state. Canvas drawing itself never reads the environment.
        return GraphPalette(
            graphWorkspace:    Color.cs(CSColor.graphWorkspace),
            graphFile:         Color.cs(CSColor.graphFile),
            graphSession:      Color.cs(CSColor.graphSession),
            graphExecution:    Color.cs(CSColor.graphExecution),
            graphMemory:       Color.cs(CSColor.graphMemory),
            graphIntelligence: Color.cs(CSColor.graphIntelligence),
            graphEvent:        Color.cs(CSColor.graphEvent),
            graphEdge:         Color.cs(CSColor.graphEdge),
            graphEdgeHighlight: Color.cs(CSColor.graphEdgeHighlight),
            graphEdgeAmbient:  Color.cs(CSColor.graphEdgeAmbient),
            graphHalo:         Color.cs(CSColor.graphHalo),
            graphCluster:      Color.cs(CSColor.graphCluster),
            graphFocus:        Color.cs(CSColor.graphFocus)
        )
    }
}

// MARK: - Label formatting

enum GraphLabelFormatter {
    /// Returns a short, readable label for a node. For file nodes this
    /// shows the last path component; full path lives in the inspector.
    /// Long labels are truncated with an ellipsis to keep the canvas
    /// legible at any zoom.
    static func displayTitle(for node: GraphVisualizationModel.VisualNode) -> String {
        let title = node.title
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if node.nodeType == .file {
            let last = (trimmed as NSString).lastPathComponent
            return last.isEmpty ? trimmed : last
        }
        if trimmed.count > 36 {
            return String(trimmed.prefix(35)) + "…"
        }
        return trimmed
    }
}
