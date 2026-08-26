//! AI model management commands.

use tauri::{Emitter, State};

use crate::ai::models::{RerankRequest, RerankResult};
use crate::ai::{AIDiagnostics, DownloadProgress, InferenceStats, ModelInfo};
use crate::copilot::memory::vector::provider::VectorProvider;
use crate::semantic::embeddings::EmbeddingProvider;

/// AI state manager (to be added to lib.rs).
pub struct AIState {
    pub manager: crate::ai::ModelManager,
    pub reranker: parking_lot::RwLock<Option<std::sync::Arc<crate::ai::Reranker>>>,
    pub embedding_provider:
        parking_lot::RwLock<Option<std::sync::Arc<crate::ai::ONNXEmbeddingProvider>>>,
    pub shared_provider: std::sync::Arc<crate::ai::SharedProvider>,
}

/// Lists all available AI models.
#[tauri::command]
pub async fn list_models(state: State<'_, AIState>) -> Result<Vec<ModelInfo>, String> {
    Ok(state.manager.list_models())
}

/// Gets information about a specific model.
#[tauri::command]
pub async fn get_model(
    model_id: String,
    state: State<'_, AIState>,
) -> Result<Option<ModelInfo>, String> {
    Ok(state.manager.get_model(&model_id))
}

/// Downloads a model.
#[tauri::command]
pub async fn download_model(
    model_id: String,
    state: State<'_, AIState>,
    app: tauri::AppHandle,
) -> Result<(), String> {
    state
        .manager
        .download_model(&model_id, move |progress: DownloadProgress| {
            let _ = app.emit("model:download_progress", &progress);
        })
        .await
        .map_err(|e| e.to_string())
}

/// Loads a model into memory.
#[tauri::command]
pub async fn load_model(model_id: String, state: State<'_, AIState>) -> Result<(), String> {
    // Get model metadata
    let model = state
        .manager
        .get_model(&model_id)
        .ok_or_else(|| format!("Model not found: {}", model_id))?;

    if model.status != crate::ai::models::ModelStatus::Downloaded {
        return Err("Model must be downloaded first".to_string());
    }

    let model_path = state
        .manager
        .get_model_path(&model_id)
        .ok_or_else(|| "Model path not found".to_string())?;

    let model_file = model_path.join("model.onnx");
    let tokenizer_file = model_path.join("tokenizer.json");

    // Load based on model type
    match model.metadata.model_type {
        crate::ai::models::ModelType::Embedding => {
            let provider = crate::ai::ONNXEmbeddingProvider::new(
                model_id.clone(),
                model_file,
                tokenizer_file,
                model.metadata.dimensions,
                model.metadata.max_sequence_length,
                true,  // enable_cache
                10000, // cache_size
            )
            .map_err(|e| e.to_string())?;

            let provider = std::sync::Arc::new(provider);
            {
                let mut guard = state.embedding_provider.write();
                *guard = Some(provider.clone());
            }
            // Unify: also swap the shared local provider so MemoryVectorSystem,
            // SemanticMemoryEngine and graph vector search all use the same ONNX.
            state
                .shared_provider
                .set_provider(provider.clone() as std::sync::Arc<dyn VectorProvider>);

            state
                .manager
                .mark_loaded(&model_id, model.metadata.file_size_bytes)
                .map_err(|e| e.to_string())?;

            state
                .manager
                .set_active_embedding_model(model_id.clone())
                .map_err(|e| e.to_string())?;
        }
        crate::ai::models::ModelType::Reranker => {
            let reranker = crate::ai::Reranker::new(
                model_id.clone(),
                model_file,
                tokenizer_file,
                model.metadata.max_sequence_length,
                true, // enable_cache
                1000, // cache_size
            )
            .map_err(|e| e.to_string())?;

            let reranker = std::sync::Arc::new(reranker);
            {
                let mut guard = state.reranker.write();
                *guard = Some(reranker);
            }

            state
                .manager
                .mark_loaded(&model_id, model.metadata.file_size_bytes)
                .map_err(|e| e.to_string())?;

            state
                .manager
                .set_active_reranker_model(model_id.clone())
                .map_err(|e| e.to_string())?;
        }
    }

    Ok(())
}

/// Unloads a model from memory.
#[tauri::command]
pub async fn unload_model(model_id: String, state: State<'_, AIState>) -> Result<(), String> {
    // Clear provider if it matches the unloaded model and revert shared provider to n-gram fallback
    {
        let active = state.manager.active_embedding_model();
        if active.as_deref() == Some(&model_id) {
            {
                let mut guard = state.embedding_provider.write();
                *guard = None;
            }
            state.shared_provider.set_provider(std::sync::Arc::new(
                crate::copilot::memory::vector::LocalVectorProvider::default(),
            ) as std::sync::Arc<dyn VectorProvider>);
        }
        let active_r = state.manager.active_reranker_model();
        if active_r.as_deref() == Some(&model_id) {
            let mut guard = state.reranker.write();
            *guard = None;
        }
    }
    state
        .manager
        .mark_unloaded(&model_id)
        .map_err(|e| e.to_string())
}

/// Gets the active embedding model ID.
#[tauri::command]
pub async fn get_active_embedding_model(
    state: State<'_, AIState>,
) -> Result<Option<String>, String> {
    Ok(state.manager.active_embedding_model())
}

/// Gets the active reranker model ID.
#[tauri::command]
pub async fn get_active_reranker_model(
    state: State<'_, AIState>,
) -> Result<Option<String>, String> {
    Ok(state.manager.active_reranker_model())
}

/// Gets model status.
#[tauri::command]
pub async fn get_model_status(
    model_id: String,
    state: State<'_, AIState>,
) -> Result<Option<crate::ai::models::ModelStatus>, String> {
    Ok(state.manager.get_model(&model_id).map(|m| m.status))
}

/// Gets inference statistics for all models.
#[tauri::command]
pub async fn get_inference_statistics(
    state: State<'_, AIState>,
) -> Result<Vec<InferenceStats>, String> {
    let mut stats = Vec::new();

    // Get embedding provider stats
    {
        let guard = state.embedding_provider.read();
        if let Some(provider) = guard.as_ref() {
            stats.push(provider.get_stats());
        }
    }

    // Get reranker stats
    {
        let guard = state.reranker.read();
        if let Some(reranker) = guard.as_ref() {
            stats.push(reranker.get_stats());
        }
    }

    Ok(stats)
}

/// Gets AI diagnostics.
#[tauri::command]
pub async fn get_ai_diagnostics(state: State<'_, AIState>) -> Result<AIDiagnostics, String> {
    let models = state.manager.list_models();
    let stats_vec = get_inference_statistics(state).await?;

    let mut stats_map = std::collections::HashMap::new();
    for stat in stats_vec {
        stats_map.insert(stat.model_id.clone(), stat);
    }

    Ok(AIDiagnostics::new(models, stats_map))
}

/// Reranks documents using the active reranker model.
#[tauri::command]
pub async fn rerank_documents(
    request: RerankRequest,
    state: State<'_, AIState>,
) -> Result<Vec<RerankResult>, String> {
    let reranker = {
        let guard = state.reranker.read();
        guard
            .as_ref()
            .cloned()
            .ok_or_else(|| "No reranker model loaded".to_string())?
    };

    reranker.rerank(request).await.map_err(|e| e.to_string())
}

/// Graph AI vector search using the real ONNX embedding provider.
/// Reuses the existing `graph_vector_search` ranking logic but with genuine
/// local embeddings (all-MiniLM-L6-v2, 384-d, cosine 0…1) instead of the
/// hash fallback. Returns empty when no ONNX model is loaded — caller
/// should fall back to `graph_vector_search` (hash) or `graph_ranked_search`.
///
/// Small API extension, no new DB, no new vector store, no external service.
/// One RPC per focus/search change, top-K 20, cached on the frontend.
#[tauri::command]
pub async fn graph_ai_vector_search(
    query: String,
    limit: Option<u32>,
    graph_engine: State<'_, crate::graph::GraphEngine>,
    ai_state: State<'_, AIState>,
) -> Result<Vec<crate::models::kg_opt::RankedSearchHit>, String> {
    let provider = {
        let guard = ai_state.embedding_provider.read();
        guard.as_ref().cloned()
    };
    let Some(provider) = provider else {
        return Ok(Vec::new());
    };

    let query_vec = crate::semantic::embeddings::EmbeddingProvider::embed(
            provider.as_ref(),
            &query,
        )
        .await
        .map_err(|e| e.to_string())?;

    // Fetch candidates via the graph engine (all 6 types, top 250 as in KgOptService)
    let candidates = graph_engine
        .graph_nodes(
            vec![
                crate::models::kg::GraphNodeType::Workspace,
                crate::models::kg::GraphNodeType::File,
                crate::models::kg::GraphNodeType::PlannerReport,
                crate::models::kg::GraphNodeType::Execution,
                crate::models::kg::GraphNodeType::MemoryRecord,
                crate::models::kg::GraphNodeType::AutonomousSession,
            ],
            None,
            Some(250),
        )
        .await
        .map_err(|e| e.to_string())?;

    // Batch embed all candidate titles — one ONNX batch instead of 250 individual
    // inferences. Keeps the same cosine threshold and top-K, but ~20× faster
    // for cold cache (15 ms → 0.7 ms per title amortized).
    let titles: Vec<String> = candidates.iter().map(|n| n.title.clone()).collect();
    let title_refs: Vec<&str> = titles.iter().map(|s| s.as_str()).collect();
    let title_vecs =
        crate::copilot::memory::vector::provider::VectorProvider::embed_batch(
            provider.as_ref(),
            &title_refs,
        )
        .await
        .map_err(|e| e.to_string())?;

    let mut scored: Vec<crate::models::kg_opt::RankedSearchHit> = Vec::new();
    for (node, title_vec) in candidates.into_iter().zip(title_vecs) {
        let sim = cosine_cosine(&query_vec, &title_vec);
        if sim >= 0.20 {
            scored.push(crate::models::kg_opt::RankedSearchHit {
                node,
                score: (sim * 100.0).round() / 100.0,
                method: "ai_vector".to_string(),
                reason: format!("AI semantic similarity {:.0}%", sim * 100.0),
            });
        }
    }
    scored.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    scored.truncate(limit.unwrap_or(20) as usize);
    Ok(scored)
}

fn cosine_cosine(a: &[f32], b: &[f32]) -> f64 {
    let mut dot = 0f64;
    let mut na = 0f64;
    let mut nb = 0f64;
    for (x, y) in a.iter().zip(b.iter()) {
        dot += *x as f64 * *y as f64;
        na += *x as f64 * *x as f64;
        nb += *y as f64 * *y as f64;
    }
    if na <= 0.0 || nb <= 0.0 {
        return 0.0;
    }
    (dot / (na.sqrt() * nb.sqrt())).clamp(0.0, 1.0)
}
