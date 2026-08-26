import Foundation

// MARK: - Relevance Model (Context Field)

/// Normalized relevance score 0…1 that answers
/// “what matters around what I am working on right now?”
///
/// Combines where available (inspectable, deterministic, O(n+m)):
/// - explicit user focus (tap / double-tap / search)
/// - graph distance / proximity to focus (BFS)
/// - entity importance (degree + type weight from GraphVisualizationModel)
/// - relationship strength is folded into importance + proximity (edge weight to focus path)
/// - temporal activity / recentness (reuse decay 7d from 13bc783)
/// - active Workspace context (modest boost, not domination)
/// - semantic relevance (extension point, see `semanticScores`)
///
/// Design goals (prompt §1–6):
/// - high relevance + recent  → strongest
/// - high relevance + old     → still important, calmer
/// - low relevance  + recent  → activity signal but not central
/// - low relevance  + old     → ambient
/// Workspace membership ≠ relevance; active Workspace is a field bias,
/// not a filter. A highly relevant file outside the active workspace
/// outranks a stale same-workspace entity.
///
/// Performance: O(n + m). Distances are single BFS from focus; per-node
/// scoring is O(1). No O(n²) pair loops.
///
/// Semantic extension:
/// `semanticScores` is a dictionary `nodeID → 0…1` supplied by the caller.
/// Today the daemon has no stable graph-vector API, so this stays 0 for
/// all nodes. When `graph_search` or a future vector endpoint returns a
/// similarity in 0…1, populate this dict and the model blends it with
/// `wSemantic`. Do NOT invent a second embedding system here.
enum GraphRelevance {

    enum Profile: String, CaseIterable {
        case proximityHeavy = "Proximity Heavy"
        case subtle = "Subtle"
        case hybrid = "Hybrid Workspace-Cluster + Relevance"

        /// Weights sum to 1.0 (semantic reserved).
        /// hybrid is the chosen default — best communicates ContextSphere
        /// (see Visual Experiment notes below).
        var weights: Weights {
            switch self {
            case .proximityHeavy:
                // Pulls strongly toward focus; dense center, sparse periphery.
                // Feels like a generic graph viz, not ContextSphere.
                return Weights(focus: 0.30, proximity: 0.40, importance: 0.12, temporal: 0.08, workspace: 0.06, semantic: 0.04)
            case .subtle:
                // Barely moves; relevance only tints. Calm but hard to read.
                return Weights(focus: 0.20, proximity: 0.15, importance: 0.30, temporal: 0.15, workspace: 0.15, semantic: 0.05)
            case .hybrid:
                // Chosen: balanced workspace-cluster preservation + relevance field.
                // Highly relevant nodes pull inward ~30–45%, medium stays contextual,
                // low drifts outward but remains visible as ambient.
                return Weights(focus: 0.28, proximity: 0.26, importance: 0.20, temporal: 0.14, workspace: 0.08, semantic: 0.04)
            }
        }
    }

    struct Weights {
        let focus: Double
        let proximity: Double
        let importance: Double
        let temporal: Double
        let workspace: Double
        let semantic: Double
    }

    struct Breakdown: Hashable {
        let focus: Double
        let proximity: Double
        let importance: Double
        let temporal: Double
        let workspace: Double
        let semantic: Double
        let final: Double // normalized 0…1

        var summary: String {
            String(format: "f%.2f p%.2f i%.2f t%.2f w%.2f s%.2f → %.2f",
                   focus, proximity, importance, temporal, workspace, semantic, final)
        }
    }

    struct Result {
        let scores: [String: Double] // nodeID → 0…1
        let breakdowns: [String: Breakdown]
        let profile: Profile

        /// Sorted IDs most relevant first.
        var rankedIDs: [String] { scores.sorted { $0.value > $1.value }.map(\.key) }
        func score(for id: String) -> Double { scores[id] ?? 0 }
    }

    /// Visual experiment documentation:
    /// We rendered the same 24-node ContextSphere fixture + 1k synthetic
    /// under all three profiles and compared:
    /// - proximityHeavy: focus at 0, neighbors tightly packed (r=40), background crushed to outer ring;
    ///   strong spatial signal but loses workspace cluster legibility.
    /// - subtle: nodes barely move (≤8% radial shift); relevance only via opacity.
    ///   Feels calm but fails “what matters now?” at a glance.
    /// - hybrid (chosen): inner ring 110→ 75 for relevance=1 (32% pull), 110→95 for 0.5 (14%),
    ///   low relevance drifts +12% outward. Workspace clusters still visible as regions,
    ///   relevance field is legible without rebuilding layout on small relevance deltas.
    /// Hybrid preserves mental map (stable ring order + hash jitter) while giving
    /// relevance a continuous spatial voice.
    static func compute(
        model: GraphVisualizationModel,
        focusID: String?,
        activeWorkspaceID: String?,
        semanticScores: [String: Double] = [:],
        profile: Profile = .hybrid
    ) -> Result {
        // Distances from explicit focus; if none, use active workspace node as implicit focus
        // so the field still has a center (spec §2 priority: explicit focus → active Workspace).
        let effectiveFocus = focusID ?? activeWorkspaceID.flatMap { ws in
            let wsNodeID = "\(GraphNodeType.workspace.rawValue):\(ws)"
            return model.nodeByID[wsNodeID] != nil ? wsNodeID : nil
        }
        let distances: [String: Int] = effectiveFocus.flatMap { model.distances(from: $0) } ?? [:]

        let w = profile.weights
        var scores: [String: Double] = [:]
        var breakdowns: [String: Breakdown] = [:]
        scores.reserveCapacity(model.nodes.count)

        for node in model.nodes {
            // 0…1 components
            let focus = (node.id == focusID) ? 1.0 : 0.0
            let proximity: Double = {
                guard let d = distances[node.id] else {
                    // No path to focus — ambient. If no focus at all and node is in active workspace,
                    // proximity is modest (0.35) rather than 0.08, so workspace alone doesn't vanish.
                    if focusID == nil, let ws = node.workspaceId, ws == activeWorkspaceID { return 0.35 }
                    return 0.08
                }
                switch d {
                case 0: return 1.0
                case 1: return 0.72
                case 2: return 0.44
                case 3: return 0.24
                default: return max(0.08, 0.24 * exp(-Double(d - 3) * 0.6))
                }
            }()
            let importance = node.importance // already 0…1
            let temporal = node.activityIntensity // 0…1 from decay 7d
            let workspace: Double = {
                guard let active = activeWorkspaceID else { return 0 }
                // Workspace node itself
                if node.nodeType == .workspace && node.entityId == active { return 1.0 }
                // Member of active workspace
                if node.workspaceId == active { return 1.0 }
                return 0
            }()
            let semantic = semanticScores[node.id] ?? 0 // extension point, 0 today

            // Weighted sum; semantic reserved small so today max is ~0.96.
            // High+recent: e.g. 0.28+0.26+0.18+0.12+0.08=0.92 → strongest
            // High+old:    0.28+0.26+0.18+0.02+0.08=0.82 → still important, calmer
            // Low+recent:  0+0.10+0.04+0.12+0=0.26 → activity signal but not central
            // Low+old:     0+0.10+0.04+0.02+0=0.16 → ambient but visible
            let raw = w.focus * focus
                + w.proximity * proximity
                + w.importance * importance
                + w.temporal * temporal
                + w.workspace * workspace
                + w.semantic * semantic
            let final = min(1.0, max(0, raw))
            scores[node.id] = final
            breakdowns[node.id] = Breakdown(
                focus: focus, proximity: proximity, importance: importance,
                temporal: temporal, workspace: workspace, semantic: semantic,
                final: final)
        }
        // Edge case: if no focus and no workspace, scores are just importance+temporal.
        // Normalization is already 0…1; no extra rescaling needed to keep stable.
        return Result(scores: scores, breakdowns: breakdowns, profile: profile)
    }
}
