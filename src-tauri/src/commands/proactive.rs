//! Proactive Copilot IPC Commands

use std::sync::Arc;
use tauri::State;
use uuid::Uuid;

use crate::copilot::proactive_engine::ProactiveEngine;
use crate::copilot::proactive_models::*;

/// Gets active proactive notifications.
#[tauri::command]
pub async fn copilot_get_notifications(
    engine: State<'_, Arc<ProactiveEngine>>,
    workspace_id: Option<String>,
) -> Result<Vec<ProactiveNotification>, String> {
    let wid = workspace_id
        .map(|s| Uuid::parse_str(&s))
        .transpose()
        .map_err(|e| e.to_string())?;

    Ok(engine.get_active_notifications(wid).await)
}

/// Dismisses a proactive notification.
#[tauri::command]
pub async fn copilot_dismiss_notification(
    engine: State<'_, Arc<ProactiveEngine>>,
    notification_id: String,
) -> Result<(), String> {
    let id = Uuid::parse_str(&notification_id).map_err(|e| e.to_string())?;
    engine
        .dismiss_notification(id)
        .await
        .map_err(|e| e.to_string())
}

/// Generates resume context for a workspace.
#[tauri::command]
pub async fn copilot_get_resume_context(
    engine: State<'_, Arc<ProactiveEngine>>,
    workspace_id: String,
) -> Result<ResumeContext, String> {
    let wid = Uuid::parse_str(&workspace_id).map_err(|e| e.to_string())?;
    engine
        .generate_resume_context(wid)
        .await
        .map_err(|e| e.to_string())
}

/// Generates an execution plan for a goal.
#[tauri::command]
pub async fn copilot_generate_plan(
    engine: State<'_, Arc<ProactiveEngine>>,
    workspace_id: Option<String>,
    goal: String,
) -> Result<ExecutionPlan, String> {
    let wid = workspace_id
        .map(|s| Uuid::parse_str(&s))
        .transpose()
        .map_err(|e| e.to_string())?;

    engine
        .generate_execution_plan(wid, &goal)
        .await
        .map_err(|e| e.to_string())
}

/// Sets automation permission for an action.
#[tauri::command]
pub async fn copilot_set_permission(
    engine: State<'_, Arc<ProactiveEngine>>,
    workspace_id: Option<String>,
    action_type: String,
    permission: PermissionLevel,
) -> Result<(), String> {
    let wid = workspace_id
        .map(|s| Uuid::parse_str(&s))
        .transpose()
        .map_err(|e| e.to_string())?;

    engine
        .set_automation_permission(wid, &action_type, permission)
        .await
        .map_err(|e| e.to_string())
}

/// Checks automation permission for an action.
#[tauri::command]
pub async fn copilot_check_permission(
    engine: State<'_, Arc<ProactiveEngine>>,
    workspace_id: Option<String>,
    action_type: String,
) -> Result<PermissionLevel, String> {
    let wid = workspace_id
        .map(|s| Uuid::parse_str(&s))
        .transpose()
        .map_err(|e| e.to_string())?;

    Ok(engine.check_automation_permission(wid, &action_type).await)
}

/// Generates enhanced daily briefing.
#[tauri::command]
pub async fn copilot_get_enhanced_briefing(
    engine: State<'_, Arc<ProactiveEngine>>,
    workspace_id: Option<String>,
) -> Result<EnhancedBriefing, String> {
    let wid = workspace_id
        .map(|s| Uuid::parse_str(&s))
        .transpose()
        .map_err(|e| e.to_string())?;

    engine
        .generate_enhanced_briefing(wid)
        .await
        .map_err(|e| e.to_string())
}

/// Queries timeline intelligence.
#[tauri::command]
pub async fn copilot_query_timeline(
    engine: State<'_, Arc<ProactiveEngine>>,
    workspace_id: Option<String>,
    query: String,
) -> Result<TimelineIntelligence, String> {
    let wid = workspace_id
        .map(|s| Uuid::parse_str(&s))
        .transpose()
        .map_err(|e| e.to_string())?;

    engine
        .query_timeline_intelligence(wid, &query)
        .await
        .map_err(|e| e.to_string())
}

/// Triggers proactive opportunity check.
#[tauri::command]
pub async fn copilot_check_opportunities(
    engine: State<'_, Arc<ProactiveEngine>>,
    workspace_id: String,
) -> Result<(), String> {
    let wid = Uuid::parse_str(&workspace_id).map_err(|e| e.to_string())?;
    engine
        .check_proactive_opportunities(wid)
        .await
        .map_err(|e| e.to_string())
}

/// Executes a single ProactiveAction via the safe ToolExecutor.
/// Validates workspace isolation, expiry, dismissal, dedup, permission, and
/// tool allowlist before invoking. Returns structured `ProactiveExecutionResult`.
#[tauri::command]
pub async fn copilot_execute_proactive_action(
    engine: State<'_, Arc<ProactiveEngine>>,
    action_id: String,
    workspace_id: Option<String>,
) -> Result<ProactiveExecutionResult, String> {
    let wid = workspace_id
        .map(|s| Uuid::parse_str(&s))
        .transpose()
        .map_err(|e| e.to_string())?;
    Ok(engine.execute_proactive_action(&action_id, wid).await)
}
