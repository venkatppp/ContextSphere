//! Timeline IPC commands. Same discipline as `commands::workspace`: no
//! SQL, no business rules here — every handler pulls the managed
//! [`TimelineEngine`] out of Tauri state and calls exactly one method.

use tauri::State;
use uuid::Uuid;

use crate::errors::DatabaseError;
use crate::models::TimelineEvent;
use crate::timeline::TimelineEngine;

/// Lists the most recent timeline events for a workspace, newest first.
/// Backs the Timeline screen's vertical feed (blueprint §3.2).
///
/// `limit` is optional; omit it (or pass `null`) to use the server-side
/// default page size. Requests above the service layer's cap are
/// silently clamped, not rejected — see
/// [`crate::services::timeline_service::TimelineService::list_recent_events`].
#[tauri::command]
pub async fn list_workspace_timeline(
    engine: State<'_, TimelineEngine>,
    workspace_id: Uuid,
    limit: Option<i64>,
    offset: Option<i64>,
) -> Result<Vec<TimelineEvent>, DatabaseError> {
    engine.recent_events(workspace_id, limit, offset).await
}

/// Convenience alias for the dashboard's "recent activity" use case:
/// the most recent events for a workspace, capped at a small page size
/// suited to an inline feed rather than the full Timeline screen.
const RECENT_ACTIVITY_LIMIT: i64 = 10;

#[tauri::command]
pub async fn get_recent_activity(
    engine: State<'_, TimelineEngine>,
    workspace_id: Uuid,
) -> Result<Vec<TimelineEvent>, DatabaseError> {
    engine
        .recent_events(workspace_id, Some(RECENT_ACTIVITY_LIMIT), None)
        .await
}
