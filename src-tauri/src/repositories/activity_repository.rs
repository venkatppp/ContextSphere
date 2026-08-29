use chrono::{DateTime, Utc};
use sqlx::SqlitePool;
use uuid::Uuid;

use crate::errors::DatabaseError;
use crate::models::activity::{ActivityEvent, ActivityEventRow, NewActivityEvent};

#[derive(Debug, Clone)]
pub struct ActivityRepository {
    pool: SqlitePool,
}

const SELECT_COLUMNS: &str =
    "id, workspace_id, app_name, bundle_id, window_title, url_domain, url_title, event_type, started_at, ended_at, duration_seconds, metadata, created_at";

impl ActivityRepository {
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }

    pub async fn create(&self, input: NewActivityEvent) -> Result<ActivityEvent, DatabaseError> {
        let id = Uuid::new_v4();
        let now = Utc::now();
        let metadata_json = input
            .metadata
            .as_ref()
            .map(serde_json::to_string)
            .transpose()
            .map_err(|e| DatabaseError::InvalidInput(format!("invalid activity metadata: {e}")))?;

        sqlx::query(
            "INSERT INTO activity_events (id, workspace_id, app_name, bundle_id, window_title, url_domain, url_title, event_type, started_at, ended_at, duration_seconds, metadata, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(id)
        .bind(input.workspace_id)
        .bind(&input.app_name)
        .bind(&input.bundle_id)
        .bind(&input.window_title)
        .bind(&input.url_domain)
        .bind(&input.url_title)
        .bind(input.event_type.as_str())
        .bind(input.started_at)
        .bind(input.ended_at)
        .bind(input.duration_seconds)
        .bind(&metadata_json)
        .bind(now)
        .execute(&self.pool)
        .await?;

        self.get_by_id(id).await
    }

    pub async fn get_by_id(&self, id: Uuid) -> Result<ActivityEvent, DatabaseError> {
        let row: ActivityEventRow = sqlx::query_as(&format!(
            "SELECT {SELECT_COLUMNS} FROM activity_events WHERE id = ?"
        ))
        .bind(id)
        .fetch_optional(&self.pool)
        .await?
        .ok_or_else(|| DatabaseError::not_found("activity_event", id.to_string()))?;
        ActivityEvent::try_from(row)
    }

    /// Lists activity events for a workspace within a time window, newest first.
    pub async fn list_by_workspace_window(
        &self,
        workspace_id: Option<Uuid>,
        since: DateTime<Utc>,
        until: DateTime<Utc>,
        limit: Option<i64>,
    ) -> Result<Vec<ActivityEvent>, DatabaseError> {
        let lim = limit.unwrap_or(200);
        let rows: Vec<ActivityEventRow> = if let Some(ws) = workspace_id {
            sqlx::query_as(&format!(
                "SELECT {SELECT_COLUMNS} FROM activity_events
                 WHERE (workspace_id = ? OR workspace_id IS NULL)
                   AND started_at >= ? AND started_at <= ?
                 ORDER BY started_at DESC LIMIT ?"
            ))
            .bind(ws)
            .bind(since)
            .bind(until)
            .bind(lim)
            .fetch_all(&self.pool)
            .await?
        } else {
            sqlx::query_as(&format!(
                "SELECT {SELECT_COLUMNS} FROM activity_events
                 WHERE started_at >= ? AND started_at <= ?
                 ORDER BY started_at DESC LIMIT ?"
            ))
            .bind(since)
            .bind(until)
            .bind(lim)
            .fetch_all(&self.pool)
            .await?
        };
        rows.into_iter().map(ActivityEvent::try_from).collect()
    }

    /// Lists recent activity events across all workspaces.
    pub async fn list_recent(&self, limit: i64) -> Result<Vec<ActivityEvent>, DatabaseError> {
        let rows: Vec<ActivityEventRow> = sqlx::query_as(&format!(
            "SELECT {SELECT_COLUMNS} FROM activity_events ORDER BY started_at DESC LIMIT ?"
        ))
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter().map(ActivityEvent::try_from).collect()
    }

    /// Counts distinct apps in window.
    pub async fn distinct_app_count(
        &self,
        workspace_id: Option<Uuid>,
        since: DateTime<Utc>,
        until: DateTime<Utc>,
    ) -> Result<i64, DatabaseError> {
        let count: i64 = if let Some(ws) = workspace_id {
            sqlx::query_scalar(
                "SELECT COUNT(DISTINCT app_name) FROM activity_events
                 WHERE (workspace_id = ? OR workspace_id IS NULL)
                   AND started_at >= ? AND started_at <= ? AND event_type = 'app_foreground'",
            )
            .bind(ws)
            .bind(since)
            .bind(until)
            .fetch_one(&self.pool)
            .await?
        } else {
            sqlx::query_scalar(
                "SELECT COUNT(DISTINCT app_name) FROM activity_events
                 WHERE started_at >= ? AND started_at <= ? AND event_type = 'app_foreground'",
            )
            .bind(since)
            .bind(until)
            .fetch_one(&self.pool)
            .await?
        };
        Ok(count)
    }

    pub async fn distinct_domain_count(
        &self,
        workspace_id: Option<Uuid>,
        since: DateTime<Utc>,
        until: DateTime<Utc>,
    ) -> Result<i64, DatabaseError> {
        let count: i64 = if let Some(ws) = workspace_id {
            sqlx::query_scalar(
                "SELECT COUNT(DISTINCT url_domain) FROM activity_events
                 WHERE (workspace_id = ? OR workspace_id IS NULL)
                   AND started_at >= ? AND started_at <= ? AND event_type = 'web_visit' AND url_domain IS NOT NULL",
            )
            .bind(ws)
            .bind(since)
            .bind(until)
            .fetch_one(&self.pool)
            .await?
        } else {
            sqlx::query_scalar(
                "SELECT COUNT(DISTINCT url_domain) FROM activity_events
                 WHERE started_at >= ? AND started_at <= ? AND event_type = 'web_visit' AND url_domain IS NOT NULL",
            )
            .bind(since)
            .bind(until)
            .fetch_one(&self.pool)
            .await?
        };
        Ok(count)
    }

    /// Deletes activity older than cutoff — for pruning tests.
    #[cfg(test)]
    pub async fn delete_all(&self) -> Result<(), DatabaseError> {
        sqlx::query("DELETE FROM activity_events").execute(&self.pool).await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::test_database;
    use crate::models::activity::ActivityEventType;
    use crate::models::CreateWorkspaceInput;
    use crate::repositories::WorkspaceRepository;
    use chrono::Utc;

    async fn setup() -> (ActivityRepository, Option<Uuid>, tempfile::TempDir) {
        let (database, tmp) = test_database().await;
        let repo = ActivityRepository::new(database.pool().clone());
        let ws_repo = WorkspaceRepository::new(database.pool().clone());
        let ws = ws_repo
            .create(CreateWorkspaceInput {
                name: "ws".into(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();
        (repo, Some(ws.id), tmp)
    }

    #[tokio::test]
    async fn create_and_get_round_trip() {
        let (repo, ws, _guard) = setup().await;
        let now = Utc::now();
        let ev = repo
            .create(NewActivityEvent {
                workspace_id: ws,
                app_name: "Xcode".into(),
                bundle_id: Some("com.apple.dt.Xcode".into()),
                window_title: Some("GraphView.swift".into()),
                url_domain: None,
                url_title: None,
                event_type: ActivityEventType::AppForeground,
                started_at: now,
                ended_at: None,
                duration_seconds: None,
                metadata: None,
            })
            .await
            .unwrap();
        assert_eq!(ev.app_name, "Xcode");
        let fetched = repo.get_by_id(ev.id).await.unwrap();
        assert_eq!(fetched.id, ev.id);
    }

    #[tokio::test]
    async fn distinct_counts() {
        let (repo, ws, _guard) = setup().await;
        let now = Utc::now();
        repo.create(NewActivityEvent {
            workspace_id: ws,
            app_name: "Xcode".into(),
            bundle_id: None,
            window_title: None,
            url_domain: None,
            url_title: None,
            event_type: ActivityEventType::AppForeground,
            started_at: now,
            ended_at: Some(now + chrono::Duration::seconds(60)),
            duration_seconds: Some(60),
            metadata: None,
        })
        .await
        .unwrap();
        repo.create(NewActivityEvent {
            workspace_id: ws,
            app_name: "Safari".into(),
            bundle_id: None,
            window_title: None,
            url_domain: Some("developer.apple.com".into()),
            url_title: Some("Docs".into()),
            event_type: ActivityEventType::WebVisit,
            started_at: now + chrono::Duration::seconds(70),
            ended_at: Some(now + chrono::Duration::seconds(130)),
            duration_seconds: Some(60),
            metadata: None,
        })
        .await
        .unwrap();
        let apps = repo
            .distinct_app_count(ws, now - chrono::Duration::hours(1), now + chrono::Duration::hours(1))
            .await
            .unwrap();
        assert_eq!(apps, 1); // only app_foreground counted as app
        let domains = repo
            .distinct_domain_count(ws, now - chrono::Duration::hours(1), now + chrono::Duration::hours(1))
            .await
            .unwrap();
        assert_eq!(domains, 1);
    }
}
