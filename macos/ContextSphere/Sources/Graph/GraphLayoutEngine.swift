import Foundation
import CoreGraphics

// MARK: - Layout engine (prompt §15)

/// Hybrid layout for the Context Field (prompt §6).
///
/// Stages:
///  1. Semantic hierarchy — workspace nodes anchor their clusters.
///  2. Community clustering — by workspaceId (future: Louvain on topics).
///  3. Force simulation — springs on strong edges + repulsion (deterministic).
///  4. Focus transformation — when a focus node is set, re-center into a
///     radial layout around it (Handshake-like exploration).
///
/// Pure functions, deterministic, off-main-thread safe. No SwiftUI.
enum GraphLayoutEngine {
    static let worldWidth: CGFloat = 1400
    static let worldHeight: CGFloat = 900

    /// Entry point used by the view model. Relevance is a 0…1 field per node.
    static func layout(model: GraphVisualizationModel,
                       existing: [String: CGPoint] = [:],
                       anchorID: String? = nil,
                       focusID: String? = nil,
                       relevance: [String: Double] = [:]) -> [String: CGPoint] {
        // If focused, prefer relevance-aware radial focus layout
        if let focusID, model.nodeByID[focusID] != nil {
            return focusRadialLayout(model: model, focusID: focusID, existing: existing, relevance: relevance)
        }
        // Otherwise hybrid workspace-cluster + relevance pipeline
        let nodes = model.nodes.map { vn in
            GraphLayout.NodeInput(id: vn.id, nodeType: vn.nodeType,
                                   workspaceId: vn.workspaceId, entityId: vn.entityId,
                                   isWorkspace: vn.isWorkspace)
        }
        let edges = model.edges.map { e in
            GraphLayout.EdgeInput(source: e.sourceID, target: e.targetID, weight: e.weight)
        }
        return GraphLayout.layout(nodes: nodes, edges: edges, existing: existing, anchorID: anchorID, relevance: relevance)
    }

    // MARK: Radial focus layout

    private static func focusRadialLayout(model: GraphVisualizationModel,
                                           focusID: String,
                                           existing: [String: CGPoint],
                                           relevance: [String: Double] = [:]) -> [String: CGPoint] {
        let distances = model.distances(from: focusID)
        // Group by distance: 0 = focus, 1 = neighbors, 2 = second-degree, nil = background
        var rings: [Int: [GraphVisualizationModel.VisualNode]] = [:]
        var background: [GraphVisualizationModel.VisualNode] = []
        for n in model.nodes {
            if let d = distances[n.id] { rings[d, default: []].append(n) }
            else { background.append(n) }
        }
        var positions: [String: CGPoint] = [:]

        // Focus at origin
        positions[focusID] = .zero

        // Relevance as continuous field: highly relevant pulls inward ~30%,
        // medium stays, low drifts outward but remains visible (ambient).
        func relevancePull(_ id: String, base: CGFloat) -> CGFloat {
            let rel = relevance[id] ?? 0.5 // neutral if missing
            // 1.15 at rel 0 → +15% outward (ambient still visible)
            // 0.70 at rel 1 → –30% inward (strong pull)
            let factor = 1.15 - CGFloat(rel) * 0.45
            return base * factor
        }

        // Ring radii grow with distance; inner rings carry neighbors
        let radii: [Int: CGFloat] = [1: 110, 2: 230, 3: 360]
        for dist in [1, 2, 3] {
            guard let members = rings[dist], !members.isEmpty else { continue }
            // Sort by relevance then importance so most relevant neighbors are at "north"
            let sorted = members.sorted {
                let ra = relevance[$0.id] ?? 0, rb = relevance[$1.id] ?? 0
                if abs(ra - rb) > 0.08 { return ra > rb }
                return $0.importance > $1.importance
            }
            let baseRadius = radii[dist] ?? 360 + CGFloat(dist - 3) * 70
            // Distribute evenly, offset by hash for stability
            let offset = CGFloat(fnv1a(focusID) % 360) * .pi / 180
            for (idx, node) in sorted.enumerated() {
                if node.id == focusID { continue }
                let angle = offset + 2 * .pi * CGFloat(idx) / CGFloat(sorted.count)
                // Add small jitter seeded by node id so coincident rings don't stack
                let jitter = CGFloat(Int(fnv1a(node.id) % 20) - 10)
                let base = baseRadius + jitter
                let r = relevancePull(node.id, base: base)
                positions[node.id] = CGPoint(x: cos(angle) * r, y: sin(angle) * r)
            }
        }

        // Background nodes: place in a faint outer circle, spread widely, but
        // highly relevant background nodes are pulled inward so a relevant file
        // outside the immediate cluster does not stay crushed at the edge.
        if !background.isEmpty {
            let outerRadius: CGFloat = 520
            let sortedBG = background.sorted {
                let ra = relevance[$0.id] ?? 0, rb = relevance[$1.id] ?? 0
                if abs(ra - rb) > 0.08 { return ra > rb }
                return fnv1a($0.id) < fnv1a($1.id)
            }
            for (idx, node) in sortedBG.enumerated() {
                let angle = 2 * .pi * CGFloat(idx) / CGFloat(sortedBG.count) + 0.17
                let base = outerRadius + CGFloat(fnv1a(node.id) % 120)
                let r = relevancePull(node.id, base: base)
                positions[node.id] = CGPoint(x: cos(angle) * r, y: sin(angle) * r)
            }
        }

        // Gentle relaxation so rings don't overlap, but preserve focus centricity.
        // For large graphs (>800) skip O(n²) relaxation entirely — ring
        // placement alone is sufficient and keeps the prototype interactive.
        if model.nodes.count <= 800 {
            var pinned = positions
            let edges = model.edges.filter { positions[$0.sourceID] != nil && positions[$0.targetID] != nil }
                .map { GraphLayout.EdgeInput(source: $0.sourceID, target: $0.targetID, weight: $0.weight) }
            let inputs = model.nodes.map { vn in
                GraphLayout.NodeInput(id: vn.id, nodeType: vn.nodeType,
                                      workspaceId: vn.workspaceId, entityId: vn.entityId,
                                      isWorkspace: vn.isWorkspace)
            }
            let iters = model.nodes.count > 400 ? 15 : 40
            relaxFocus(positions: &pinned, nodes: inputs, edges: edges, focusID: focusID, iterations: iters)
            return normalizeCentered(pinned, focusID: focusID)
        } else {
            return normalizeCentered(positions, focusID: focusID)
        }
    }

    private static func relaxFocus(positions: inout [String: CGPoint],
                                   nodes: [GraphLayout.NodeInput],
                                   edges: [GraphLayout.EdgeInput],
                                   focusID: String,
                                   iterations: Int) {
        let ids = nodes.map(\.id)
        var velocities: [String: CGPoint] = [:]
        // Build springs like GraphLayout
        var springMap: [String: [(String, CGFloat)]] = [:]
        for e in edges {
            springMap[e.source, default: []].append((e.target, e.weight))
            springMap[e.target, default: []].append((e.source, e.weight))
        }
        let focusPos = positions[focusID] ?? .zero
        for _ in 0..<iterations {
            var forces: [String: CGPoint] = [:]
            // Repulsion (soft)
            for (i, a) in ids.enumerated() where a != focusID {
                guard let pa = positions[a] else { continue }
                for b in ids[(i+1)...] where b != focusID {
                    guard let pb = positions[b] else { continue }
                    let dx = pa.x - pb.x, dy = pa.y - pb.y
                    let d2 = max(dx*dx + dy*dy, 900)
                    let f = min(4.0, 80000 / d2)
                    let fx = dx / sqrt(d2) * f
                    let fy = dy / sqrt(d2) * f
                    forces[a, default: .zero] = CGPoint(x: (forces[a]?.x ?? 0) + fx,
                                                       y: (forces[a]?.y ?? 0) + fy)
                    forces[b, default: .zero] = CGPoint(x: (forces[b]?.x ?? 0) - fx,
                                                       y: (forces[b]?.y ?? 0) - fy)
                }
            }
            // Springs
            for (id, springs) in springMap where id != focusID {
                guard let p = positions[id] else { continue }
                var fx: CGFloat = 0, fy: CGFloat = 0
                for (other, w) in springs.prefix(10) {
                    guard let q = positions[other] else { continue }
                    let dx = q.x - p.x, dy = q.y - p.y
                    let d = max(sqrt(dx*dx + dy*dy), 1)
                    fx += dx / d * (d - 115) * 0.03 * CGFloat(w)
                    fy += dy / d * (d - 115) * 0.03 * CGFloat(w)
                }
                forces[id, default: .zero] = CGPoint(x: (forces[id]?.x ?? 0) + fx,
                                                   y: (forces[id]?.y ?? 0) + fy)
            }
            // Integrate with damping, keep focus pinned
            for id in ids where id != focusID {
                guard let f = forces[id] else { continue }
                var v = velocities[id, default: .zero]
                v.x = (v.x + f.x) * 0.82
                v.y = (v.y + f.y) * 0.82
                let speed = sqrt(v.x*v.x + v.y*v.y)
                let cap: CGFloat = 6
                if speed > cap { v.x *= cap / speed; v.y *= cap / speed }
                velocities[id] = v
                positions[id] = CGPoint(x: positions[id]!.x + v.x, y: positions[id]!.y + v.y)
            }
            positions[focusID] = focusPos
        }
    }

    private static func normalizeCentered(_ positions: [String: CGPoint],
                                          focusID: String) -> [String: CGPoint] {
        guard let focus = positions[focusID] else { return positions }
        var shifted: [String: CGPoint] = [:]
        for (k, p) in positions { shifted[k] = CGPoint(x: p.x - focus.x, y: p.y - focus.y) }
        // Scale to fit world box (keep focus at center, so scale uniformly around origin)
        var maxR: CGFloat = 0
        for p in shifted.values { maxR = max(maxR, hypot(p.x, p.y)) }
        let targetR = min(worldWidth, worldHeight) / 2 - 60
        let scale = maxR > 0 ? min(1.0, targetR / maxR) : 1.0
        var result: [String: CGPoint] = [:]
        for (k, p) in shifted { result[k] = CGPoint(x: p.x * scale, y: p.y * scale) }
        return result
    }

    // MARK: Deterministic hash (stable across runs)

    private static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }
}
