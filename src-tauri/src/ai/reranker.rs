//! Reranker for improving search result quality - Real ONNX implementation.

use std::path::PathBuf;
use std::sync::Arc;

use parking_lot::Mutex;

use crate::ai::cache::InferenceCache;
use crate::ai::inference::RerankerInferenceEngine;
use crate::ai::models::{InferenceStats, RerankRequest, RerankResult};
use crate::errors::DatabaseError;

/// Cross-encoder reranker for search results with real ONNX inference.
pub struct Reranker {
    #[allow(dead_code)]
    model_id: String,
    engine: Arc<RerankerInferenceEngine>,
    cache: Arc<Mutex<InferenceCache<Vec<RerankResult>>>>,
    stats: Arc<Mutex<InferenceStats>>,
}

impl Reranker {
    /// Creates a new reranker with real ONNX inference.
    pub fn new(
        model_id: String,
        model_path: PathBuf,
        tokenizer_path: PathBuf,
        max_length: usize,
        enable_cache: bool,
        cache_size: usize,
    ) -> Result<Self, DatabaseError> {
        // Initialize the ONNX inference engine
        let engine = RerankerInferenceEngine::new(&model_path, &tokenizer_path, max_length)?;

        let cache = if enable_cache {
            InferenceCache::new(cache_size)
        } else {
            InferenceCache::new(0)
        };

        let stats = InferenceStats::new(model_id.clone(), crate::ai::models::ModelType::Reranker);

        Ok(Self {
            model_id,
            engine: Arc::new(engine),
            cache: Arc::new(Mutex::new(cache)),
            stats: Arc::new(Mutex::new(stats)),
        })
    }

    /// Reranks documents based on relevance to query using real ONNX inference.
    pub async fn rerank(&self, request: RerankRequest) -> Result<Vec<RerankResult>, DatabaseError> {
        let start = std::time::Instant::now();

        // Create cache key
        let cache_key = format!(
            "{}:{}:{}",
            request.query,
            request.documents.join("|"),
            request.top_k
        );

        // Check cache
        {
            let mut cache = self.cache.lock();
            if let Some(results) = cache.get(&cache_key) {
                let mut stats = self.stats.lock();
                stats.update_cache_hit();
                return Ok(results);
            }
        }

        // Cache miss - compute scores using real ONNX inference
        let results = self.rerank_with_inference(request).await?;

        // Store in cache
        {
            let mut cache = self.cache.lock();
            cache.put(cache_key, results.clone());
        }

        // Update stats
        {
            let mut stats = self.stats.lock();
            stats.update_cache_miss();
            stats.total_inferences += 1;
            stats.last_inference_at = Some(chrono::Utc::now());

            let latency = start.elapsed().as_millis() as f32;
            stats.avg_latency_ms = if stats.total_inferences == 1 {
                latency
            } else {
                (stats.avg_latency_ms * (stats.total_inferences - 1) as f32 + latency)
                    / stats.total_inferences as f32
            };
        }

        Ok(results)
    }

    /// Reranks using real ONNX cross-encoder inference.
    async fn rerank_with_inference(
        &self,
        request: RerankRequest,
    ) -> Result<Vec<RerankResult>, DatabaseError> {
        let engine = self.engine.clone();
        let query = request.query.clone();
        let documents = request.documents.clone();

        // Run inference in blocking task to avoid blocking async runtime
        let scores = tokio::task::spawn_blocking(move || {
            let doc_refs: Vec<&str> = documents.iter().map(|s| s.as_str()).collect();
            engine.score_batch(&query, &doc_refs)
        })
        .await
        .map_err(|e| DatabaseError::IoError(format!("Reranking task failed: {}", e)))??;

        // Create results with scores
        let mut results: Vec<RerankResult> = request
            .documents
            .iter()
            .enumerate()
            .zip(scores.iter())
            .map(|((index, document), score)| RerankResult {
                index,
                score: *score,
                document: document.clone(),
            })
            .collect();

        // Sort by score descending
        results.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        // Take top k
        results.truncate(request.top_k);

        Ok(results)
    }

    /// Gets inference statistics.
    pub fn get_stats(&self) -> InferenceStats {
        self.stats.lock().clone()
    }

    /// Clears the reranking cache.
    pub fn clear_cache(&self) {
        self.cache.lock().clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Note: These tests require actual ONNX models to be present.

    #[tokio::test]
    #[ignore] // Ignore by default since it requires downloaded models
    async fn real_reranking_works() {
        let candidates = vec![
            (
                PathBuf::from("test_models/bge-reranker-base/model.onnx"),
                PathBuf::from("test_models/bge-reranker-base/tokenizer.json"),
            ),
            (
                PathBuf::from("/Users/srivenkat/Library/Application Support/com.chronodesk.app/models/bge-reranker-base/model.onnx"),
                PathBuf::from("/Users/srivenkat/Library/Application Support/com.chronodesk.app/models/bge-reranker-base/tokenizer.json"),
            ),
        ];
        let (model_path, tokenizer_path) = match candidates.into_iter().find(|(m, t)| m.exists() && t.exists()) {
            Some((m, t)) => (m, t),
            None => return,
        };
        // Also handle HOME env for CI
        let home_candidates = std::env::var("HOME")
            .ok()
            .map(|h| {
                (
                    PathBuf::from(format!("{}/Library/Application Support/com.chronodesk.app/models/bge-reranker-base/model.onnx", h)),
                    PathBuf::from(format!("{}/Library/Application Support/com.chronodesk.app/models/bge-reranker-base/tokenizer.json", h)),
                )
            });
        let (model_path, tokenizer_path) = if model_path.exists() {
            (model_path, tokenizer_path)
        } else if let Some((m, t)) = home_candidates {
            if m.exists() && t.exists() {
                (m, t)
            } else {
                return;
            }
        } else {
            return;
        };

        let reranker = Reranker::new(
            "test".to_string(),
            model_path,
            tokenizer_path,
            512,
            true,
            100,
        )
        .unwrap();

        let request = RerankRequest {
            query: "rust programming".to_string(),
            documents: vec![
                "Learning Rust programming language".to_string(),
                "Python tutorial for beginners".to_string(),
                "Advanced Rust techniques".to_string(),
            ],
            top_k: 2,
        };

        let results = reranker.rerank(request).await.unwrap();
        assert_eq!(results.len(), 2);
        assert!(results[0].score >= results[1].score);

        // Verify that Rust-related documents score higher
        assert!(results[0].document.contains("Rust") || results[1].document.contains("Rust"));
    }

    #[tokio::test]
    #[ignore]
    async fn cross_encoder_semantic_reranking() {
        // Proves BGE cross-encoder beats lexical overlap: query shares no tokens with A,
        // but A is semantically related, while B shares "Swift" token but is unrelated.
        let candidates = vec![
            (
                PathBuf::from("test_models/bge-reranker-base/model.onnx"),
                PathBuf::from("test_models/bge-reranker-base/tokenizer.json"),
            ),
            (
                PathBuf::from("/Users/srivenkat/Library/Application Support/com.chronodesk.app/models/bge-reranker-base/model.onnx"),
                PathBuf::from("/Users/srivenkat/Library/Application Support/com.chronodesk.app/models/bge-reranker-base/tokenizer.json"),
            ),
        ];
        let (model_path, tokenizer_path) = match candidates.into_iter().find(|(m, t)| m.exists() && t.exists()) {
            Some((m, t)) => (m, t),
            None => {
                if let Ok(home) = std::env::var("HOME") {
                    let m = PathBuf::from(format!("{}/Library/Application Support/com.chronodesk.app/models/bge-reranker-base/model.onnx", home));
                    let t = PathBuf::from(format!("{}/Library/Application Support/com.chronodesk.app/models/bge-reranker-base/tokenizer.json", home));
                    if m.exists() && t.exists() {
                        (m, t)
                    } else {
                        return;
                    }
                } else {
                    return;
                }
            }
        };

        let reranker = Reranker::new(
            "test".to_string(),
            model_path,
            tokenizer_path,
            512,
            true,
            100,
        )
        .unwrap();

        let request = RerankRequest {
            query: "debug the Swift graph rendering problem".to_string(),
            documents: vec![
                "Investigating Canvas layout failures in the macOS graph renderer".to_string(),
                "Swift syntax tutorial for beginners".to_string(),
                "Organizing financial documents".to_string(),
            ],
            top_k: 3,
        };

        let results = reranker.rerank(request).await.unwrap();
        assert_eq!(results.len(), 3);
        // A should outrank B and C because it is semantically related to graph rendering, not just Swift token overlap
        let pos_a = results.iter().position(|r| r.document.contains("Canvas layout failures")).unwrap();
        let pos_b = results.iter().position(|r| r.document.contains("Swift syntax tutorial")).unwrap();
        let pos_c = results.iter().position(|r| r.document.contains("financial documents")).unwrap();
        assert!(pos_a < pos_b, "Canvas failures (A) should outrank Swift tutorial (B): positions {} vs {}, scores {:?}", pos_a, pos_b, results.iter().map(|r| (r.document.clone(), r.score)).collect::<Vec<_>>());
        assert!(pos_a < pos_c, "Canvas failures (A) should outrank financial (C)");
        // Scores should be 0..1 (sigmoid) and deterministic
        for r in &results {
            assert!((0.0..=1.0).contains(&r.score), "score {} out of range", r.score);
        }
        // Determinism: rerun same query should give same ordering and scores within epsilon
        let request2 = RerankRequest {
            query: "debug the Swift graph rendering problem".to_string(),
            documents: vec![
                "Investigating Canvas layout failures in the macOS graph renderer".to_string(),
                "Swift syntax tutorial for beginners".to_string(),
                "Organizing financial documents".to_string(),
            ],
            top_k: 3,
        };
        let results2 = reranker.rerank(request2).await.unwrap();
        for (r1, r2) in results.iter().zip(results2.iter()) {
            assert!((r1.score - r2.score).abs() < 1e-5, "deterministic scores {} vs {}", r1.score, r2.score);
        }
    }
}
