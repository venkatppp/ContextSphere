//! Execution Memory Repository - SQLite persistence for the memory store.
//!
//! One row per (kind, source_id) so re-recording a run (e.g. an execution
//! then its planner report) upserts instead of duplicating history.

use chrono::Utc;
use sqlx::SqlitePool;
use uuid::Uuid;

use crate::copilot::memory::models::{
    embedding_to_blob, ExecutionMemoryRecord, MemoryAcceptance, MemoryKind, MemoryStatus,
    RetentionPolicy,
};
use crate::errors::DatabaseError;

/// Repository for execution memory persistence.
#[derive(Clone)]
pub struct MemoryRepository {
    pool: SqlitePool,
}

impl MemoryRepository {
    /// Creates a new memory repository.
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }

    /// The underlying connection pool (used to build companion
    /// repositories over the same store).
    pub fn pool(&self) -> &SqlitePool {
        &self.pool
    }

    /// Upserts a memory record, keyed on `(kind, source_id)`.
    pub async fn upsert(&self, record: &ExecutionMemoryRecord) -> Result<(), DatabaseError> {
        let plan = record
            .plan
            .as_ref()
            .map(serde_json::to_string)
            .transpose()?;
        let steps = serde_json::to_string(&record.steps)?;
        let reasoning = serde_json::to_string(&record.reasoning)?;
        let tools = serde_json::to_string(&record.tools_used)?;
        let failed = serde_json::to_string(&record.failed_steps)?;
        let outcome = serde_json::to_string(&record.outcome)?;
        let embedding = record.goal_embedding.as_ref().map(|e| embedding_to_blob(e));

        sqlx::query(
            r#"
            INSERT INTO execution_memory (
                id, kind, source_id, workspace_id, goal, status, plan, steps,
                reasoning, tools_used, failed_steps, error, outcome,
                goal_embedding, goal_embedding_dim, replay_count, created_at, updated_at,
                retention, retention_until, archived_at, expired_at, summary,
                compressed_at, version, parent_id
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(kind, source_id) DO UPDATE SET
                workspace_id = excluded.workspace_id,
                goal = excluded.goal,
                status = excluded.status,
                plan = excluded.plan,
                steps = excluded.steps,
                reasoning = excluded.reasoning,
                tools_used = excluded.tools_used,
                failed_steps = excluded.failed_steps,
                error = excluded.error,
                outcome = excluded.outcome,
                goal_embedding = excluded.goal_embedding,
                goal_embedding_dim = excluded.goal_embedding_dim,
                retention = excluded.retention,
                retention_until = excluded.retention_until,
                archived_at = excluded.archived_at,
                expired_at = excluded.expired_at,
                summary = excluded.summary,
                compressed_at = excluded.compressed_at,
                version = excluded.version,
                parent_id = excluded.parent_id,
                updated_at = excluded.updated_at
            "#,
        )
        .bind(record.id.to_string())
        .bind(record.kind.to_string())
        .bind(record.source_id.to_string())
        .bind(record.workspace_id)
        .bind(&record.goal)
        .bind(record.status.to_string())
        .bind(plan)
        .bind(steps)
        .bind(reasoning)
        .bind(tools)
        .bind(failed)
        .bind(record.error.as_deref())
        .bind(outcome)
        .bind(embedding)
        .bind(record.goal_embedding.as_ref().map(|e| e.len() as i64))
        .bind(record.replay_count as i64)
        .bind(record.created_at.to_rfc3339())
        .bind(record.updated_at.to_rfc3339())
        .bind(record.retention.to_string())
        .bind(record.retention_until.map(|t| t.to_rfc3339()))
        .bind(record.archived_at.map(|t| t.to_rfc3339()))
        .bind(record.expired_at.map(|t| t.to_rfc3339()))
        .bind(record.summary.as_deref())
        .bind(record.compressed_at.map(|t| t.to_rfc3339()))
        .bind(record.version as i64)
        .bind(record.parent_id.map(|id| id.to_string()))
        .execute(&self.pool)
        .await
        .map_err(|e| {
            tracing::error!(
                error = %e,
                record_id = %record.id,
                workspace_id = ?record.workspace_id,
                parent_id = ?record.parent_id,
                kind = %record.kind,
                source_id = %record.source_id,
                "failed to upsert execution_memory"
            );
            e
        })?;

        Ok(())
    }

    /// Loads one record by id.
    pub async fn get(&self, id: Uuid) -> Result<Option<ExecutionMemoryRecord>, DatabaseError> {
        let rows = sqlx::query("SELECT * FROM execution_memory WHERE id = ?")
            .bind(id.to_string())
            .fetch_all(&self.pool)
            .await?;
        let mut records = self.rows_to_records(rows).await?;
        Ok(records.pop())
    }

    /// Loads the record for a `(kind, source_id)` pair, if any.
    pub async fn get_by_source(
        &self,
        kind: MemoryKind,
        source_id: Uuid,
    ) -> Result<Option<ExecutionMemoryRecord>, DatabaseError> {
        let rows = sqlx::query("SELECT * FROM execution_memory WHERE kind = ? AND source_id = ?")
            .bind(kind.to_string())
            .bind(source_id.to_string())
            .fetch_all(&self.pool)
            .await?;
        let mut records = self.rows_to_records(rows).await?;
        Ok(records.pop())
    }

    /// Loads the records with the given ids (used by vector k-NN search:
    /// only the top candidates leave SQL).
    pub async fn get_many(
        &self,
        ids: &[Uuid],
    ) -> Result<Vec<ExecutionMemoryRecord>, DatabaseError> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let placeholders = vec!["?"; ids.len()].join(", ");
        let sql = format!("SELECT * FROM execution_memory WHERE id IN ({placeholders})");
        let mut query = sqlx::query(&sql);
        for id in ids {
            query = query.bind(id.to_string());
        }
        let rows = query.fetch_all(&self.pool).await?;
        self.rows_to_records(rows).await
    }

    /// Back-fills a record's goal embedding (written by the vector
    /// indexer). Deliberately leaves `updated_at` untouched so an index
    /// pass never re-pends the record it just indexed.
    pub async fn update_goal_embedding(
        &self,
        id: Uuid,
        embedding: Option<&[f32]>,
    ) -> Result<(), DatabaseError> {
        sqlx::query(
            "UPDATE execution_memory SET goal_embedding = ?, goal_embedding_dim = ? WHERE id = ?",
        )
        .bind(embedding.map(embedding_to_blob))
        .bind(embedding.map(|e| e.len() as i64))
        .bind(id.to_string())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Lists records matching the given filters, newest first.
    pub async fn list(
        &self,
        kind: Option<MemoryKind>,
        status: Option<MemoryStatus>,
        workspace_id: Option<Uuid>,
        limit: usize,
    ) -> Result<Vec<ExecutionMemoryRecord>, DatabaseError> {
        let mut sql = String::from("SELECT * FROM execution_memory WHERE 1 = 1");
        let mut conditions = Vec::new();
        let mut bind_kinds: Vec<String> = Vec::new();
        let mut bind_status: Vec<String> = Vec::new();
        let mut bind_workspace: Option<Uuid> = None;

        if let Some(kind) = kind {
            conditions.push("kind = ?".to_string());
            bind_kinds.push(kind.to_string());
        }
        if let Some(status) = status {
            conditions.push("status = ?".to_string());
            bind_status.push(status.to_string());
        }
        if let Some(workspace_id) = workspace_id {
            conditions.push("workspace_id = ?".to_string());
            bind_workspace = Some(workspace_id);
        }
        if !conditions.is_empty() {
            sql.push_str(&format!(" AND {}", conditions.join(" AND ")));
        }
        sql.push_str(" ORDER BY created_at DESC LIMIT ?");

        let mut query = sqlx::query(&sql);
        for value in bind_kinds {
            query = query.bind(value);
        }
        for value in bind_status {
            query = query.bind(value);
        }
        if let Some(ws) = bind_workspace {
            query = query.bind(ws);
        }
        query = query.bind(limit as i64);

        let rows = query.fetch_all(&self.pool).await?;
        self.rows_to_records(rows).await
    }

    /// Lists every record (used by retrieval/learning to rank in Rust).
    pub async fn list_all(&self) -> Result<Vec<ExecutionMemoryRecord>, DatabaseError> {
        let rows = sqlx::query("SELECT * FROM execution_memory ORDER BY created_at ASC")
            .fetch_all(&self.pool)
            .await?;
        self.rows_to_records(rows).await
    }

    /// Increments the replay counter for a record.
    pub async fn mark_replayed(&self, id: Uuid) -> Result<(), DatabaseError> {
        sqlx::query(
            "UPDATE execution_memory SET replay_count = replay_count + 1, updated_at = ? WHERE id = ?",
        )
        .bind(Utc::now().to_rfc3339())
        .bind(id.to_string())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Records user feedback on a recommendation into the acceptance
    /// ledger (RC-6 M3): accepted/rejected tallies per memory record.
    pub async fn record_acceptance(
        &self,
        memory_id: Uuid,
        accepted: bool,
    ) -> Result<(), DatabaseError> {
        let now = Utc::now().to_rfc3339();
        if accepted {
            sqlx::query(
                r#"
                INSERT INTO memory_acceptance
                    (memory_id, accepted_count, rejected_count, first_feedback_at, last_feedback_at)
                VALUES (?, 1, 0, ?, ?)
                ON CONFLICT(memory_id) DO UPDATE SET
                    accepted_count = accepted_count + 1,
                    last_feedback_at = excluded.last_feedback_at
                "#,
            )
            .bind(memory_id.to_string())
            .bind(&now)
            .bind(&now)
            .execute(&self.pool)
            .await?;
        } else {
            sqlx::query(
                r#"
                INSERT INTO memory_acceptance
                    (memory_id, accepted_count, rejected_count, first_feedback_at, last_feedback_at)
                VALUES (?, 0, 1, ?, ?)
                ON CONFLICT(memory_id) DO UPDATE SET
                    rejected_count = rejected_count + 1,
                    last_feedback_at = excluded.last_feedback_at
                "#,
            )
            .bind(memory_id.to_string())
            .bind(&now)
            .bind(&now)
            .execute(&self.pool)
            .await?;
        }
        Ok(())
    }

    /// Sets the exact acceptance tallies of a record (RC-6 M4 import /
    /// snapshot restore: ledger entries travel with exports and must be
    /// restored to their exact values, not incremented).
    pub async fn restore_acceptance(
        &self,
        memory_id: Uuid,
        accepted: u64,
        rejected: u64,
    ) -> Result<(), DatabaseError> {
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            r#"
            INSERT INTO memory_acceptance
                (memory_id, accepted_count, rejected_count, first_feedback_at, last_feedback_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(memory_id) DO UPDATE SET
                accepted_count = excluded.accepted_count,
                rejected_count = excluded.rejected_count,
                last_feedback_at = excluded.last_feedback_at
            "#,
        )
        .bind(memory_id.to_string())
        .bind(accepted as i64)
        .bind(rejected as i64)
        .bind(&now)
        .bind(&now)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Loads the full acceptance ledger keyed by memory id.
    pub async fn acceptance_map(
        &self,
    ) -> Result<std::collections::HashMap<Uuid, MemoryAcceptance>, DatabaseError> {
        type Row = (String, i64, i64);
        let rows: Vec<Row> = sqlx::query_as(
            r#"
            SELECT memory_id, accepted_count, rejected_count
            FROM memory_acceptance
            "#,
        )
        .fetch_all(&self.pool)
        .await?;

        let mut map = std::collections::HashMap::with_capacity(rows.len());
        for (memory_id, accepted, rejected) in rows {
            if let Ok(id) = Uuid::parse_str(&memory_id) {
                map.insert(
                    id,
                    MemoryAcceptance {
                        accepted: accepted.max(0) as u64,
                        rejected: rejected.max(0) as u64,
                    },
                );
            }
        }
        Ok(map)
    }

    /// Hard-deletes a memory record (duplicate merge, RC-6 M3). The
    /// acceptance ledger and the durable vector index row cascade via
    /// their `ON DELETE CASCADE` foreign keys; the in-memory vector index
    /// must be updated by the caller.
    pub async fn delete(&self, id: Uuid) -> Result<(), DatabaseError> {
        sqlx::query("DELETE FROM execution_memory WHERE id = ?")
            .bind(id.to_string())
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// Counts records by status for the stats payload.
    pub async fn counts(&self) -> Result<(u64, u64, u64, u64), DatabaseError> {
        type Row = (i64, i64, i64, i64);
        let row: Option<Row> = sqlx::query_as(
            r#"
            SELECT
                SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END),
                SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END),
                SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END),
                COUNT(*)
            FROM execution_memory
            "#,
        )
        .fetch_optional(&self.pool)
        .await?;
        match row {
            Some((success, failed, cancelled, total)) => Ok((
                success.max(0) as u64,
                failed.max(0) as u64,
                cancelled.max(0) as u64,
                total as u64,
            )),
            None => Ok((0, 0, 0, 0)),
        }
    }

    /// Total replays across all records.
    pub async fn total_replays(&self) -> Result<u64, DatabaseError> {
        type Row = (i64,);
        let row: Option<Row> = sqlx::query_as("SELECT SUM(replay_count) FROM execution_memory")
            .fetch_optional(&self.pool)
            .await?;
        Ok(match row {
            Some((sum,)) => sum.max(0) as u64,
            None => 0,
        })
    }

    /// Counts records by kind.
    pub async fn counts_by_kind(&self) -> Result<(u64, u64, u64), DatabaseError> {
        type Row = (i64, i64, i64);
        let row: Option<Row> = sqlx::query_as(
            r#"
            SELECT
                SUM(CASE WHEN kind = 'execution' THEN 1 ELSE 0 END),
                SUM(CASE WHEN kind = 'planner_report' THEN 1 ELSE 0 END),
                SUM(CASE WHEN kind = 'autonomous_session' THEN 1 ELSE 0 END)
            FROM execution_memory
            "#,
        )
        .fetch_optional(&self.pool)
        .await?;
        match row {
            Some((executions, reports, sessions)) => Ok((
                executions.max(0) as u64,
                reports.max(0) as u64,
                sessions.max(0) as u64,
            )),
            None => Ok((0, 0, 0)),
        }
    }

    fn row_to_record(
        &self,
        row: &sqlx::sqlite::SqliteRow,
    ) -> Result<ExecutionMemoryRecord, DatabaseError> {
        use sqlx::Row;
        Ok(ExecutionMemoryRecord {
            id: Uuid::parse_str(&row.get::<String, _>("id"))
                .map_err(|e| DatabaseError::IoError(e.to_string()))?,
            kind: self.parse_kind(&row.get::<String, _>("kind"))?,
            source_id: Uuid::parse_str(&row.get::<String, _>("source_id"))
                .map_err(|e| DatabaseError::IoError(e.to_string()))?,
            workspace_id: {
                let raw: Option<String> = row.try_get("workspace_id").ok().flatten();
                raw.and_then(|s| Uuid::parse_str(&s).ok())
                    .or_else(|| {
                        let raw: Option<Vec<u8>> = row.try_get("workspace_id").ok().flatten();
                        raw.and_then(|b| {
                            if b.len() == 16 {
                                let s = format!(
                                    "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
                                    b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                                    b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
                                );
                                Uuid::parse_str(&s).ok()
                            } else {
                                None
                            }
                        })
                    })
            },
            goal: row.get("goal"),
            status: self.parse_status(&row.get::<String, _>("status"))?,
            plan: row
                .get::<Option<String>, _>("plan")
                .map(|s| serde_json::from_str(&s))
                .transpose()?,
            steps: serde_json::from_str(&row.get::<String, _>("steps"))?,
            reasoning: serde_json::from_str(&row.get::<String, _>("reasoning"))?,
            tools_used: serde_json::from_str(&row.get::<String, _>("tools_used"))?,
            failed_steps: serde_json::from_str(&row.get::<String, _>("failed_steps"))?,
            error: row.get("error"),
            outcome: serde_json::from_str(&row.get::<String, _>("outcome"))?,
            goal_embedding: row
                .get::<Option<Vec<u8>>, _>("goal_embedding")
                .map(|blob| crate::copilot::memory::models::embedding_from_blob(&blob)),
            replay_count: row.get::<i64, _>("replay_count").max(0) as u64,
            created_at: parse_rfc3339(&row.get::<String, _>("created_at"))?,
            updated_at: parse_rfc3339(&row.get::<String, _>("updated_at"))?,
            retention: self.parse_retention(&row.get::<String, _>("retention"))?,
            retention_until: row
                .get::<Option<String>, _>("retention_until")
                .map(|s| parse_rfc3339(&s))
                .transpose()?,
            archived_at: row
                .get::<Option<String>, _>("archived_at")
                .map(|s| parse_rfc3339(&s))
                .transpose()?,
            expired_at: row
                .get::<Option<String>, _>("expired_at")
                .map(|s| parse_rfc3339(&s))
                .transpose()?,
            summary: row.get("summary"),
            compressed_at: row
                .get::<Option<String>, _>("compressed_at")
                .map(|s| parse_rfc3339(&s))
                .transpose()?,
            version: row.get::<i64, _>("version").max(1) as u64,
            parent_id: {
                let raw: Option<String> = row.try_get("parent_id").ok().flatten();
                raw.and_then(|s| Uuid::parse_str(&s).ok())
                    .or_else(|| {
                        let raw: Option<Vec<u8>> = row.try_get("parent_id").ok().flatten();
                        raw.and_then(|b| {
                            if b.len() == 16 {
                                let s = format!(
                                    "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
                                    b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                                    b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
                                );
                                Uuid::parse_str(&s).ok()
                            } else {
                                None
                            }
                        })
                    })
            },
        })
    }

    async fn rows_to_records(
        &self,
        rows: Vec<sqlx::sqlite::SqliteRow>,
    ) -> Result<Vec<ExecutionMemoryRecord>, DatabaseError> {
        rows.iter().map(|row| self.row_to_record(row)).collect()
    }

    fn parse_kind(&self, s: &str) -> Result<MemoryKind, DatabaseError> {
        match s {
            "execution" => Ok(MemoryKind::Execution),
            "planner_report" => Ok(MemoryKind::PlannerReport),
            "autonomous_session" => Ok(MemoryKind::AutonomousSession),
            other => Err(DatabaseError::IoError(format!(
                "Unknown memory kind: {other}"
            ))),
        }
    }

    fn parse_retention(&self, s: &str) -> Result<RetentionPolicy, DatabaseError> {
        match s {
            "permanent" => Ok(RetentionPolicy::Permanent),
            "temporary" => Ok(RetentionPolicy::Temporary),
            "archived" => Ok(RetentionPolicy::Archived),
            "expired" => Ok(RetentionPolicy::Expired),
            other => Err(DatabaseError::IoError(format!(
                "Unknown retention policy: {other}"
            ))),
        }
    }

    fn parse_status(&self, s: &str) -> Result<MemoryStatus, DatabaseError> {
        match s {
            "success" => Ok(MemoryStatus::Success),
            "failed" => Ok(MemoryStatus::Failed),
            "cancelled" => Ok(MemoryStatus::Cancelled),
            other => Err(DatabaseError::IoError(format!(
                "Unknown memory status: {other}"
            ))),
        }
    }
}

fn parse_rfc3339(s: &str) -> Result<chrono::DateTime<Utc>, DatabaseError> {
    chrono::DateTime::parse_from_rfc3339(s)
        .map(|dt| dt.with_timezone(&Utc))
        .map_err(|e| DatabaseError::IoError(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::copilot::memory::models::{MemoryOutcome, RetentionPolicy};
    use crate::database::test_database;
    use crate::errors::DatabaseError;

    fn sample_record(
        kind: MemoryKind,
        source_id: Uuid,
        goal: &str,
        status: MemoryStatus,
    ) -> ExecutionMemoryRecord {
        ExecutionMemoryRecord {
            id: Uuid::new_v4(),
            kind,
            source_id,
            workspace_id: None,
            goal: goal.to_string(),
            status,
            plan: None,
            steps: vec!["list workspaces".into(), "resume work".into()],
            reasoning: vec![],
            tools_used: vec!["list_workspaces".into(), "resume_workspace".into()],
            failed_steps: vec![],
            error: if status == MemoryStatus::Failed {
                Some("boom".into())
            } else {
                None
            },
            outcome: MemoryOutcome::default(),
            goal_embedding: None,
            replay_count: 0,
            created_at: Utc::now(),
            updated_at: Utc::now(),
            retention: RetentionPolicy::Permanent,
            retention_until: None,
            archived_at: None,
            expired_at: None,
            summary: None,
            compressed_at: None,
            version: 1,
            parent_id: None,
        }
    }

    #[tokio::test]
    async fn upsert_records_and_reads_back() {
        let (database, _guard) = test_database().await;
        let repo = MemoryRepository::new(database.pool().clone());
        let record = sample_record(
            MemoryKind::Execution,
            Uuid::new_v4(),
            "resume focus",
            MemoryStatus::Success,
        );

        repo.upsert(&record).await.expect("upsert should succeed");

        let loaded = repo
            .get(record.id)
            .await
            .expect("read should succeed")
            .expect("record exists");
        assert_eq!(loaded.goal, "resume focus");
        assert_eq!(loaded.tools_used, record.tools_used);
        assert!(loaded.steps.len() == 2);
    }

    #[tokio::test]
    async fn upsert_is_keyed_on_kind_and_source() {
        let (database, _guard) = test_database().await;
        let repo = MemoryRepository::new(database.pool().clone());
        let source = Uuid::new_v4();
        let mut record = sample_record(
            MemoryKind::Execution,
            source,
            "resume focus",
            MemoryStatus::Success,
        );
        repo.upsert(&record).await.unwrap();

        record.status = MemoryStatus::Failed;
        record.error = Some("later failure".into());
        repo.upsert(&record).await.unwrap();

        let loaded = repo
            .get_by_source(MemoryKind::Execution, source)
            .await
            .unwrap()
            .unwrap();
        assert!(matches!(loaded.status, MemoryStatus::Failed));
        assert_eq!(loaded.error.as_deref(), Some("later failure"));

        let rows = repo.list_all().await.unwrap();
        assert_eq!(rows.len(), 1, "upsert must not duplicate history");
    }

    #[tokio::test]
    async fn list_filters_by_kind_status_and_workspace() {
        let (database, _guard) = test_database().await;
        let pool = database.pool().clone();
        let repo = MemoryRepository::new(pool.clone());
        // Seed a real workspace so the memory row's FK holds.
        let ws = Uuid::new_v4();
        let now = Utc::now();
        sqlx::query(
            "INSERT OR IGNORE INTO workspaces
                (id, name, description, status, health_score, root_path, last_active_at, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(ws)
        .bind("Memory Workspace")
        .bind::<Option<String>>(None)
        .bind(crate::models::workspace::WorkspaceStatus::Active.as_str())
        .bind(0.0_f64)
        .bind::<Option<String>>(None)
        .bind(now.to_rfc3339())
        .bind(now.to_rfc3339())
        .bind(now.to_rfc3339())
        .execute(&pool)
        .await
        .expect("workspace seeding should succeed");

        let a = ExecutionMemoryRecord {
            workspace_id: Some(ws),
            ..sample_record(
                MemoryKind::Execution,
                Uuid::new_v4(),
                "goal a",
                MemoryStatus::Success,
            )
        };
        let b = sample_record(
            MemoryKind::AutonomousSession,
            Uuid::new_v4(),
            "goal b",
            MemoryStatus::Failed,
        );
        repo.upsert(&a).await.unwrap();
        repo.upsert(&b).await.unwrap();

        let executions = repo
            .list(Some(MemoryKind::Execution), None, None, 10)
            .await
            .unwrap();
        assert_eq!(executions.len(), 1);

        let in_ws = repo.list(None, None, Some(ws), 10).await.unwrap();
        assert_eq!(in_ws.len(), 1);

        let failed = repo
            .list(None, Some(MemoryStatus::Failed), None, 10)
            .await
            .unwrap();
        assert_eq!(failed.len(), 1);
        assert!(matches!(failed[0].status, MemoryStatus::Failed));
    }

    #[tokio::test]
    async fn counts_and_replays_track_history() {
        let (database, _guard) = test_database().await;
        let repo = MemoryRepository::new(database.pool().clone());
        let mut record = sample_record(
            MemoryKind::Execution,
            Uuid::new_v4(),
            "g",
            MemoryStatus::Success,
        );
        repo.upsert(&record).await.unwrap();
        record.id = Uuid::new_v4();
        record.source_id = Uuid::new_v4();
        record.status = MemoryStatus::Failed;
        repo.upsert(&record).await.unwrap();
        record.id = Uuid::new_v4();
        record.source_id = Uuid::new_v4();
        record.status = MemoryStatus::Cancelled;
        record.kind = MemoryKind::AutonomousSession;
        repo.upsert(&record).await.unwrap();

        let (success, failed, cancelled, total) = repo.counts().await.unwrap();
        assert_eq!((success, failed, cancelled, total), (1, 1, 1, 3));

        let (executions, reports, sessions) = repo.counts_by_kind().await.unwrap();
        assert_eq!((executions, reports, sessions), (2, 0, 1));

        repo.mark_replayed(record.id).await.unwrap();
        repo.mark_replayed(record.id).await.unwrap();
        assert_eq!(repo.total_replays().await.unwrap(), 2);
    }

    #[tokio::test]
    async fn acceptance_ledger_tallies_and_delete_removes() {
        let (database, _guard) = test_database().await;
        let repo = MemoryRepository::new(database.pool().clone());
        let record = sample_record(
            MemoryKind::Execution,
            Uuid::new_v4(),
            "g",
            MemoryStatus::Success,
        );
        repo.upsert(&record).await.unwrap();

        repo.record_acceptance(record.id, true).await.unwrap();
        repo.record_acceptance(record.id, true).await.unwrap();
        repo.record_acceptance(record.id, true).await.unwrap();
        repo.record_acceptance(record.id, false).await.unwrap();

        let map = repo.acceptance_map().await.unwrap();
        let entry = map.get(&record.id).expect("ledger entry exists");
        assert_eq!(entry.accepted, 3);
        assert_eq!(entry.rejected, 1);
        assert!((entry.rate() - 0.75).abs() < 1e-9);

        // Unknown records carry no entry (callers treat them as neutral).
        assert!(!map.contains_key(&Uuid::new_v4()));

        // Deleting the memory cascades its acceptance row.
        repo.delete(record.id).await.unwrap();
        assert!(repo.get(record.id).await.unwrap().is_none());
        assert!(repo.acceptance_map().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn embedding_round_trips_through_blob() {
        let (database, _guard) = test_database().await;
        let repo = MemoryRepository::new(database.pool().clone());
        let mut record = sample_record(
            MemoryKind::Execution,
            Uuid::new_v4(),
            "g",
            MemoryStatus::Success,
        );
        record.goal_embedding = Some(vec![0.1, 0.2, 0.3, 0.4]);
        repo.upsert(&record).await.unwrap();

        let loaded = repo.get(record.id).await.unwrap().unwrap();
        let embedding = loaded.goal_embedding.expect("embedding should persist");
        assert_eq!(embedding.len(), 4);
        assert!((embedding[0] - 0.1).abs() < 1e-6);

        let _ = DatabaseError::IoError("unused".into());
    }

    #[tokio::test]
    async fn get_many_loads_only_requested_ids() {
        let (database, _guard) = test_database().await;
        let repo = MemoryRepository::new(database.pool().clone());
        let a = sample_record(
            MemoryKind::Execution,
            Uuid::new_v4(),
            "goal a",
            MemoryStatus::Success,
        );
        let b = sample_record(
            MemoryKind::Execution,
            Uuid::new_v4(),
            "goal b",
            MemoryStatus::Success,
        );
        let _c = sample_record(
            MemoryKind::Execution,
            Uuid::new_v4(),
            "goal c",
            MemoryStatus::Success,
        );
        repo.upsert(&a).await.unwrap();
        repo.upsert(&b).await.unwrap();

        let loaded = repo.get_many(&[a.id, b.id]).await.unwrap();
        assert_eq!(loaded.len(), 2);
        let mut goals: Vec<&str> = loaded.iter().map(|r| r.goal.as_str()).collect();
        goals.sort();
        assert_eq!(goals, vec!["goal a", "goal b"]);
        assert!(repo.get_many(&[]).await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn update_goal_embedding_back_fills_without_touching_updated_at() {
        let (database, _guard) = test_database().await;
        let repo = MemoryRepository::new(database.pool().clone());
        let record = sample_record(
            MemoryKind::Execution,
            Uuid::new_v4(),
            "g",
            MemoryStatus::Success,
        );
        let original_updated = record.updated_at;
        repo.upsert(&record).await.unwrap();

        repo.update_goal_embedding(record.id, Some(&[0.5, 0.25, 0.125]))
            .await
            .unwrap();
        let loaded = repo.get(record.id).await.unwrap().unwrap();
        assert_eq!(
            loaded.goal_embedding.expect("embedding back-filled"),
            vec![0.5, 0.25, 0.125]
        );
        assert_eq!(
            loaded.updated_at, original_updated,
            "index back-fill must not change the record's updated_at"
        );

        repo.update_goal_embedding(record.id, None).await.unwrap();
        let loaded = repo.get(record.id).await.unwrap().unwrap();
        assert!(loaded.goal_embedding.is_none());
    }
}
