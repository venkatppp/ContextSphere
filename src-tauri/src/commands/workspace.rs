//! Workspace IPC commands.
//!
//! Every handler here does exactly two things: pull the managed
//! [`WorkspaceService`] out of Tauri state, and call one method on it.
//! No SQL, no business rules, no validation logic lives in this file —
//! see [`crate::services::workspace_service`] for that. Keeping commands
//! this thin means the same business logic is exercised whether it's
//! invoked from the frontend or from a `#[tokio::test]`.
//!
//! Note on naming: Tauri registers commands globally by their bare
//! function name (not module-qualified), so these are named
//! `list_active_workspaces` / `get_workspace` / etc. rather than the
//! shorter `list_active` / `get` — that avoids a same-name collision with
//! a future `commands::file`/`commands::timeline` module that will
//! plausibly also want a `get` or `create` command. The `workspace::`
//! grouping the spec asks for is expressed by this file living in
//! `commands::workspace`, which is how the Rust side organizes and
//! documents them even though the JS side calls them by bare name.

use std::sync::Arc;
use tauri::{AppHandle, State};
use uuid::Uuid;

use crate::app_events::{
    self, EVENT_WORKSPACE_CREATED, EVENT_WORKSPACE_DELETED, EVENT_WORKSPACE_SWITCHED,
    EVENT_WORKSPACE_UPDATED,
};
use crate::context_memory::ContextMemoryEngine;
use crate::errors::DatabaseError;
use crate::intelligence::health::WorkspaceHealthEngine;
use crate::models::{CreateWorkspaceInput, UpdateWorkspaceInput, Workspace, WorkspaceStats};
use crate::repositories::FileRepository;
use crate::runtime::RuntimeWorkers;
use crate::services::WorkspaceService;

/// Lists every active workspace, most recently active first.
/// Backs the dashboard's "Active workspaces" grid (blueprint §3.2).
#[tauri::command]
pub async fn list_active_workspaces(
    service: State<'_, WorkspaceService>,
) -> Result<Vec<Workspace>, DatabaseError> {
    service.list_active_workspaces().await
}

/// Lists every archived workspace, most recently active first.
/// Backs the "Archived" filter tab on the Workspaces screen.
#[tauri::command]
pub async fn list_archived_workspaces(
    service: State<'_, WorkspaceService>,
) -> Result<Vec<Workspace>, DatabaseError> {
    service.list_archived_workspaces().await
}

/// Fetches a single workspace by id.
///
/// # Errors
/// Returns [`DatabaseError::NotFound`] (serialized to a plain string
/// across IPC) if `id` doesn't exist.
#[tauri::command]
pub async fn get_workspace(
    service: State<'_, WorkspaceService>,
    id: Uuid,
) -> Result<Workspace, DatabaseError> {
    service.get_workspace(id).await
}

/// Aggregated statistics for a workspace — file count, timeline event
/// count, recency, and health score — in a single round-trip.
///
/// The health score is computed live from measurable signals by the
/// workspace health engine whenever the stored score is stale (0.0 =
/// never calculated, or older than 15 minutes), so the UI never shows
/// a fabricated or placeholder health value.
///
/// Named `get_workspace_statistics` (not `get_workspace_stats`, which
/// would collide with `commands::search::get_workspace_stats`).
///
/// # Errors
/// [`DatabaseError::NotFound`] if `id` doesn't exist.
#[tauri::command]
pub async fn get_workspace_statistics(
    service: State<'_, WorkspaceService>,
    health_engine: State<'_, WorkspaceHealthEngine>,
    workspace_id: Uuid,
) -> Result<WorkspaceStats, DatabaseError> {
    let mut stats = service.get_workspace_stats(workspace_id).await?;

    // Stale or missing health score? Recalculate from real data.
    let fresh = health_engine.get_latest_health(workspace_id).await?;
    let stale = match &fresh {
        Some(health) => {
            (chrono::Utc::now() - health.calculated_at).num_minutes() > 15
                || stats.health_score == 0.0
        }
        None => true,
    };
    if stale {
        let health = health_engine.calculate_health(workspace_id).await?;
        stats.health_score = health.overall_score * 100.0;
    } else if let Some(health) = &fresh {
        stats.health_score = health.overall_score * 100.0;
    }

    Ok(stats)
}

/// Creates a new workspace and emits [`EVENT_WORKSPACE_CREATED`] so every
/// listening window updates without a manual refresh.
///
/// # Errors
/// [`DatabaseError::InvalidInput`] if `input.name` is empty.
#[tauri::command]
pub async fn create_workspace(
    app: AppHandle,
    service: State<'_, WorkspaceService>,
    input: CreateWorkspaceInput,
) -> Result<Workspace, DatabaseError> {
    let workspace = service.create_workspace(input).await?;
    app_events::emit(&app, EVENT_WORKSPACE_CREATED, &workspace);
    Ok(workspace)
}

/// Applies a partial update to a workspace and emits
/// [`EVENT_WORKSPACE_UPDATED`]. See [`UpdateWorkspaceInput`] for PATCH
/// semantics (a field left as `None` is left unchanged).
///
/// # Errors
/// [`DatabaseError::NotFound`] if `id` doesn't exist;
/// [`DatabaseError::InvalidInput`] for an invalid `name`/`health_score`.
#[tauri::command]
pub async fn update_workspace(
    app: AppHandle,
    service: State<'_, WorkspaceService>,
    id: Uuid,
    input: UpdateWorkspaceInput,
) -> Result<Workspace, DatabaseError> {
    let workspace = service.update_workspace(id, input).await?;
    app_events::emit(&app, EVENT_WORKSPACE_UPDATED, &workspace);
    Ok(workspace)
}

/// Permanently deletes a workspace — and, via cascading foreign keys,
/// every file/timeline/tag/relationship row that referenced it — then
/// emits [`EVENT_WORKSPACE_DELETED`] with `{ "id": <uuid> }`.
///
/// # Errors
/// [`DatabaseError::NotFound`] if `id` doesn't exist.
#[tauri::command]
pub async fn delete_workspace(
    app: AppHandle,
    service: State<'_, WorkspaceService>,
    id: Uuid,
) -> Result<(), DatabaseError> {
    service.delete_workspace(id).await?;
    app_events::emit(
        &app,
        EVENT_WORKSPACE_DELETED,
        &serde_json::json!({ "id": id }),
    );
    Ok(())
}

/// Switches the active workspace and broadcasts the change.
#[tauri::command]
pub async fn switch_workspace(
    app: AppHandle,
    service: State<'_, WorkspaceService>,
    context_memory_engine: State<'_, ContextMemoryEngine>,
    file_repository: State<'_, FileRepository>,
    runtime_workers: State<'_, Arc<RuntimeWorkers>>,
    proactive_engine: State<'_, std::sync::Arc<crate::copilot::ProactiveEngine>>,
    id: Uuid,
) -> Result<(), DatabaseError> {
    // Create auto snapshot before switching
    let files = file_repository.list_by_workspace(id).await?;
    let active_files: Vec<String> = files.iter().map(|f| f.path_or_url.clone()).collect();

    let _ = context_memory_engine.auto_snapshot(id, active_files).await;

    // Notify the proactive engine so it can react to the context switch
    // (emits `proactive:notification` when the detector has something).
    let previous_workspace = service.get_active_workspace().await.ok().flatten();

    service.switch_workspace(id).await?;

    if let Err(error) = proactive_engine
        .on_workspace_switched(
            previous_workspace.map(|w| w.id).unwrap_or(id),
            id,
        )
        .await
    {
        tracing::warn!(error = %error, "proactive workspace-switch hook failed");
    }

    // Update runtime workers with new active workspace
    runtime_workers.set_active_workspace(Some(id)).await;

    // Invalidate cache and trigger immediate updates
    runtime_workers.invalidate_and_update(id).await;

    app_events::emit(
        &app,
        EVENT_WORKSPACE_SWITCHED,
        &serde_json::json!({ "id": id }),
    );

    Ok(())
}
