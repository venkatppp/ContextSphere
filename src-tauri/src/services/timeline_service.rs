//! Business logic for the Timeline Engine. Sits between
//! `commands::timeline` / [`crate::timeline::engine::TimelineEngine`] and
//! [`TimelineRecorder`]/[`TimelineRepository`] — the same layering
//! [`crate::services::workspace_service::WorkspaceService`] uses,
//! applied to timeline concerns: pagination limits and query validation
//! live here, not in the repository or the command handler.

use uuid::Uuid;

use crate::errors::DatabaseError;
use crate::models::TimelineEvent;
use crate::repositories::TimelineRepository;
use crate::timeline::events::TimelineActivity;
use crate::timeline::recorder::TimelineRecorder;

/// Upper bound on `limit` for any timeline query, regardless of what the
/// caller requests. Protects the desktop app from a single "load
/// everything" call (e.g. a misbehaving frontend retry loop) pulling an
/// unbounded number of rows into memory.
const MAX_LIST_LIMIT: i64 = 500;

/// Business logic for recording and querying timeline activity.
#[derive(Debug, Clone)]
pub struct TimelineService {
    recorder: TimelineRecorder,
    timeline_repository: TimelineRepository,
}

impl TimelineService {
    pub fn new(recorder: TimelineRecorder, timeline_repository: TimelineRepository) -> Self {
        Self {
            recorder,
            timeline_repository,
        }
    }

    /// Records a [`TimelineActivity`] as having occurred at `occurred_at`.
    /// See [`TimelineRecorder::record`] for exactly what this does
    /// (including transparent file-row resolution).
    pub async fn record_activity(
        &self,
        workspace_id: Uuid,
        activity: TimelineActivity,
        occurred_at: chrono::DateTime<chrono::Utc>,
    ) -> Result<TimelineEvent, DatabaseError> {
        self.recorder
            .record(workspace_id, activity, occurred_at)
            .await
    }

    /// Records a [`TimelineActivity`] as occurring right now. The
    /// convenience path every watcher-pipeline call site uses — real
    /// filesystem events don't carry a meaningfully different
    /// "occurred_at" from "when we processed them" at Phase 3's
    /// granularity.
    pub async fn record_activity_now(
        &self,
        workspace_id: Uuid,
        activity: TimelineActivity,
    ) -> Result<TimelineEvent, DatabaseError> {
        self.record_activity(workspace_id, activity, chrono::Utc::now())
            .await
    }

    /// Indexes a pre-existing file under `workspace_id`: ensures the
    /// `files` row exists without recording a timeline event. The file
    /// watcher's initial directory scan calls this for every file found
    /// when a watch starts, so pre-existing content populates the
    /// workspace without fabricating "created now" events.
    pub async fn register_file(
        &self,
        workspace_id: Uuid,
        path: &str,
    ) -> Result<(), DatabaseError> {
        self.recorder.register_file(workspace_id, path).await.map(|_| ())
    }

    /// Lists the most recent events for a workspace, newest first.
    ///
    /// `limit` is clamped to `1..=MAX_LIST_LIMIT`: `None` or a
    /// non-positive value falls back to
    /// [`crate::repositories::timeline_repository`]'s own default page
    /// size, and anything above [`MAX_LIST_LIMIT`] is capped rather than
    /// rejected — a generous request is clamped, not treated as an error,
    /// since "give me everything" is a reasonable (if oversized) ask from
    /// the UI.
    pub async fn list_recent_events(
        &self,
        workspace_id: Uuid,
        limit: Option<i64>,
        offset: Option<i64>,
    ) -> Result<Vec<TimelineEvent>, DatabaseError> {
        let clamped_limit = limit.filter(|&l| l > 0).map(|l| l.min(MAX_LIST_LIMIT));
        self.timeline_repository
            .list_by_workspace_paged(workspace_id, clamped_limit, offset)
            .await
    }

    /// Lists every event referencing a specific file, newest first —
    /// backs a "file history" view (when a file, not a whole workspace,
    /// is what the user is inspecting).
    pub async fn list_events_for_file(
        &self,
        file_id: Uuid,
    ) -> Result<Vec<TimelineEvent>, DatabaseError> {
        self.timeline_repository.list_by_file(file_id).await
    }

    /// Fetches a single event by id — backs a "jump to this event's
    /// detail" action.
    pub async fn get_event(&self, id: Uuid) -> Result<TimelineEvent, DatabaseError> {
        self.timeline_repository.get_by_id(id).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::test_database;
    use crate::models::CreateWorkspaceInput;
    use crate::repositories::{FileRepository, WorkspaceRepository};

    async fn service_with_workspace() -> (TimelineService, Uuid, tempfile::TempDir) {
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
        let service = TimelineService::new(recorder, timeline_repository);

        (service, workspace.id, temp_dir)
    }

    #[tokio::test]
    async fn record_and_list_round_trip() {
        let (service, workspace_id, _guard) = service_with_workspace().await;

        service
            .record_activity_now(workspace_id, TimelineActivity::WorkspaceOpened)
            .await
            .unwrap();
        service
            .record_activity_now(
                workspace_id,
                TimelineActivity::FileCreated {
                    path: "/repo/main.rs".to_string(),
                },
            )
            .await
            .unwrap();

        let events = service
            .list_recent_events(workspace_id, None, None)
            .await
            .unwrap();
        assert_eq!(events.len(), 2);
    }

    #[tokio::test]
    async fn list_recent_events_clamps_limit_above_the_maximum() {
        let (service, workspace_id, _guard) = service_with_workspace().await;

        for _ in 0..3 {
            service
                .record_activity_now(workspace_id, TimelineActivity::WorkspaceOpened)
                .await
                .unwrap();
        }

        // Requesting far more than MAX_LIST_LIMIT must not error — it's
        // silently clamped — and must still return the 3 rows that exist.
        let events = service
            .list_recent_events(workspace_id, Some(1_000_000), None)
            .await
            .unwrap();
        assert_eq!(events.len(), 3);
    }

    #[tokio::test]
    async fn list_recent_events_ignores_a_non_positive_limit() {
        let (service, workspace_id, _guard) = service_with_workspace().await;
        service
            .record_activity_now(workspace_id, TimelineActivity::WorkspaceOpened)
            .await
            .unwrap();

        // A zero/negative limit falls back to the repository's default
        // page size rather than returning zero rows.
        let events = service
            .list_recent_events(workspace_id, Some(0), None)
            .await
            .unwrap();
        assert_eq!(events.len(), 1);
    }

    #[tokio::test]
    async fn list_events_for_file_returns_only_that_files_events() {
        let (service, workspace_id, _guard) = service_with_workspace().await;

        let event = service
            .record_activity_now(
                workspace_id,
                TimelineActivity::FileCreated {
                    path: "/repo/main.rs".to_string(),
                },
            )
            .await
            .unwrap();
        service
            .record_activity_now(workspace_id, TimelineActivity::WorkspaceOpened)
            .await
            .unwrap();

        let file_id = event
            .file_id
            .expect("file-level activity should have a file_id");
        let events = service.list_events_for_file(file_id).await.unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].file_id, Some(file_id));
    }
}
