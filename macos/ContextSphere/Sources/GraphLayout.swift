import Foundation
import CoreGraphics

/// Deterministic, dependency-free graph layout.
///
/// Pipeline (all pure, runs off the main thread):
/// 1. Cluster nodes by workspace.
/// 2. Lay each cluster as rings around its workspace node.
/// 3. Arrange clusters around a center circle.
/// 4. Optional light force relaxation (springs on the strongest edges,
///    pair repulsion) with a fixed iteration count and a seeded PRNG —
///    same input always yields the same output.
///
/// For incremental expansion, pass `existing` positions: new nodes are
/// placed in rings around the anchor and a gentler relaxation pass lets
/// the graph settle without violently moving what is already there.
enum GraphLayout {
    struct NodeInput {
        let id: String
        let nodeType: GraphNodeType
        let workspaceId: String?
        let entityId: String
        let isWorkspace: Bool
    }

    struct EdgeInput {
        let source: String
        let target: String
        let weight: Double
    }

    /// World-space box the layout is normalized into.
    static let worldWidth: CGFloat = 1400
    static let worldHeight: CGFloat = 900

    private static let nodeCountLimitForRelaxation = 400
    private static let springsPerNode = 12
    private static let restLength: CGFloat = 115

    static func layout(nodes: [NodeInput], edges: [EdgeInput],
                       existing: [String: CGPoint] = [:],
                       anchorID: String? = nil,
                       relevance: [String: Double] = [:]) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }

        var positions = existing
        let known = Set(nodes.map(\.id))

        // Place nodes that are new (not in `existing`).
        let newcomers = nodes.filter { positions[$0.id] == nil }
        if !newcomers.isEmpty, let anchorID, let anchor = positions[anchorID] {
            placeAroundAnchor(newcomers, anchor: anchor, into: &positions)
        }
        for node in newcomers where positions[node.id] == nil {
            positions[node.id] = CGPoint(x: CGFloat(fnv1a(node.id) % 1000) - 500,
                                         y: CGFloat(fnv1a("\(node.id).y") % 800) - 400)
        }

        // Full (re)layout when nothing exists yet.
        if existing.isEmpty {
            positions = clusterLayout(nodes: nodes, relevance: relevance)
        }

        // Relaxation.
        if nodes.count <= nodeCountLimitForRelaxation {
            let springMap = buildSprings(nodes: nodes, edges: edges, positions: positions)
            let incremental = !existing.isEmpty
            relax(positions: &positions, nodes: nodes, springMap: springMap,
                  iterations: incremental ? 45 : 110,
                  maxStep: incremental ? 5 : 12)
        }

        // Only return positions for known nodes.
        return positions.filter { known.contains($0.key) }
    }

    // MARK: - Cluster + ring layout

    private static func clusterLayout(nodes: [NodeInput], relevance: [String: Double] = [:]) -> [String: CGPoint] {
        var clusters: [String: [NodeInput]] = [:]
        for node in nodes {
            let key = node.workspaceId ?? "orphan:\(node.nodeType.rawValue)"
            clusters[key, default: []].append(node)
        }

        // Cluster heads: workspace nodes anchor their cluster.
        var clusterCenters: [(key: String, radius: CGFloat)] = []
        for (key, members) in clusters.sorted(by: { fnv1a($0.key) < fnv1a($1.key) }) {
            clusterCenters.append((key, clusterRadius(members: members)))
        }

        let count = clusterCenters.count
        let maxRadius = clusterCenters.map(\.radius).max() ?? 200
        let gap: CGFloat = 130
        let ringRadius: CGFloat
        if count <= 1 {
            ringRadius = 0
        } else {
            let numerator = maxRadius * 2 + gap
            ringRadius = numerator / (2 * sin(.pi / CGFloat(count)))
        }

        var result: [String: CGPoint] = [:]
        for (index, cluster) in clusterCenters.enumerated() {
            let angle = 2 * .pi * CGFloat(index) / CGFloat(max(count, 1))
            let center = CGPoint(x: cos(angle) * ringRadius,
                                 y: sin(angle) * ringRadius)
            for member in clusters[cluster.key] ?? [] {
                let local = placeClusterSingle(member, in: clusters[cluster.key] ?? [], relevance: relevance)
                result[member.id] = CGPoint(x: center.x + local.x, y: center.y + local.y)
            }
        }
        return normalize(result)
    }

    private static func placeClusterSingle(_ node: NodeInput,
                                           in members: [NodeInput],
                                           relevance: [String: Double] = [:]) -> CGPoint {
        let head = members.first { $0.isWorkspace }
        if node.id == head?.id {
            return .zero
        }
        let nonHeads = members.filter { $0.id != head?.id }
        // Hybrid: relevance sorts inner vs outer ring, but workspace clusters remain legible.
        // Highly relevant → inner ring (smaller radius), low relevance → outer but still visible.
        let sorted = nonHeads.sorted {
            let ra = relevance[$0.id] ?? 0.5, rb = relevance[$1.id] ?? 0.5
            if abs(ra - rb) > 0.07 { return ra > rb }
            return fnv1a($0.id) < fnv1a($1.id)
        }
        guard let index = sorted.firstIndex(where: { $0.id == node.id }) else { return .zero }
        let (baseRadius, capacity, offset) = ringGeometry(index: index)
        // Subtle relevance radius tweak within ring: relevant ~ -8, ambient ~ +8 (preserves ring)
        let rel = relevance[node.id] ?? 0.5
        let tweak = (0.5 - CGFloat(rel)) * 16 // -8 at 1.0, +8 at 0.0
        let radius = baseRadius + tweak
        let angle = offset + 2 * .pi * CGFloat(index) / CGFloat(capacity)
        return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
    }

    /// Rings grow outward; ring i holds 8 + 12*i nodes. The golden-angle
    /// offset (seeded per cluster) keeps successive rings from aligning.
    private static func ringGeometry(index: Int) -> (radius: CGFloat, capacity: Int, offset: CGFloat) {
        var ring = 0
        var capacity = 8
        var remaining = index
        var radius: CGFloat = 95
        while remaining >= capacity {
            remaining -= capacity
            ring += 1
            capacity = 8 + 12 * ring
            radius += 62
        }
        let offset = CGFloat(ring) * 2.39996
        return (radius, max(capacity, 1), offset)
    }

    private static func clusterRadius(members: [NodeInput]) -> CGFloat {
        var ring = 0
        var capacity = 8
        var remaining = members.count - 1
        var radius: CGFloat = 95
        while remaining > capacity {
            remaining -= capacity
            ring += 1
            capacity = 8 + 12 * ring
            radius += 62
        }
        return radius + 40
    }

    private static func normalize(_ positions: [String: CGPoint]) -> [String: CGPoint] {
        guard !positions.isEmpty else { return positions }
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for point in positions.values {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let spanX = max(maxX - minX, 1)
        let spanY = max(maxY - minY, 1)
        let scale = min(worldWidth / spanX, worldHeight / spanY)
        let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        var result: [String: CGPoint] = [:]
        for (key, point) in positions {
            result[key] = CGPoint(x: (point.x - center.x) * scale, y: (point.y - center.y) * scale)
        }
        return result
    }

    // MARK: - Relaxation

    private static func buildSprings(nodes: [NodeInput], edges: [EdgeInput],
                                     positions: [String: CGPoint]) -> [String: [(String, CGFloat)]] {
        var perNode: [String: [(String, CGFloat)]] = [:]
        for edge in edges {
            guard positions[edge.source] != nil, positions[edge.target] != nil else { continue }
            perNode[edge.source, default: []].append((edge.target, edge.weight))
            perNode[edge.target, default: []].append((edge.source, edge.weight))
        }
        for (id, springs) in perNode {
            perNode[id] = Array(springs.sorted { $0.1 > $1.1 }.prefix(springsPerNode))
        }
        return perNode
    }

    private static func relax(positions: inout [String: CGPoint], nodes: [NodeInput],
                              springMap: [String: [(String, CGFloat)]],
                              iterations: Int, maxStep: CGFloat) {
        let ids = nodes.map(\.id)
        let velocityScale: CGFloat = 0.85
        var velocities: [String: CGPoint] = [:]
        var rng = SplitMix64(seed: 0x9E3779B97F4A7C15)

        for _ in 0..<iterations {
            var forces: [String: CGPoint] = [:]
            for (index, a) in ids.enumerated() {
                guard let pa = positions[a] else { continue }
                for b in ids[(index + 1)...] {
                    guard let pb = positions[b] else { continue }
                    let dx = pa.x - pb.x, dy = pa.y - pb.y
                    let d2 = max(dx * dx + dy * dy, 400)
                    let f = min(9.0, 140000.0 / d2)
                    let fx = dx / sqrt(d2) * f
                    let fy = dy / sqrt(d2) * f
                    forces[a, default: .zero] = CGPoint(x: fx, y: fy)
                    forces[b, default: .zero] = CGPoint(x: -fx, y: -fy)
                }
            }
            for (id, springs) in springMap {
                guard let p = positions[id] else { continue }
                var fx: CGFloat = 0, fy: CGFloat = 0
                for (otherID, weight) in springs {
                    guard let q = positions[otherID] else { continue }
                    let dx = q.x - p.x, dy = q.y - p.y
                    let d = max(sqrt(dx * dx + dy * dy), 1)
                    let f = (d - restLength) * 0.045 * CGFloat(weight)
                    fx += dx / d * f
                    fy += dy / d * f
                }
                forces[id, default: .zero] = CGPoint(x: fx, y: fy)
            }
            for id in ids {
                guard let f = forces[id] else { continue }
                var v = velocities[id, default: .zero]
                v.x = (v.x + f.x) * velocityScale
                v.y = (v.y + f.y) * velocityScale
                let speed = sqrt(v.x * v.x + v.y * v.y)
                if speed > maxStep {
                    v.x *= maxStep / speed
                    v.y *= maxStep / speed
                }
                velocities[id] = v
                positions[id] = CGPoint(x: positions[id]!.x + v.x, y: positions[id]!.y + v.y)
                _ = rng.next()
            }
        }
    }

    private static func placeAroundAnchor(_ nodes: [NodeInput], anchor: CGPoint,
                                          into positions: inout [String: CGPoint]) {
        let sorted = nodes.sorted { fnv1a($0.id) < fnv1a($1.id) }
        for (index, node) in sorted.enumerated() {
            let (radius, capacity, offset) = ringGeometry(index: index)
            let angle = offset + 2 * .pi * CGFloat(index) / CGFloat(capacity)
            positions[node.id] = CGPoint(x: anchor.x + cos(angle) * radius,
                                         y: anchor.y + sin(angle) * radius)
        }
    }

    // MARK: - Deterministic hashing

    /// FNV-1a 64-bit — deterministic across runs (Swift's `hashValue`
    /// is seeded per process and must not be used for layout).
    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

/// Deterministic split-mix PRNG (fixed seed) so relaxation output is
/// reproducible for the same node set.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}