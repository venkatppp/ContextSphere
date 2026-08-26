import Foundation

/// Small adapter that connects existing ContextSphere retrieval to the graph
/// relevance field. Reuses the daemon's vector/FTS infrastructure — does
/// not create a new embedding system, vector DB, or FTS index.
///
/// Desired flow (real embeddings when available):
///   current focus / search text
///        ↓
///   existing retrieval (`graph_ai_vector_search` [ONNX all-MiniLM-L6-v2 384-d, cosine 0…1]
///                       → `graph_vector_search` [hash fallback, threshold 0.20]
///                       → `graph_ranked_search` [keyword])
///        ↓
///   ranked hits + similarity 0…1
///        ↓
///   [nodeID: Double]
///        ↓
///   GraphRelevance.semanticScores
///        ↓
///   Context Field
///
/// All queries are bounded top-K 20 and cached per focus/search value so
/// semantic relevance never becomes O(n²). When the ONNX model is not
/// downloaded/loaded, `graph_ai_vector_search` returns empty and the adapter
/// falls back to the hash vector search (still functional, but near-random).
enum GraphSemanticAdapter {
    static let defaultLimit: UInt32 = 20
    /// Minimum score surfaced by the backend vector search (KgOptService::VECTOR_HIT_THRESHOLD).
    static let vectorThreshold: Double = 0.20
    /// Cache for last successful fetch to avoid repeated RPC for same query.
    private static var cache: [String: [String: Double]] = [:]

    /// Fetches semantic scores for a query string.
    ///
    /// Source score: `RankedSearchHit.score` is already normalized 0…1
    /// - vector: cosine similarity 0…1 (rounded to 2 decimals, threshold 0.20)
    /// - ranked: keyword quality (title prefix 1.0, title contains 0.85, summary 0.6) + recency 0.05, clamp 0…1
    ///
    /// Normalization: keep `score` as is (`score.clamp(0,1)`). No rescaling;
    /// a 0.22 vector hit stays 0.22 (low but not ambient), 0.92 stays strong.
    /// Missing / not returned → 0 (ambient). Empty query → empty dict.
    ///
    /// Thresholds: backend filters `<0.20` for vector; ranked has no hard floor
    /// but we keep all returned hits (they are already relevance-sorted).
    /// We do not fake scores — if the RPC returns no hits, the dict is empty
    /// and relevance falls back to structural/temporal/workspace only.
    static func fetchScores(for query: String, limit: UInt32 = defaultLimit) async -> [String: Double] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        let key = "\(trimmed.lowercased())#\(limit)"
        if let cached = cache[key] { return cached }

        // Prefer real ONNX vector search; fall back to hash vector then keyword.
        if let aiScores = await aiVectorScores(for: trimmed, limit: limit), !aiScores.isEmpty {
            cache[key] = aiScores
            return aiScores
        }
        if let vectorScores = await vectorScores(for: trimmed, limit: limit), !vectorScores.isEmpty {
            cache[key] = vectorScores
            return vectorScores
        }
        if let rankedScores = await rankedScores(for: trimmed, limit: limit) {
            cache[key] = rankedScores
            return rankedScores
        }
        return [:]
    }

    /// Convenience for focus-driven semantic context: uses the focused node's
    /// title (and summary if present) as the query. Keeps the same bounded
    /// top-K and caching behavior — one RPC per focus change, not per node.
    static func fetchScores(forFocusNode node: KgNode, limit: UInt32 = defaultLimit) async -> [String: Double] {
        // Use title as primary query; if summary exists, append first 80 chars for richer context.
        var query = node.title
        if let summary = node.summary, !summary.isEmpty {
            let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSummary.isEmpty {
                query += " " + String(trimmedSummary.prefix(80))
            }
        }
        return await fetchScores(for: query, limit: limit)
    }

    // MARK: - Private vector / ranked fetch

    private static func aiVectorScores(for query: String, limit: UInt32) async -> [String: Double]? {
        do {
            let hits: [RankedSearchHit] = try await CoreBridge.shared.request(
                "graph_ai_vector_search",
                params: ["query": query, "limit": limit],
                as: [RankedSearchHit].self)
            if hits.isEmpty { return nil } // no ONNX model loaded or no hits
            var dict: [String: Double] = [:]
            dict.reserveCapacity(hits.count)
            for hit in hits {
                let s = min(1.0, max(0, hit.score))
                guard s >= vectorThreshold - 0.001 else { continue }
                dict[hit.node.id] = s
            }
            return dict.isEmpty ? nil : dict
        } catch {
            return nil // RPC not yet available or model not loaded — fallback
        }
    }

    private static func vectorScores(for query: String, limit: UInt32) async -> [String: Double]? {
        do {
            let hits: [RankedSearchHit] = try await CoreBridge.shared.request(
                "graph_vector_search",
                params: ["query": query, "limit": limit],
                as: [RankedSearchHit].self)
            // Empty when no embedder — treat as unavailable, let caller try ranked.
            if hits.isEmpty { return nil }
            var dict: [String: Double] = [:]
            dict.reserveCapacity(hits.count)
            for hit in hits {
                let s = min(1.0, max(0, hit.score))
                // Respect backend threshold even if it shifts — ignore <0.20 just in case cache has stale.
                guard s >= vectorThreshold - 0.001 else { continue }
                dict[hit.node.id] = s
            }
            return dict
        } catch {
            // Best-effort: vector search is optional; silently fall back.
            return nil
        }
    }

    private static func rankedScores(for query: String, limit: UInt32) async -> [String: Double]? {
        do {
            let hits: [RankedSearchHit] = try await CoreBridge.shared.request(
                "graph_ranked_search",
                params: ["query": query, "limit": limit],
                as: [RankedSearchHit].self)
            var dict: [String: Double] = [:]
            dict.reserveCapacity(hits.count)
            for hit in hits {
                dict[hit.node.id] = min(1.0, max(0, hit.score))
            }
            // Return even if empty — it is a valid result (no matches).
            return dict
        } catch {
            return nil
        }
    }

    /// Clears the in-memory cache (e.g. after a graph sync that adds many nodes).
    static func invalidateCache() { cache.removeAll() }
}
