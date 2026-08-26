//! Health service for data access and persistence.

use crate::errors::DatabaseError;
use chrono::{DateTime, Duration, Utc};
use sqlx::SqlitePool;
use uuid::Uuid;

use super::models::WorkspaceHealth;

/// Service for persisting and retrieving workspace health history.
#[derive(Clone)]
pub struct HealthService {
    pool: SqlitePool,
}

impl HealthService {
    /// Creates a new health service.
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }

    /// Saves a workspace health assessment.
    ///
    /// `workspaces.id` (and therefore the FK target) stores UUIDs in
    /// sqlx's BLOB encoding, so the model's string id is parsed back to
    /// a `Uuid` before binding; binding the raw string would store TEXT
    /// and fail the foreign key.
    pub async fn save_health(&self, health: &WorkspaceHealth) -> Result<(), DatabaseError> {
        let health_json = serde_json::to_string(health)?;
        let workspace_uuid = Uuid::parse_str(&health.workspace_id)
            .map_err(|e| DatabaseError::InvalidInput(format!(
                "workspace health has invalid workspace id `{}`: {e}",
                health.workspace_id)))?;

        sqlx::query(
            r#"
            INSERT INTO workspace_health_history (workspace_id, overall_score, factors_json, calculated_at)
            VALUES (?, ?, ?, ?)
            "#
        )
        .bind(workspace_uuid)
        .bind(health.overall_score)
        .bind(&health_json)
        .bind(health.calculated_at)
        .execute(&self.pool)
        .await?;

        Ok(())
    }

    /// Gets the most recent health assessment for a workspace.
    pub async fn get_latest_health(
        &self,
        workspace_id: Uuid,
    ) -> Result<Option<WorkspaceHealth>, DatabaseError> {
        let record = sqlx::query_as::<_, HealthRow>(
            r#"
            SELECT workspace_id, overall_score, factors_json, calculated_at
            FROM workspace_health_history
            WHERE workspace_id = ?
            ORDER BY calculated_at DESC
            LIMIT 1
            "#,
        )
        .bind(workspace_id)
        .fetch_optional(&self.pool)
        .await?;

        if let Some(r) = record {
            let mut health: WorkspaceHealth = serde_json::from_str(&r.factors_json)?;
            health.workspace_id = r.workspace_id.to_string();
            health.overall_score = r.overall_score;
            Ok(Some(health))
        } else {
            Ok(None)
        }
    }

    /// Gets health history for a workspace within a time range.
    pub async fn get_health_history(
        &self,
        workspace_id: Uuid,
        since: DateTime<Utc>,
    ) -> Result<Vec<WorkspaceHealth>, DatabaseError> {
        let records = sqlx::query_as::<_, HealthRow>(
            r#"
            SELECT workspace_id, overall_score, factors_json, calculated_at
            FROM workspace_health_history
            WHERE workspace_id = ? AND calculated_at >= ?
            ORDER BY calculated_at ASC
            "#,
        )
        .bind(workspace_id)
        .bind(since)
        .fetch_all(&self.pool)
        .await?;

        let mut history = Vec::new();
        for r in records {
            let mut health: WorkspaceHealth = serde_json::from_str(&r.factors_json)?;
            health.workspace_id = r.workspace_id.to_string();
            health.overall_score = r.overall_score;
            history.push(health);
        }

        Ok(history)
    }

    /// Calculates trend by comparing current score to previous assessment.
    pub async fn calculate_trend(
        &self,
        workspace_id: Uuid,
        current_score: f64,
    ) -> Result<Option<f64>, DatabaseError> {
        let record = sqlx::query_as::<_, (f64,)>(
            r#"
            SELECT overall_score
            FROM workspace_health_history
            WHERE workspace_id = ?
            ORDER BY calculated_at DESC
            LIMIT 1 OFFSET 1
            "#,
        )
        .bind(workspace_id)
        .fetch_optional(&self.pool)
        .await?;

        Ok(record.map(|r| current_score - r.0))
    }

    /// Cleans up old health history entries (keeps last 90 days).
    pub async fn cleanup_old_history(&self) -> Result<u64, DatabaseError> {
        let cutoff = Utc::now() - Duration::days(90);

        let result = sqlx::query(
            r#"
            DELETE FROM workspace_health_history
            WHERE calculated_at < ?
            "#,
        )
        .bind(cutoff)
        .execute(&self.pool)
        .await?;

        Ok(result.rows_affected())
    }
}

/// Row type for deserializing health records. `workspace_id` is a Uuid
/// so sqlx decodes the BLOB representation used by `workspaces.id`.
#[derive(sqlx::FromRow)]
struct HealthRow {
    workspace_id: Uuid,
    overall_score: f64,
    factors_json: String,
    #[allow(dead_code)]
    calculated_at: DateTime<Utc>,
}
