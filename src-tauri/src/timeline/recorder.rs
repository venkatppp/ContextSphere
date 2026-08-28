//! [`TimelineRecorder`]: the single choke point for turning a
//! [`super::events::TimelineActivity`] into persisted rows. Resolves (or
//! creates) the `files` row a file-level activity refers to, then writes
//! the `timeline_events` row — so file-row bookkeeping never has to be
//! duplicated at every call site that wants to record something.

use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::errors::DatabaseError;
use crate::models::{ArtifactType, NewFile, NewTimelineEvent, TimelineEvent};
use crate::repositories::{FileRepository, TimelineRepository};

use super::events::TimelineActivity;

/// Records [`TimelineActivity`] values onto a workspace's timeline.
#[derive(Debug, Clone)]
pub struct TimelineRecorder {
    file_repository: FileRepository,
    timeline_repository: TimelineRepository,
}

impl TimelineRecorder {
    pub fn new(file_repository: FileRepository, timeline_repository: TimelineRepository) -> Self {
        Self {
            file_repository,
            timeline_repository,
        }
    }

    /// Records `activity` against `workspace_id`, occurring at
    /// `occurred_at`. For a file-level activity, finds the existing
    /// `files` row for that path within the workspace or creates one —
    /// callers never manage file rows themselves.
    ///
    /// # Errors
    /// Propagates any [`DatabaseError`] from the underlying repositories,
    /// most commonly [`DatabaseError::Constraint`] if `workspace_id`
    /// doesn't reference an existing workspace.
    pub async fn record(
        &self,
        workspace_id: Uuid,
        activity: TimelineActivity,
        occurred_at: DateTime<Utc>,
    ) -> Result<TimelineEvent, DatabaseError> {
        // Defense-in-depth: never ingest generated/dependency/build
        // paths, even if a caller bypasses the watcher's ignore filter.
        // `is_ignored` is the shared exclusion source of truth.
        if let Some(path) = activity.file_path() {
            if crate::watcher::event_handler::is_ignored(std::path::Path::new(&path)) {
                tracing::debug!(path = %path, "skipping ignored path in timeline recorder");
                return Err(DatabaseError::InvalidInput(format!(
                    "path is inside an excluded directory: {path}"
                )));
            }
        }

        let file_id = match (&activity, activity.file_path()) {
            // A deleted file's `files` row is removed after the event is
            // recorded below; a path that was never indexed must not get
            // a row created for it, so resolve without creating.
            (TimelineActivity::FileDeleted { .. }, Some(path)) => self
                .file_repository
                .find_by_workspace_and_path(workspace_id, path)
                .await?
                .map(|existing| existing.id),
            (_, Some(path)) => Some(self.resolve_file(workspace_id, path).await?),
            (_, None) => None,
        };

        let (event_type, metadata) = activity.to_event_type_and_metadata();

        let event = self
            .timeline_repository
            .create(NewTimelineEvent {
                workspace_id,
                file_id,
                event_type,
                occurred_at,
                metadata,
            })
            .await?;

        // Best-effort local content indexing for filename+content search.
        // Local-only, workspace-scoped, text <256KB, 10k chars, ignores binaries.
        // Failure is non-fatal (e.g. file already deleted, not readable).
        if let (Some(fid), Some(path)) = (file_id, activity.file_path()) {
            if !matches!(activity, TimelineActivity::FileDeleted { .. }) {
                Self::maybe_index_content(&self.file_repository, fid, &path).await;
            }
        }

        // The deletion event is recorded first (its FK references the
        // row); the row itself is then removed so deleted files stop
        // showing up in searches, file lists and duplicate scans. The
        // `ON DELETE SET NULL` foreign key and the `search_index` delete
        // trigger clean up the references.
        if let (TimelineActivity::FileDeleted { .. }, Some(id)) = (&activity, file_id) {
            self.file_repository.delete(id).await?;
        }

        tracing::info!(
            workspace_id = %workspace_id,
            event_type = event.event_type.as_str(),
            file_id = ?file_id,
            "timeline event recorded"
        );

        Ok(event)
    }

    /// Finds the `files` row for `path` within `workspace_id`, creating
    /// one — as a generic `file` artifact; the watcher pipeline doesn't
    /// yet distinguish tabs/notes/screenshots from real filesystem files,
    /// only [`crate::watcher`] does that distinction, and Phase 3 only
    /// watches the filesystem — the first time this path is seen.
    pub(crate) async fn resolve_file(
        &self,
        workspace_id: Uuid,
        path: &str,
    ) -> Result<Uuid, DatabaseError> {
        if let Some(existing) = self
            .file_repository
            .find_by_workspace_and_path(workspace_id, path)
            .await?
        {
            return Ok(existing.id);
        }

        let created = self
            .file_repository
            .create(NewFile {
                workspace_id,
                artifact_type: ArtifactType::File,
                path_or_url: path.to_string(),
                content_hash: None,
            })
            .await?;

        Ok(created.id)
    }

    /// Ensures a `files` row exists for `path` under `workspace_id`
    /// without recording a timeline event — the initial directory scan
    /// runs when a watch starts, and a pre-existing file wasn't
    /// "created" right now, so it gets indexed but no fake event. Reuses
    /// [`TimelineRecorder::resolve_file`], so a later live event (or a
    /// re-scan after remove/re-add) reuses the same row instead of
    /// duplicating it.
    ///
    /// # Errors
    /// [`DatabaseError::InvalidInput`] if `path` is inside an excluded
    /// directory (same defense-in-depth as [`TimelineRecorder::record`]).
    pub(crate) async fn register_file(
        &self,
        workspace_id: Uuid,
        path: &str,
    ) -> Result<Uuid, DatabaseError> {
        if crate::watcher::event_handler::is_ignored(std::path::Path::new(path)) {
            tracing::debug!(path = %path, "skipping ignored path in file registration");
            return Err(DatabaseError::InvalidInput(format!(
                "path is inside an excluded directory: {path}"
            )));
        }

        let file_id = self.resolve_file(workspace_id, path).await?;
        // Best-effort content indexing for initial scan (local, <256KB, text).
        Self::maybe_index_content(&self.file_repository, file_id, path).await;
        Ok(file_id)
    }

    /// Local-only content preview for FTS5 `search_index.body`.
    /// - Ignores excluded/vendor paths (shared `is_ignored`).
    /// - Skips >256KB, empty, or binary (null byte) files.
    /// - Truncates to 10k chars.
    /// - Never fails the caller (logs and returns on error).
    async fn maybe_index_content(
        file_repository: &crate::repositories::FileRepository,
        file_id: Uuid,
        path: &str,
    ) {
        use std::path::Path;
        if crate::watcher::event_handler::is_ignored(Path::new(path)) {
            return;
        }
        let Ok(meta) = tokio::fs::metadata(path).await else {
            return;
        };
        const MAX_BYTES: u64 = 256 * 1024;
        const MAX_CHARS: usize = 10_000;
        if meta.len() == 0 || meta.len() > MAX_BYTES {
            return;
        }
        let Ok(bytes) = tokio::fs::read(path).await else {
            return;
        };
        if bytes.contains(&0) {
            return;
        }
        let text = String::from_utf8_lossy(&bytes);
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return;
        }
        let preview: String = trimmed.chars().take(MAX_CHARS).collect();
        if let Err(e) = file_repository.update_search_body(file_id, preview).await {
            tracing::debug!(file_id = %file_id, error = %e, "content indexing failed");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::test_database;
    use crate::models::CreateWorkspaceInput;
    use crate::repositories::{TimelineRepository, WorkspaceRepository};

    async fn recorder_with_workspace() -> (TimelineRecorder, FileRepository, Uuid, tempfile::TempDir)
    {
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

        let file_repository = FileRepository::new(database.pool().clone());
        let recorder = TimelineRecorder::new(
            file_repository.clone(),
            TimelineRepository::new(database.pool().clone()),
        );

        (recorder, file_repository, workspace.id, temp_dir)
    }

    #[tokio::test]
    async fn recording_file_created_creates_a_file_row() {
        let (recorder, file_repository, workspace_id, _guard) = recorder_with_workspace().await;

        recorder
            .record(
                workspace_id,
                TimelineActivity::FileCreated {
                    path: "/repo/src/main.rs".to_string(),
                },
                Utc::now(),
            )
            .await
            .expect("record should succeed");

        let files = file_repository
            .list_by_workspace(workspace_id)
            .await
            .unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].path_or_url, "/repo/src/main.rs");
    }

    #[tokio::test]
    async fn recording_activity_for_the_same_path_twice_reuses_the_file_row() {
        let (recorder, file_repository, workspace_id, _guard) = recorder_with_workspace().await;

        recorder
            .record(
                workspace_id,
                TimelineActivity::FileCreated {
                    path: "/repo/src/main.rs".to_string(),
                },
                Utc::now(),
            )
            .await
            .unwrap();
        recorder
            .record(
                workspace_id,
                TimelineActivity::FileModified {
                    path: "/repo/src/main.rs".to_string(),
                },
                Utc::now(),
            )
            .await
            .unwrap();

        let files = file_repository
            .list_by_workspace(workspace_id)
            .await
            .unwrap();
        assert_eq!(
            files.len(),
            1,
            "the second event must not create a duplicate file row"
        );
    }

    #[tokio::test]
    async fn recording_file_deleted_removes_the_file_row_but_keeps_the_event() {
        let (database, _guard) = test_database().await;
        let workspace_repo = WorkspaceRepository::new(database.pool().clone());
        let workspace = workspace_repo
            .create(CreateWorkspaceInput {
                name: "Delete Target".to_string(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();
        let file_repository = FileRepository::new(database.pool().clone());
        let timeline_repository = TimelineRepository::new(database.pool().clone());
        let recorder = TimelineRecorder::new(file_repository.clone(), timeline_repository.clone());

        recorder
            .record(
                workspace.id,
                TimelineActivity::FileCreated {
                    path: "/repo/gone.rs".to_string(),
                },
                Utc::now(),
            )
            .await
            .expect("record create should succeed");
        recorder
            .record(
                workspace.id,
                TimelineActivity::FileDeleted {
                    path: "/repo/gone.rs".to_string(),
                },
                Utc::now(),
            )
            .await
            .expect("record delete should succeed");

        let files = file_repository
            .list_by_workspace(workspace.id)
            .await
            .unwrap();
        assert!(
            files.is_empty(),
            "the deleted file's row must not linger as a ghost"
        );

        let events = timeline_repository
            .list_by_workspace(workspace.id, None)
            .await
            .unwrap();
        assert_eq!(events.len(), 2, "both events must remain recorded");
    }

    #[tokio::test]
    async fn recording_deleted_for_a_never_indexed_path_creates_no_row() {
        let (database, _guard) = test_database().await;
        let workspace_repo = WorkspaceRepository::new(database.pool().clone());
        let workspace = workspace_repo
            .create(CreateWorkspaceInput {
                name: "Delete Target".to_string(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();
        let file_repository = FileRepository::new(database.pool().clone());
        let recorder = TimelineRecorder::new(
            file_repository.clone(),
            TimelineRepository::new(database.pool().clone()),
        );

        recorder
            .record(
                workspace.id,
                TimelineActivity::FileDeleted {
                    path: "/repo/never-seen.rs".to_string(),
                },
                Utc::now(),
            )
            .await
            .expect("record delete should succeed");

        let files = file_repository
            .list_by_workspace(workspace.id)
            .await
            .unwrap();
        assert!(
            files.is_empty(),
            "a deleted path that was never indexed must not create a file row"
        );
    }

    #[tokio::test]
    async fn workspace_level_activity_records_with_no_file_id() {
        let (recorder, _file_repository, workspace_id, _guard) = recorder_with_workspace().await;

        let event = recorder
            .record(workspace_id, TimelineActivity::WorkspaceOpened, Utc::now())
            .await
            .unwrap();

        assert_eq!(event.file_id, None);
    }

    #[tokio::test]
    async fn register_file_indexes_a_row_without_a_timeline_event() {
        let (database, _guard) = test_database().await;
        let workspace_repo = WorkspaceRepository::new(database.pool().clone());
        let workspace = workspace_repo
            .create(CreateWorkspaceInput {
                name: "Scan Target".to_string(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();
        let file_repository = FileRepository::new(database.pool().clone());
        let timeline_repository = TimelineRepository::new(database.pool().clone());
        let recorder = TimelineRecorder::new(file_repository.clone(), timeline_repository.clone());

        // Registering the same path twice (e.g. a re-scan after
        // remove/re-add) must reuse the row, not duplicate it.
        recorder
            .register_file(workspace.id, "/repo/old.py")
            .await
            .unwrap();
        recorder
            .register_file(workspace.id, "/repo/old.py")
            .await
            .unwrap();

        let files = file_repository.list_by_workspace(workspace.id).await.unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].path_or_url, "/repo/old.py");

        assert!(
            timeline_repository
                .list_by_workspace(workspace.id, None)
                .await
                .unwrap()
                .is_empty(),
            "indexing a pre-existing file must not fabricate a timeline event"
        );
    }

    #[tokio::test]
    async fn register_file_rejects_ignored_paths() {
        let (database, _guard) = test_database().await;
        let workspace_repo = WorkspaceRepository::new(database.pool().clone());
        let workspace = workspace_repo
            .create(CreateWorkspaceInput {
                name: "Scan Target".to_string(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();
        let recorder = TimelineRecorder::new(
            FileRepository::new(database.pool().clone()),
            TimelineRepository::new(database.pool().clone()),
        );

        let result = recorder
            .register_file(workspace.id, "/repo/node_modules/x/index.js")
            .await;

        assert!(matches!(result, Err(DatabaseError::InvalidInput(_))));
    }

    #[tokio::test]
    async fn recording_against_unknown_workspace_fails() {
        let (database, _guard) = test_database().await;
        let recorder = TimelineRecorder::new(
            FileRepository::new(database.pool().clone()),
            TimelineRepository::new(database.pool().clone()),
        );

        let result = recorder
            .record(
                Uuid::new_v4(),
                TimelineActivity::WorkspaceOpened,
                Utc::now(),
            )
            .await;

        assert!(matches!(result, Err(DatabaseError::Constraint(_))));
    }
}
