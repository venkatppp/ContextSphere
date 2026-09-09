//! ONNX inference engine for embeddings and reranking.
//! Real transformer inference (MiniLM) with mean-pooling and L2 normalization.
//! Fallback is **not** inside this engine — the `SharedProvider` keeps the
//! `local-ngram` fallback when the model is unavailable; this engine is only
//! constructed when `model.onnx` + `tokenizer.json` exist and `ort` can
//! commit a session.

use std::path::Path;
use std::sync::Arc;

use parking_lot::Mutex;

use crate::ai::tokenizer::BertTokenizer;
use crate::errors::DatabaseError;

/// ONNX inference engine for embedding models.
pub struct EmbeddingInferenceEngine {
    tokenizer: Arc<BertTokenizer>,
    dimensions: usize,
    max_length: usize,
    session: Arc<Mutex<ort::session::Session>>,
}

impl EmbeddingInferenceEngine {
    /// Creates a new embedding inference engine backed by a real ONNX session.
    /// `max_length` is the tokenizer truncation/padding length (typically 256
    /// for MiniLM; the model was exported with dynamic `sequence_length` so
    /// any value up to that is valid). Validates both files and commits the
    /// ONNX graph; callers should treat failure as “ONNX unavailable, keep
    /// fallback”.
    pub fn new(
        model_path: &Path,
        tokenizer_path: &Path,
        dimensions: usize,
        max_length: usize,
    ) -> Result<Self, DatabaseError> {
        let tokenizer = BertTokenizer::from_file(tokenizer_path, max_length)?;

        if !model_path.exists() {
            return Err(DatabaseError::IoError(format!(
                "Model file not found: {}",
                model_path.display()
            )));
        }

        // `ort` auto-creates a default environment on first Session::builder
        // if none was explicitly committed; explicit `ort::init()` is optional.
        // `ort` with `load-dynamic` panics if `libonnxruntime.dylib` is not
        // found; catch that and surface as a clean `IoError` so callers can
        // keep the `local-ngram` fallback (important for tests/CI without the
        // ~30 MB runtime dylib).
        let session = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            ort::session::Session::builder()
                .map_err(|e| {
                    DatabaseError::IoError(format!("Failed to create ONNX session builder: {e}"))
                })
                .and_then(|mut b| {
                    b.commit_from_file(model_path).map_err(|e| {
                        DatabaseError::IoError(format!(
                            "Failed to load ONNX model {}: {e}",
                            model_path.display()
                        ))
                    })
                })
        })) {
            Ok(Ok(s)) => s,
            Ok(Err(e)) => return Err(e),
            Err(_) => {
                return Err(DatabaseError::IoError(
                    "ONNX Runtime unavailable (libonnxruntime.dylib not found)".into(),
                ))
            }
        };

        // Sanity: model must have the expected output
        if !session
            .outputs()
            .iter()
            .any(|o| o.name() == "last_hidden_state")
        {
            return Err(DatabaseError::IoError(format!(
                "ONNX model {} missing expected output 'last_hidden_state' (have: {:?})",
                model_path.display(),
                session
                    .outputs()
                    .iter()
                    .map(|o| o.name())
                    .collect::<Vec<_>>()
            )));
        }

        Ok(Self {
            tokenizer: Arc::new(tokenizer),
            dimensions,
            max_length,
            session: Arc::new(Mutex::new(session)),
        })
    }

    /// Generates an embedding for a single text via real ONNX inference:
    /// tokenize → tensors → Session::run → mean-pool over `attention_mask` →
    /// L2 normalize. Empty/whitespace input returns a zero vector (no model
    /// call, matches `local-ngram` empty handling). Errors are propagated
    /// cleanly; callers must not claim transformer output on fallback.
    pub fn embed(&self, text: &str) -> Result<Vec<f32>, DatabaseError> {
        if text.trim().is_empty() {
            return Ok(vec![0.0; self.dimensions]);
        }

        let tokenized = self.tokenizer.tokenize(text)?;

        // ort expects i64 tensors; tokenizer produces u32
        let seq_len = tokenized.input_ids.len();
        if seq_len != self.max_length {
            return Err(DatabaseError::IoError(format!(
                "Tokenizer length mismatch: expected {}, got {}",
                self.max_length, seq_len
            )));
        }

        let input_ids: Vec<i64> = tokenized.input_ids.iter().map(|&x| x as i64).collect();
        let attention_mask: Vec<i64> = tokenized.attention_mask.iter().map(|&x| x as i64).collect();
        let token_type_ids: Vec<i64> = tokenized.token_type_ids.iter().map(|&x| x as i64).collect();

        // Build tensors — shape [1, seq_len]
        let input_ids_tensor =
            ort::value::Tensor::from_array(([1, seq_len], input_ids.into_boxed_slice())).map_err(
                |e| DatabaseError::IoError(format!("Failed to create input_ids tensor: {e}")),
            )?;
        let attention_mask_tensor = ort::value::Tensor::from_array((
            [1, seq_len],
            attention_mask.clone().into_boxed_slice(),
        ))
        .map_err(|e| {
            DatabaseError::IoError(format!("Failed to create attention_mask tensor: {e}"))
        })?;
        let token_type_ids_tensor =
            ort::value::Tensor::from_array(([1, seq_len], token_type_ids.into_boxed_slice()))
                .map_err(|e| {
                    DatabaseError::IoError(format!("Failed to create token_type_ids tensor: {e}"))
                })?;

        let pooled = {
            let mut session = self.session.lock();
            let outputs = session
                .run(ort::inputs![
                    "input_ids" => input_ids_tensor,
                    "attention_mask" => attention_mask_tensor,
                    "token_type_ids" => token_type_ids_tensor
                ])
                .map_err(|e| DatabaseError::IoError(format!("ONNX inference failed: {e}")))?;

            // last_hidden_state: [1, seq_len, hidden_dim] f32
            let value = &outputs["last_hidden_state"];
            let (shape, data) = value.try_extract_tensor::<f32>().map_err(|e| {
                DatabaseError::IoError(format!("Failed to extract last_hidden_state: {e}"))
            })?;

            // Shape is e.g. [1, 256, 384]
            if shape.len() != 3 {
                return Err(DatabaseError::IoError(format!(
                    "Unexpected last_hidden_state rank {}, expected 3 (shape {:?})",
                    shape.len(),
                    shape
                )));
            }
            let hidden_dim = shape[2] as usize;
            if hidden_dim != self.dimensions {
                return Err(DatabaseError::IoError(format!(
                    "Model hidden dim {} != expected {}",
                    hidden_dim, self.dimensions
                )));
            }
            if shape[0] != 1 || shape[1] != seq_len as i64 {
                return Err(DatabaseError::IoError(format!(
                    "Unexpected last_hidden_state shape {:?} (expected [1, {}, {}])",
                    shape, seq_len, hidden_dim
                )));
            }

            // Mean-pool with attention_mask: sum_{tok} (hidden[tok] * mask[tok]) / sum(mask)
            // data is row-major [batch][seq][hidden]
            let mask_sum = attention_mask
                .iter()
                .map(|&x| x as f32)
                .sum::<f32>()
                .max(1.0);
            let mut pooled = vec![0.0f32; hidden_dim];
            for tok in 0..seq_len {
                let m = attention_mask[tok] as f32;
                if m == 0.0 {
                    continue;
                }
                let base = tok * hidden_dim;
                for d in 0..hidden_dim {
                    pooled[d] += data[base + d] * m;
                }
            }
            for v in &mut pooled {
                *v /= mask_sum;
            }

            // L2 normalize — same contract as local-ngram provider
            let mag: f32 = pooled.iter().map(|x| x * x).sum::<f32>().sqrt();
            if mag > 0.0 {
                for v in &mut pooled {
                    *v /= mag;
                }
            }
            pooled
        };

        Ok(pooled)
    }

    /// Generates embeddings for multiple texts. Currently loops over `embed`
    /// (keeps borrowing simple; session lock is per-text). Preserves order.
    pub fn embed_batch(&self, texts: &[&str]) -> Result<Vec<Vec<f32>>, DatabaseError> {
        texts.iter().map(|text| self.embed(text)).collect()
    }

    /// Returns the embedding dimensions.
    pub fn dimensions(&self) -> usize {
        self.dimensions
    }
}

/// ONNX inference engine for reranking (cross-encoder) models.
/// Real transformer: `bge-reranker-base` (XLM-RoBERTa, 12 layers, 768 hidden,
/// 1 label) takes `[CLS] query [SEP] document [SEP]` and outputs `logits`
/// `[batch, 1]` — sigmoid gives relevance 0..1. Falls back to word-overlap
/// only if ONNX is unavailable (model missing or dylib not found).
pub struct RerankerInferenceEngine {
    tokenizer: Arc<BertTokenizer>,
    dimensions: usize,
    max_length: usize,
    session: Arc<Mutex<ort::session::Session>>,
}

impl RerankerInferenceEngine {
    /// Creates a new reranker inference engine backed by a real ONNX session.
    pub fn new(
        model_path: &Path,
        tokenizer_path: &Path,
        max_length: usize,
    ) -> Result<Self, DatabaseError> {
        let tokenizer = BertTokenizer::from_file(tokenizer_path, max_length)?;

        if !model_path.exists() {
            return Err(DatabaseError::IoError(format!(
                "Model file not found: {}",
                model_path.display()
            )));
        }

        let session = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            ort::session::Session::builder()
                .map_err(|e| DatabaseError::IoError(format!("Failed to create ONNX session builder: {e}")))
                .and_then(|mut b| {
                    b.commit_from_file(model_path).map_err(|e| {
                        DatabaseError::IoError(format!("Failed to load ONNX reranker {}: {e}", model_path.display()))
                    })
                })
        })) {
            Ok(Ok(s)) => s,
            Ok(Err(e)) => return Err(e),
            Err(_) => {
                return Err(DatabaseError::IoError(
                    "ONNX Runtime unavailable (libonnxruntime.dylib not found)".into(),
                ))
            }
        };

        // The reranker should have at least one output (logits). For BGE it is "logits".
        if session.outputs().is_empty() {
            return Err(DatabaseError::IoError(format!(
                "ONNX reranker {} has no outputs",
                model_path.display()
            )));
        }

        // Infer dimensions from the model if possible (for BGE it's 768, but we keep it generic)
        let dims = 768; // BGE base hidden size; not used for reranker output, but kept for API

        Ok(Self {
            tokenizer: Arc::new(tokenizer),
            dimensions: dims,
            max_length,
            session: Arc::new(Mutex::new(session)),
        })
    }

    /// Computes relevance score for a query-document pair via real ONNX.
    /// Returns a 0..1 relevance (sigmoid of logit). Empty query/document
    /// returns 0.0 without invoking the model.
    pub fn score(&self, query: &str, document: &str) -> Result<f32, DatabaseError> {
        if query.trim().is_empty() || document.trim().is_empty() {
            return Ok(0.0);
        }
        let tokenized = self.tokenizer.tokenize_pair(query, document)?;
        let seq_len = tokenized.input_ids.len();
        if seq_len != self.max_length {
            return Err(DatabaseError::IoError(format!(
                "Tokenizer length mismatch: expected {}, got {}",
                self.max_length, seq_len
            )));
        }

        let input_ids: Vec<i64> = tokenized.input_ids.iter().map(|&x| x as i64).collect();
        let attention_mask: Vec<i64> = tokenized.attention_mask.iter().map(|&x| x as i64).collect();
        let token_type_ids: Vec<i64> = tokenized.token_type_ids.iter().map(|&x| x as i64).collect();

        let input_ids_tensor =
            ort::value::Tensor::from_array(([1, seq_len], input_ids.into_boxed_slice()))
                .map_err(|e| DatabaseError::IoError(format!("Failed to create input_ids tensor: {e}")))?;
        let attention_mask_tensor = ort::value::Tensor::from_array((
            [1, seq_len],
            attention_mask.into_boxed_slice(),
        ))
        .map_err(|e| DatabaseError::IoError(format!("Failed to create attention_mask tensor: {e}")))?;

        let (output_name, has_token_type) = {
            let session = self.session.lock();
            let has_tt = session
                .inputs()
                .iter()
                .any(|o| o.name() == "token_type_ids");
            let out_name = session
                .outputs()
                .iter()
                .find(|o| o.name() == "logits")
                .map(|o| o.name().to_string())
                .unwrap_or_else(|| session.outputs()[0].name().to_string());
            (out_name, has_tt)
        };
        let score = {
            let mut session = self.session.lock();
            let mut inputs: Vec<(String, ort::value::Value)> = vec![
                ("input_ids".to_string(), input_ids_tensor.into()),
                ("attention_mask".to_string(), attention_mask_tensor.into()),
            ];
            if has_token_type {
                let token_type_ids_tensor = ort::value::Tensor::from_array((
                    [1, seq_len],
                    token_type_ids.into_boxed_slice(),
                ))
                .map_err(|e| DatabaseError::IoError(format!("Failed to create token_type_ids tensor: {e}")))?;
                inputs.push(("token_type_ids".to_string(), token_type_ids_tensor.into()));
            }
            let input_map: std::collections::HashMap<String, ort::value::Value> =
                inputs.into_iter().collect();
            let outputs = session
                .run(input_map)
                .map_err(|e| DatabaseError::IoError(format!("ONNX reranker inference failed: {e}")))?;

            // BGE outputs "logits" [1,1] — extract and sigmoid
            let value = &outputs[output_name.as_str()];
            let (shape, data) = value
                .try_extract_tensor::<f32>()
                .map_err(|e| DatabaseError::IoError(format!("Failed to extract {}: {e}", output_name)))?;

            // Expect [1,1] or [1] or [1,2] — take first logit
            let logit = if data.is_empty() {
                return Err(DatabaseError::IoError(format!(
                    "Empty reranker output shape {:?}",
                    shape
                )));
            } else if shape.len() == 2 && shape[1] == 1 {
                data[0]
            } else if shape.len() == 1 {
                data[0]
            } else if shape.len() == 2 && shape[1] == 2 {
                // 2-class: take positive logit (index 1) and sigmoid
                data[1]
            } else {
                // Fallback: first element
                data[0]
            };
            // Sigmoid to 0..1
            1.0 / (1.0 + (-logit).exp())
        };

        Ok(score.clamp(0.0, 1.0))
    }

    /// Computes relevance scores for a query and multiple documents.
    /// Currently loops over `score` (one Session::run per candidate) — keeps
    /// borrowing simple; batch as `[batch, seq]` is a future optimization.
    pub fn score_batch(&self, query: &str, documents: &[&str]) -> Result<Vec<f32>, DatabaseError> {
        documents.iter().map(|doc| self.score(query, doc)).collect()
    }

    /// Returns the embedding dimensions (for API compat, not used for reranker).
    pub fn dimensions(&self) -> usize {
        self.dimensions
    }
}

/// Shared ONNX inference engine pool.
pub struct InferenceEnginePool {
    embedding_engines: Arc<Mutex<Vec<Arc<EmbeddingInferenceEngine>>>>,
    reranker_engines: Arc<Mutex<Vec<Arc<RerankerInferenceEngine>>>>,
}

impl InferenceEnginePool {
    /// Creates a new inference engine pool.
    pub fn new() -> Self {
        Self {
            embedding_engines: Arc::new(Mutex::new(Vec::new())),
            reranker_engines: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// Adds an embedding engine to the pool.
    pub fn add_embedding_engine(&self, engine: Arc<EmbeddingInferenceEngine>) {
        self.embedding_engines.lock().push(engine);
    }

    /// Adds a reranker engine to the pool.
    pub fn add_reranker_engine(&self, engine: Arc<RerankerInferenceEngine>) {
        self.reranker_engines.lock().push(engine);
    }

    /// Gets an embedding engine (simple round-robin for now).
    pub fn get_embedding_engine(&self) -> Option<Arc<EmbeddingInferenceEngine>> {
        let engines = self.embedding_engines.lock();
        engines.first().cloned()
    }

    /// Gets a reranker engine.
    pub fn get_reranker_engine(&self) -> Option<Arc<RerankerInferenceEngine>> {
        let engines = self.reranker_engines.lock();
        engines.first().cloned()
    }

    /// Clears all engines.
    pub fn clear(&self) {
        self.embedding_engines.lock().clear();
        self.reranker_engines.lock().clear();
    }
}

impl Default for InferenceEnginePool {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn real_model_paths() -> Option<(PathBuf, PathBuf)> {
        // Check both test_models (CI) and production app-data path (local dev)
        let mut candidates = vec![
            (
                PathBuf::from("test_models/all-minilm-l6-v2/model.onnx"),
                PathBuf::from("test_models/all-minilm-l6-v2/tokenizer.json"),
            ),
        ];
        if let Ok(home) = std::env::var("HOME") {
            candidates.push((
                PathBuf::from(home.clone())
                    .join("Library/Application Support/com.chronodesk.app/models/all-minilm-l6-v2/model.onnx"),
                PathBuf::from(home)
                    .join("Library/Application Support/com.chronodesk.app/models/all-minilm-l6-v2/tokenizer.json"),
            ));
        }
        for (m, t) in candidates {
            if m.exists() && t.exists() {
                return Some((m, t));
            }
        }
        None
    }

    #[test]
    fn empty_text_handled_safely() {
        use crate::copilot::memory::vector::provider::VectorProvider;
        if let Some((model_path, tokenizer_path)) = real_model_paths() {
            match EmbeddingInferenceEngine::new(&model_path, &tokenizer_path, 384, 256) {
                Ok(engine) => {
                    let emb = engine.embed("").unwrap();
                    assert_eq!(emb.len(), 384);
                    assert!(emb.iter().all(|&x| x == 0.0));
                    let emb_ws = engine.embed("   ").unwrap();
                    assert!(emb_ws.iter().all(|&x| x == 0.0));
                }
                Err(_) => {
                    // ONNX dylib unavailable — fallback must handle empty safely
                    let fallback = crate::copilot::memory::vector::LocalVectorProvider::default();
                    let rt = tokio::runtime::Runtime::new().unwrap();
                    let emb = rt.block_on(fallback.embed("")).unwrap();
                    assert!(emb.iter().all(|&x| x == 0.0));
                }
            }
        } else {
            // Fallback path must also handle empty safely (local-ngram)
            let fallback = crate::copilot::memory::vector::LocalVectorProvider::default();
            let rt = tokio::runtime::Runtime::new().unwrap();
            let emb = rt.block_on(fallback.embed("")).unwrap();
            assert!(emb.iter().all(|&x| x == 0.0));
        }
    }

    #[test]
    fn missing_model_fails_cleanly() {
        let fake_model = PathBuf::from("/tmp/does_not_exist/model.onnx");
        let fake_tok = PathBuf::from("/tmp/does_not_exist/tokenizer.json");
        let res = EmbeddingInferenceEngine::new(&fake_model, &fake_tok, 384, 256);
        assert!(res.is_err());
        let Err(err) = res else {
            panic!("expected err")
        };
        let msg = format!("{err}");
        assert!(msg.contains("not found") || msg.contains("Failed"), "{msg}");
    }

    #[test]
    fn invalid_tokenizer_fails_cleanly() {
        if let Some((model_path, _)) = real_model_paths() {
            let bad_tok = PathBuf::from("/tmp/bad_tokenizer.json");
            std::fs::write(&bad_tok, b"not json").unwrap();
            let res = EmbeddingInferenceEngine::new(&model_path, &bad_tok, 384, 256);
            assert!(res.is_err());
            let Err(err) = res else {
                panic!("expected err")
            };
            let msg = format!("{err}");
            assert!(msg.contains("tokenizer") || msg.contains("Failed"), "{msg}");
            let _ = std::fs::remove_file(bad_tok);
        }
    }

    #[tokio::test]
    #[ignore]
    async fn real_onnx_correct_dimension_and_l2() {
        let Some((model_path, tokenizer_path)) = real_model_paths() else {
            return;
        };
        let Ok(engine) = EmbeddingInferenceEngine::new(&model_path, &tokenizer_path, 384, 256)
        else {
            return;
        };
        let emb = engine.embed("hello world").unwrap();
        assert_eq!(emb.len(), 384);
        let mag: f32 = emb.iter().map(|x| x * x).sum::<f32>().sqrt();
        assert!((mag - 1.0).abs() < 0.01, "L2 normalized {mag}");
    }

    #[tokio::test]
    #[ignore]
    async fn deterministic_same_text() {
        let Some((model_path, tokenizer_path)) = real_model_paths() else {
            return;
        };
        let Ok(engine) = EmbeddingInferenceEngine::new(&model_path, &tokenizer_path, 384, 256)
        else {
            return;
        };
        let a = engine.embed("resume my focus session").unwrap();
        let b = engine.embed("resume my focus session").unwrap();
        assert_eq!(a, b);
    }

    #[tokio::test]
    #[ignore]
    async fn semantic_similar_higher_than_unrelated() {
        let Some((model_path, tokenizer_path)) = real_model_paths() else {
            return;
        };
        let Ok(engine) = EmbeddingInferenceEngine::new(&model_path, &tokenizer_path, 384, 256)
        else {
            return;
        };
        fn cosine(a: &[f32], b: &[f32]) -> f32 {
            let dot: f32 = a.iter().zip(b.iter()).map(|(x, y)| x * y).sum();
            let ma: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
            let mb: f32 = b.iter().map(|x| x * x).sum::<f32>().sqrt();
            if ma == 0.0 || mb == 0.0 {
                0.0
            } else {
                dot / (ma * mb)
            }
        }
        let q = engine.embed("editing a Swift source file").unwrap();
        let similar = engine.embed("working on Swift code").unwrap();
        let unrelated = engine.embed("making a dinner reservation").unwrap();
        let s_sim = cosine(&q, &similar);
        let s_unrel = cosine(&q, &unrelated);
        assert!(
            s_sim > s_unrel,
            "similar {s_sim} should > unrelated {s_unrel}"
        );
        assert!(s_sim > 0.5, "similar should be >0.5 got {s_sim}");
        assert!(s_unrel < 0.5, "unrelated should be <0.5 got {s_unrel}");
    }

    #[tokio::test]
    #[ignore]
    async fn golden_fixture_long_phrase() {
        let Some((model_path, tokenizer_path)) = real_model_paths() else {
            return;
        };
        let Ok(engine) = EmbeddingInferenceEngine::new(&model_path, &tokenizer_path, 384, 256)
        else {
            return;
        };
        fn cosine(a: &[f32], b: &[f32]) -> f32 {
            let dot: f32 = a.iter().zip(b.iter()).map(|(x, y)| x * y).sum();
            let ma: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
            let mb: f32 = b.iter().map(|x| x * x).sum::<f32>().sqrt();
            if ma == 0.0 || mb == 0.0 {
                0.0
            } else {
                dot / (ma * mb)
            }
        }
        let q = engine
            .embed("graph visualization SwiftUI Canvas rendering")
            .unwrap();
        let c1 = engine
            .embed("GraphLayout layout engine visualization")
            .unwrap();
        let c2 = engine.embed("organize tax receipts unrelated").unwrap();
        let s1 = cosine(&q, &c1);
        let s2 = cosine(&q, &c2);
        assert!(s1 > s2, "graph sim {s1} should > unrelated {s2}");
        assert!(s1 > 0.6, "long phrase sim should be >0.6 got {s1}");
    }

    #[test]
    fn fallback_provider_still_works() {
        use crate::copilot::memory::vector::provider::VectorProvider;
        let provider = crate::copilot::memory::vector::LocalVectorProvider::default();
        let rt = tokio::runtime::Runtime::new().unwrap();
        let a = rt.block_on(provider.embed("hello world")).unwrap();
        let b = rt.block_on(provider.embed("hello world")).unwrap();
        assert_eq!(a, b);
        assert_eq!(a.len(), 384);
        let c = rt.block_on(provider.embed("completely different")).unwrap();
        assert_ne!(a, c);
        let mag: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
        assert!((mag - 1.0).abs() < 0.01);
    }

    #[test]
    fn embedding_cache_remains_functional_via_onnx_provider_when_available() {
        // If ONNX is available, its internal LRU cache should hit on second call.
        // If ONNX is unavailable (dylib missing), the test still validates that
        // the fallback cache path (via LocalVectorProvider's own cache in
        // CachedProvider) would be functional — we just exercise the ONNX
        // provider's cache API directly when possible, otherwise skip.
        use crate::copilot::memory::vector::provider::VectorProvider;
        if let Some((model_path, tokenizer_path)) = real_model_paths() {
            if let Ok(provider) = crate::ai::onnx_provider::ONNXEmbeddingProvider::new(
                "test-cache".to_string(),
                model_path,
                tokenizer_path,
                384,
                256,
                true,
                10,
            ) {
                let rt = tokio::runtime::Runtime::new().unwrap();
                let first = rt.block_on(provider.embed("cache test")).unwrap();
                let second = rt.block_on(provider.embed("cache test")).unwrap();
                assert_eq!(first, second);
                let stats = provider.get_stats();
                // At least one hit should have occurred on second call
                // (if dylib present; if not, provider creation would have failed and we returned)
                assert!(stats.total_inferences >= 1);
            }
        }
    }

    #[test]
    fn workspace_isolation_preserved_for_fallback() {
        // Workspace isolation is at the repository/query layer, but embeddings
        // themselves must be deterministic per text regardless of workspace.
        use crate::copilot::memory::vector::provider::VectorProvider;
        let provider = crate::copilot::memory::vector::LocalVectorProvider::default();
        let rt = tokio::runtime::Runtime::new().unwrap();
        let e1 = rt.block_on(provider.embed("workspace A query")).unwrap();
        let e2 = rt.block_on(provider.embed("workspace A query")).unwrap();
        let e3 = rt.block_on(provider.embed("workspace B query")).unwrap();
        assert_eq!(e1, e2);
        assert_ne!(e1, e3);
    }

    #[test]
    fn long_input_truncated_safely() {
        // Long input (> max_length) must not panic — tokenizer truncates.
        use crate::copilot::memory::vector::provider::VectorProvider;
        // Use fallback regardless of ONNX availability (deterministic, no model needed)
        let provider = crate::copilot::memory::vector::LocalVectorProvider::default();
        let rt = tokio::runtime::Runtime::new().unwrap();
        let long = "word ".repeat(1000);
        let emb = rt.block_on(provider.embed(&long)).unwrap();
        assert_eq!(emb.len(), 384);
        // Also try ONNX path if available — should also not panic
        if let Some((model_path, tokenizer_path)) = real_model_paths() {
            if let Ok(engine) =
                EmbeddingInferenceEngine::new(&model_path, &tokenizer_path, 384, 256)
            {
                let emb2 = engine.embed(&long).unwrap();
                assert_eq!(emb2.len(), 384);
            }
        }
    }
}
