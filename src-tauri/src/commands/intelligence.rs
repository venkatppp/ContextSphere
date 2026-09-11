//! Intelligence commands - recommendations and workspace health.

use tauri::State;
use uuid::Uuid;

use crate::context_memory::models::{ContextSnapshot, SnapshotType};
use crate::intelligence::continuity::{ContextContinuityEngine, ReconstructedContext};
use crate::intelligence::health::{WorkspaceHealth, WorkspaceHealthEngine};
use crate::intelligence::recommendation::{
    Recommendation, RecommendationCategory, RecommendationEngine, RecommendationPriority,
};
use crate::intelligence::workspace::{
    ActiveWorkspaceInference, WorkspaceIntelligence, WorkspaceIntelligenceEngine,
};
use crate::runtime::IntelligenceEmitter;

/// Gets workspace health assessment.
#[tauri::command]
pub async fn get_workspace_health(
    workspace_id: String,
    engine: State<'_, WorkspaceHealthEngine>,
    emitter: State<'_, IntelligenceEmitter>,
) -> Result<WorkspaceHealth, String> {
    let workspace_uuid =
        Uuid::parse_str(&workspace_id).map_err(|e| format!("Invalid workspace ID: {}", e))?;

    tracing::debug!(?workspace_uuid, "Getting workspace health");
    let health = engine
        .calculate_health(workspace_uuid)
        .await
        .map_err(|e| e.to_string())?;

    emitter.emit_health_updated(workspace_uuid, health.overall_score);

    Ok(health)
}

/// Gets the latest cached workspace health (without recalculation).
#[tauri::command]
pub async fn get_latest_workspace_health(
    workspace_id: String,
    engine: State<'_, WorkspaceHealthEngine>,
) -> Result<Option<WorkspaceHealth>, String> {
    let workspace_uuid =
        Uuid::parse_str(&workspace_id).map_err(|e| format!("Invalid workspace ID: {}", e))?;

    tracing::debug!(?workspace_uuid, "Getting latest workspace health");
    engine
        .get_latest_health(workspace_uuid)
        .await
        .map_err(|e| e.to_string())
}

/// Gets workspace health history.
#[tauri::command]
pub async fn get_workspace_health_history(
    workspace_id: String,
    days: i64,
    engine: State<'_, WorkspaceHealthEngine>,
) -> Result<Vec<WorkspaceHealth>, String> {
    use chrono::{Duration, Utc};

    let workspace_uuid =
        Uuid::parse_str(&workspace_id).map_err(|e| format!("Invalid workspace ID: {}", e))?;

    let since = Utc::now() - Duration::days(days);
    tracing::debug!(?workspace_uuid, days, "Getting workspace health history");
    engine
        .get_health_history(workspace_uuid, since)
        .await
        .map_err(|e| e.to_string())
}

/// Generates recommendations for a workspace.
#[tauri::command]
pub async fn get_workspace_recommendations(
    workspace_id: String,
    engine: State<'_, RecommendationEngine>,
) -> Result<Vec<Recommendation>, String> {
    let workspace_uuid =
        Uuid::parse_str(&workspace_id).map_err(|e| format!("Invalid workspace ID: {}", e))?;

    tracing::debug!(?workspace_uuid, "Generating workspace recommendations");
    engine
        .generate_recommendations(workspace_uuid)
        .await
        .map_err(|e| e.to_string())
}

/// Generates recommendations for a specific category.
#[tauri::command]
pub async fn get_category_recommendations(
    workspace_id: String,
    category: RecommendationCategory,
    engine: State<'_, RecommendationEngine>,
) -> Result<Vec<Recommendation>, String> {
    let workspace_uuid =
        Uuid::parse_str(&workspace_id).map_err(|e| format!("Invalid workspace ID: {}", e))?;

    tracing::debug!(
        ?workspace_uuid,
        ?category,
        "Generating category recommendations"
    );
    engine
        .generate_category_recommendations(workspace_uuid, category)
        .await
        .map_err(|e| e.to_string())
}

/// Gets high-priority recommendations only.
#[tauri::command]
pub async fn get_priority_recommendations(
    workspace_id: String,
    min_priority: RecommendationPriority,
    engine: State<'_, RecommendationEngine>,
) -> Result<Vec<Recommendation>, String> {
    let workspace_uuid =
        Uuid::parse_str(&workspace_id).map_err(|e| format!("Invalid workspace ID: {}", e))?;

    tracing::debug!(
        ?workspace_uuid,
        ?min_priority,
        "Generating priority recommendations"
    );
    engine
        .generate_priority_recommendations(workspace_uuid, min_priority)
        .await
        .map_err(|e| e.to_string())
}

/// Gets explainable intelligence assessment and signals for a specific workspace.
#[tauri::command]
pub async fn get_workspace_intelligence(
    workspace_id: String,
    engine: State<'_, WorkspaceIntelligenceEngine>,
) -> Result<WorkspaceIntelligence, String> {
    let workspace_uuid =
        Uuid::parse_str(&workspace_id).map_err(|e| format!("Invalid workspace ID: {}", e))?;

    tracing::debug!(?workspace_uuid, "Computing workspace intelligence");
    engine
        .infer_workspace_intelligence(workspace_uuid)
        .await
        .map_err(|e| e.to_string())
}

/// Computes active workspace inference across all active workspaces.
#[tauri::command]
pub async fn get_active_workspace_inference(
    engine: State<'_, WorkspaceIntelligenceEngine>,
) -> Result<ActiveWorkspaceInference, String> {
    tracing::debug!("Inferring active workspace");
    engine
        .infer_active_workspace()
        .await
        .map_err(|e| e.to_string())
}

/// Lists intelligence metrics and confidence scores for all active workspaces.
#[tauri::command]
pub async fn list_workspaces_intelligence(
    engine: State<'_, WorkspaceIntelligenceEngine>,
) -> Result<Vec<WorkspaceIntelligence>, String> {
    tracing::debug!("Listing workspaces intelligence");
    engine
        .list_workspaces_intelligence()
        .await
        .map_err(|e| e.to_string())
}

/// Reconstructs comprehensive context for a specific workspace.
#[tauri::command]
pub async fn reconstruct_workspace_context(
    workspace_id: String,
    engine: State<'_, ContextContinuityEngine>,
) -> Result<ReconstructedContext, String> {
    let workspace_uuid =
        Uuid::parse_str(&workspace_id).map_err(|e| format!("Invalid workspace ID: {}", e))?;

    tracing::debug!(?workspace_uuid, "Reconstructing workspace context");
    engine
        .reconstruct_workspace_context(workspace_uuid)
        .await
        .map_err(|e| e.to_string())
}

/// Gets the most relevant previous work context for smart context resumption.
#[tauri::command]
pub async fn get_smart_resume_context(
    engine: State<'_, ContextContinuityEngine>,
) -> Result<Option<ReconstructedContext>, String> {
    tracing::debug!("Retrieving smart resume context");
    engine
        .get_smart_resume_context()
        .await
        .map_err(|e| e.to_string())
}

/// Creates and persists a ContextSnapshot of the current work episode in ContextMemory.
#[tauri::command]
pub async fn snapshot_work_episode(
    workspace_id: String,
    snapshot_type: Option<SnapshotType>,
    engine: State<'_, ContextContinuityEngine>,
    emitter: State<'_, IntelligenceEmitter>,
) -> Result<ContextSnapshot, String> {
    let workspace_uuid =
        Uuid::parse_str(&workspace_id).map_err(|e| format!("Invalid workspace ID: {}", e))?;

    let snap_type = snapshot_type.unwrap_or(SnapshotType::Milestone);
    tracing::debug!(?workspace_uuid, ?snap_type, "Snapshotting work episode");
    let snapshot = engine
        .snapshot_work_episode(workspace_uuid, snap_type)
        .await
        .map_err(|e| e.to_string())?;

    emitter.emit_snapshot_created(workspace_uuid, snapshot.id);

    Ok(snapshot)
}
