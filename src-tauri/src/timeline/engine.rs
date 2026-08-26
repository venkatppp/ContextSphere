//! Timeline Engine (blueprint §4.2): the public facade for everything
//! timeline-related. Mirrors [`crate::workspace::manager::WorkspaceManager`]'s
//! role for the Workspace Engine — a thin orchestration layer over
//! [`crate::services::TimelineService`] that the file watcher pipeline
//! and Tauri commands hold as a single managed object, rather than each
//! reaching past it into repositories directly.

use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::errors::DatabaseError;
use crate::models::TimelineEvent;
use crate::services::TimelineService;

use super::events::TimelineActivity;

/// Public entry point to the Timeline Engine.
#[derive(Debug, Clone)]
pub struct TimelineEngine {
    service: TimelineService,
}

impl TimelineEngine {
    pub fn new(service: TimelineService) -> Self {
        Self { service }
    }

    /// Records `activity` against `workspace_id` at `occurred_at`. The
    /// watcher pipeline's "Timeline Recording" stage calls this once a
    /// [`super::events::TimelineActivity`] has been built from a
    /// normalized filesystem event and a resolved workspace.
    pub async fn record(
        &self,
        workspace_id: Uuid,
        activity: TimelineActivity,
        occurred_at: DateTime<Utc>,
    ) -> Result<TimelineEvent, DatabaseError> {
        self.service
            .record_activity(workspace_id, activity, occurred_at)
            .await
    }

    /// Records `activity` as occurring right now.
    pub async fn record_now(
        &self,
        workspace_id: Uuid,
        activity: TimelineActivity,
    ) -> Result<TimelineEvent, DatabaseError> {
        self.service
            .record_activity_now(workspace_id, activity)
            .await
    }

    /// Indexes a pre-existing file under `workspace_id` — a `files` row
    /// with no timeline event. The file watcher's initial directory scan
    /// calls this for every existing file found when a watch starts.
    pub async fn register_file(
        &self,
        workspace_id: Uuid,
        path: &str,
    ) -> Result<(), DatabaseError> {
        self.service.register_file(workspace_id, path).await
    }

    /// Lists the most recent events for a workspace, newest first —
    /// exposed through `commands::timeline` for the Timeline screen.
    pub async fn recent_events(
        &self,
        workspace_id: Uuid,
        limit: Option<i64>,
        offset: Option<i64>,
    ) -> Result<Vec<TimelineEvent>, DatabaseError> {
        self.service
            .list_recent_events(workspace_id, limit, offset)
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::test_database;
    use crate::models::CreateWorkspaceInput;
    use crate::repositories::{FileRepository, TimelineRepository, WorkspaceRepository};
    use crate::timeline::recorder::TimelineRecorder;

    async fn engine_with_workspace() -> (TimelineEngine, Uuid, tempfile::TempDir) {
        let (database, temp_dir) = test_database().await;
        let workspace_repo = WorkspaceRepository::new(database.pool().clone());
        let workspace = workspace_repo
            .create(CreateWorkspaceInput {
                name: "Test Workspace".to_string(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();

        let timeline_repository = TimelineRepository::new(database.pool().clone());
        let recorder = TimelineRecorder::new(
            FileRepository::new(database.pool().clone()),
            timeline_repository.clone(),
        );
        let engine = TimelineEngine::new(TimelineService::new(recorder, timeline_repository));

        (engine, workspace.id, temp_dir)
    }

    #[tokio::test]
    async fn record_now_and_recent_events_round_trip() {
        let (engine, workspace_id, _guard) = engine_with_workspace().await;

        engine
            .record_now(workspace_id, TimelineActivity::WorkspaceOpened)
            .await
            .expect("record should succeed");

        let events = engine.recent_events(workspace_id, None, None).await.unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(
            events[0].event_type,
            crate::models::TimelineEventType::WorkspaceSwitch
        );
    }
}
