use chrono::Utc;
use sqlx::SqlitePool;
use uuid::Uuid;

use crate::errors::DatabaseError;
use crate::models::timeline::TimelineEventRow;
use crate::models::{NewTimelineEvent, TimelineEvent};

/// Default number of rows returned by [`TimelineRepository::list_by_workspace`]
/// when the caller doesn't need the whole history — matches the
/// Timeline screen's initial page size (blueprint §3.2).
const DEFAULT_LIST_LIMIT: i64 = 50;

/// Owns every SQL statement that touches the `timeline_events` table
/// (blueprint §10). There is deliberately no `update` method: the
/// Timeline is an append-only log, and every row is written exactly once
/// by [`TimelineRepository::create`].
#[derive(Debug, Clone)]
pub struct TimelineRepository {
    pool: SqlitePool,
}

const SELECT_COLUMNS: &str =
    "id, workspace_id, file_id, event_type, occurred_at, metadata, created_at";

impl TimelineRepository {
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }

    /// Appends a new event to the log.
    ///
    /// # Errors
    /// [`DatabaseError::Constraint`] if `workspace_id` (or a non-`None`
    /// `file_id`) doesn't reference an existing row.
    pub async fn create(&self, input: NewTimelineEvent) -> Result<TimelineEvent, DatabaseError> {
        let id = Uuid::new_v4();
        let now = Utc::now();
        let metadata_json = input
            .metadata
            .as_ref()
            .map(serde_json::to_string)
            .transpose()
            .map_err(|e| {
                DatabaseError::InvalidInput(format!("invalid timeline event metadata: {e}"))
            })?;

        sqlx::query(
            "INSERT INTO timeline_events (id, workspace_id, file_id, event_type, occurred_at, metadata, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(id)
        .bind(input.workspace_id)
        .bind(input.file_id)
        .bind(input.event_type.as_str())
        .bind(input.occurred_at)
        .bind(&metadata_json)
        .bind(now)
        .execute(&self.pool)
        .await?;

        tracing::info!(
            event_id = %id,
            workspace_id = %input.workspace_id,
            event_type = input.event_type.as_str(),
            "timeline event recorded"
        );

        self.get_by_id(id).await
    }

    /// Fetches a single event by id.
    ///
    /// # Errors
    /// [`DatabaseError::NotFound`] if no event with that id exists.
    pub async fn get_by_id(&self, id: Uuid) -> Result<TimelineEvent, DatabaseError> {
        let row: TimelineEventRow = sqlx::query_as(&format!(
            "SELECT {SELECT_COLUMNS} FROM timeline_events WHERE id = ?"
        ))
        .bind(id)
        .fetch_optional(&self.pool)
        .await?
        .ok_or_else(|| DatabaseError::not_found("timeline_event", id.to_string()))?;

        TimelineEvent::try_from(row)
    }

    /// Lists the most recent events for a workspace, newest first —
    /// backs the Timeline screen's vertical feed (blueprint §3.2). Pass
    /// `None` for `limit` to use the screen's default page size
    /// ([`DEFAULT_LIST_LIMIT`]); pagination beyond the first page is a
    /// Phase 3 concern (offset/cursor param) once the Timeline UI exists
    /// to drive it.
    pub async fn list_by_workspace(
        &self,
        workspace_id: Uuid,
        limit: Option<i64>,
    ) -> Result<Vec<TimelineEvent>, DatabaseError> {
        self.list_by_workspace_paged(workspace_id, limit, None).await
    }

    /// Offset-based page over [`Self::list_by_workspace`]: `offset`
    /// skips that many newer events so the Timeline UI can page past the
    /// single-request cap. Negative offsets are treated as 0.
    pub async fn list_by_workspace_paged(
        &self,
        workspace_id: Uuid,
        limit: Option<i64>,
        offset: Option<i64>,
    ) -> Result<Vec<TimelineEvent>, DatabaseError> {
        let rows: Vec<TimelineEventRow> = sqlx::query_as(&format!(
            "SELECT {SELECT_COLUMNS} FROM timeline_events
             WHERE workspace_id = ? ORDER BY occurred_at DESC LIMIT ? OFFSET ?"
        ))
        .bind(workspace_id)
        .bind(limit.unwrap_or(DEFAULT_LIST_LIMIT))
        .bind(offset.unwrap_or(0).max(0))
        .fetch_all(&self.pool)
        .await?;

        rows.into_iter().map(TimelineEvent::try_from).collect()
    }

    /// Lists every event referencing a specific file, newest first —
    /// e.g. "when was this file opened/edited/moved".
    pub async fn list_by_file(&self, file_id: Uuid) -> Result<Vec<TimelineEvent>, DatabaseError> {
        let rows: Vec<TimelineEventRow> = sqlx::query_as(&format!(
            "SELECT {SELECT_COLUMNS} FROM timeline_events
             WHERE file_id = ? ORDER BY occurred_at DESC"
        ))
        .bind(file_id)
        .fetch_all(&self.pool)
        .await?;

        rows.into_iter().map(TimelineEvent::try_from).collect()
    }

    /// Lists recent events across all workspaces, newest first.
    ///
    /// Used for Smart Resume to find the most recent session regardless
    /// of workspace. Limited to a reasonable number to avoid scanning
    /// the entire timeline table.
    pub async fn list_recent(&self, limit: i64) -> Result<Vec<TimelineEvent>, DatabaseError> {
        let rows: Vec<TimelineEventRow> = sqlx::query_as(&format!(
            "SELECT {SELECT_COLUMNS} FROM timeline_events
             ORDER BY occurred_at DESC LIMIT ?"
        ))
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;

        rows.into_iter().map(TimelineEvent::try_from).collect()
    }

    /// Atomically appends a `workspace_switch` event — but only when the
    /// workspace it targets differs from the most recently recorded
    /// switch. Returns `true` if a switch was recorded, `false` if it
    /// was skipped as redundant.
    ///
    /// The check and the insert run inside a single `BEGIN IMMEDIATE`
    /// transaction on one connection, so concurrent callers (the watcher
    /// pipeline, the `switch_workspace` command, the copilot tool
    /// executor) serialize at SQLite's write lock: whoever commits first
    /// decides, and every later caller sees that committed switch and
    /// skips. Without the transaction this was a check-then-insert race
    /// that recorded duplicate "Switched workspace" rows for one
    /// continuous working session.
    pub async fn record_switch_if_latest_different(
        &self,
        workspace_id: Uuid,
        occurred_at: chrono::DateTime<chrono::Utc>,
        metadata: Option<serde_json::Value>,
    ) -> Result<bool, DatabaseError> {
        let mut conn = self.pool.acquire().await?;

        // `BEGIN IMMEDIATE` takes the write lock up front (unlike the
        // deferred `BEGIN` sqlx's `begin()` issues), which is what makes
        // the read-then-conditional-insert below atomic across
        // connections rather than merely serialized per connection.
        sqlx::query("BEGIN IMMEDIATE").execute(&mut *conn).await?;

        let outcome = async {
            let latest: Option<Uuid> = sqlx::query_scalar(
                "SELECT workspace_id FROM timeline_events
                 WHERE event_type = 'workspace_switch'
                 ORDER BY occurred_at DESC, created_at DESC LIMIT 1",
            )
            .fetch_optional(&mut *conn)
            .await?;

            if latest.is_some_and(|latest| latest == workspace_id) {
                return Ok::<bool, DatabaseError>(false);
            }

            let metadata_json = metadata
                .as_ref()
                .map(serde_json::to_string)
                .transpose()
                .map_err(|e| {
                    DatabaseError::InvalidInput(format!("invalid timeline event metadata: {e}"))
                })?;

            sqlx::query(
                "INSERT INTO timeline_events (id, workspace_id, file_id, event_type, occurred_at, metadata, created_at)
                 VALUES (?, ?, NULL, 'workspace_switch', ?, ?, ?)",
            )
            .bind(Uuid::new_v4())
            .bind(workspace_id)
            .bind(occurred_at)
            .bind(&metadata_json)
            .bind(Utc::now())
            .execute(&mut *conn)
            .await?;

            Ok::<bool, DatabaseError>(true)
        }
        .await;

        match outcome {
            Ok(recorded) => {
                sqlx::query("COMMIT").execute(&mut *conn).await?;
                Ok(recorded)
            }
            Err(err) => {
                let _ = sqlx::query("ROLLBACK").execute(&mut *conn).await;
                Err(err)
            }
        }
    }

    /// Counts timeline events for a workspace since `since` (inclusive).
    /// Feeds the workspace health engine's activity factor.
    pub async fn count_since(
        &self,
        workspace_id: Uuid,
        since: chrono::DateTime<chrono::Utc>,
    ) -> Result<i64, DatabaseError> {
        let count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM timeline_events
             WHERE workspace_id = ? AND occurred_at >= ?",
        )
        .bind(workspace_id)
        .bind(since)
        .fetch_one(&self.pool)
        .await?;

        Ok(count)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::test_database;
    use crate::models::{CreateWorkspaceInput, TimelineEventType};
    use crate::repositories::WorkspaceRepository;

    async fn repo_with_workspace() -> (TimelineRepository, Uuid, tempfile::TempDir) {
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

        (
            TimelineRepository::new(database.pool().clone()),
            workspace.id,
            temp_dir,
        )
    }

    #[tokio::test]
    async fn create_and_get_round_trip_with_metadata() {
        let (repo, workspace_id, _guard) = repo_with_workspace().await;

        let created = repo
            .create(NewTimelineEvent {
                workspace_id,
                file_id: None,
                event_type: TimelineEventType::Edit,
                occurred_at: Utc::now(),
                metadata: Some(serde_json::json!({ "diff_lines": 12 })),
            })
            .await
            .expect("create should succeed");

        let fetched = repo.get_by_id(created.id).await.unwrap();
        assert_eq!(fetched.event_type, TimelineEventType::Edit);
        assert_eq!(
            fetched.metadata.unwrap()["diff_lines"],
            serde_json::json!(12)
        );
    }

    #[tokio::test]
    async fn create_rejects_unknown_workspace() {
        let (database, _guard) = test_database().await;
        let repo = TimelineRepository::new(database.pool().clone());

        let result = repo
            .create(NewTimelineEvent {
                workspace_id: Uuid::new_v4(),
                file_id: None,
                event_type: TimelineEventType::Open,
                occurred_at: Utc::now(),
                metadata: None,
            })
            .await;

        assert!(matches!(result, Err(DatabaseError::Constraint(_))));
    }

    #[tokio::test]
    async fn list_by_workspace_orders_newest_first_and_respects_limit() {
        let (repo, workspace_id, _guard) = repo_with_workspace().await;

        for i in 0..5 {
            repo.create(NewTimelineEvent {
                workspace_id,
                file_id: None,
                event_type: TimelineEventType::Open,
                occurred_at: Utc::now() + chrono::Duration::seconds(i),
                metadata: None,
            })
            .await
            .unwrap();
        }

        let events = repo.list_by_workspace(workspace_id, Some(3)).await.unwrap();
        assert_eq!(events.len(), 3);
        // Newest first: each event's occurred_at should be >= the next one's.
        assert!(events[0].occurred_at >= events[1].occurred_at);
        assert!(events[1].occurred_at >= events[2].occurred_at);
    }

    #[tokio::test]
    async fn record_switch_if_latest_different_dedupes_across_workspaces() {
        let (database, _guard) = test_database().await;
        let repo = TimelineRepository::new(database.pool().clone());
        let workspace_repo = WorkspaceRepository::new(database.pool().clone());
        let alpha = workspace_repo
            .create(CreateWorkspaceInput {
                name: "Alpha".to_string(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();
        let beta = workspace_repo
            .create(CreateWorkspaceInput {
                name: "Beta".to_string(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();

        // First-ever switch for alpha: recorded.
        assert!(repo
            .record_switch_if_latest_different(alpha.id, Utc::now(), None)
            .await
            .unwrap());
        // Same workspace again: skipped, no row appended.
        assert!(!repo
            .record_switch_if_latest_different(
                alpha.id,
                Utc::now(),
                Some(serde_json::json!({ "reason": "workspace_created" }))
            )
            .await
            .unwrap());
        // A different workspace: recorded.
        assert!(repo
            .record_switch_if_latest_different(beta.id, Utc::now(), None)
            .await
            .unwrap());
        // Back to alpha: recorded again (the active workspace changed).
        assert!(repo
            .record_switch_if_latest_different(alpha.id, Utc::now(), None)
            .await
            .unwrap());
        // And once more: skipped.
        assert!(!repo
            .record_switch_if_latest_different(alpha.id, Utc::now(), None)
            .await
            .unwrap());

        let switches = repo.list_recent(100).await.unwrap();
        let switch_count = switches
            .iter()
            .filter(|e| e.event_type == TimelineEventType::WorkspaceSwitch)
            .count();
        assert_eq!(switch_count, 3);
    }

    #[tokio::test]
    async fn concurrent_switch_recording_never_duplicates() {
        let (database, _guard) = test_database().await;
        let repo = TimelineRepository::new(database.pool().clone());
        let workspace_repo = WorkspaceRepository::new(database.pool().clone());
        let target = workspace_repo
            .create(CreateWorkspaceInput {
                name: "Race Target".to_string(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();
        let other = workspace_repo
            .create(CreateWorkspaceInput {
                name: "Other".to_string(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();

        // Prime the timeline with a switch for a different workspace, so
        // every concurrent call would *want* to record a switch — the
        // atomicity of the check-then-insert is what must hold them back.
        repo.record_switch_if_latest_different(other.id, Utc::now(), None)
            .await
            .unwrap();

        let mut set = tokio::task::JoinSet::new();
        for _ in 0..8 {
            let repo = repo.clone();
            let id = target.id;
            set.spawn(async move {
                repo.record_switch_if_latest_different(id, Utc::now(), None)
                    .await
                    .unwrap()
            });
        }

        let mut recorded = 0usize;
        while let Some(result) = set.join_next().await {
            recorded += usize::from(result.unwrap());
        }

        assert_eq!(
            recorded, 1,
            "exactly one of the concurrent calls may record a switch"
        );
        let switches = repo.list_recent(100).await.unwrap();
        let switch_count = switches
            .iter()
            .filter(|e| e.event_type == TimelineEventType::WorkspaceSwitch)
            .count();
        assert_eq!(switch_count, 2, "priming switch + exactly one winner");
    }
}
