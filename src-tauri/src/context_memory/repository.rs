//! Context Memory Repository for persistence.

use crate::context_memory::models::{
    ContextSnapshot, CreateSnapshotRequest, SnapshotType, WorkspaceRelationship,
    WorkspaceRelationshipType,
};
use crate::errors::DatabaseError;
use chrono::{DateTime, Utc};
use sqlx::{Row, SqlitePool};

/// Repository for context memory persistence.
#[derive(Clone)]
pub struct ContextMemoryRepository {
    pool: SqlitePool,
}

impl ContextMemoryRepository {
    /// Creates a new context memory repository.
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }

    /// Creates a context snapshot.
    pub async fn create_snapshot(
        &self,
        request: CreateSnapshotRequest,
    ) -> Result<ContextSnapshot, DatabaseError> {
        let snapshot_type_str = request.snapshot_type.as_str();
        let active_files_json = serde_json::to_string(&request.active_files)?;
        let session_summary_json = request
            .session_summary
            .as_ref()
            .map(serde_json::to_string)
            .transpose()?;
        let timeline_refs_json = request
            .timeline_references
            .as_ref()
            .map(serde_json::to_string)
            .transpose()?;
        let analytics_json = request
            .analytics_summary
            .as_ref()
            .map(serde_json::to_string)
            .transpose()?;
        let recommendations_json = request
            .recommendations_summary
            .as_ref()
            .map(serde_json::to_string)
            .transpose()?;
        let metadata_json = request
            .metadata
            .as_ref()
            .map(serde_json::to_string)
            .transpose()?
            .unwrap_or_else(|| serde_json::to_string(&serde_json::json!({})).unwrap());

        let result = sqlx::query(
            r#"
            INSERT INTO context_snapshots (
                workspace_id, snapshot_type, active_files, session_summary,
                timeline_references, analytics_summary, health_score,
                recommendations_summary, metadata
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            "#,
        )
        .bind(&request.workspace_id)
        .bind(snapshot_type_str)
        .bind(&active_files_json)
        .bind(session_summary_json.as_deref())
        .bind(timeline_refs_json.as_deref())
        .bind(analytics_json.as_deref())
        .bind(request.health_score)
        .bind(recommendations_json.as_deref())
        .bind(&metadata_json)
        .execute(&self.pool)
        .await?;

        let id = result.last_insert_rowid();

        Ok(ContextSnapshot {
            id,
            workspace_id: request.workspace_id,
            snapshot_type: request.snapshot_type,
            captured_at: Utc::now(),
            active_files: request.active_files,
            session_summary: request.session_summary,
            timeline_references: request.timeline_references,
            analytics_summary: request.analytics_summary,
            health_score: request.health_score,
            recommendations_summary: request.recommendations_summary,
            metadata: request.metadata.unwrap_or_else(|| serde_json::json!({})),
        })
    }

    /// Gets context snapshots for a workspace.
    pub async fn get_workspace_snapshots(
        &self,
        workspace_id: &str,
        limit: i64,
    ) -> Result<Vec<ContextSnapshot>, DatabaseError> {
        let rows = sqlx::query(
            r#"
            SELECT id, workspace_id, snapshot_type, captured_at, active_files,
                   session_summary, timeline_references, analytics_summary,
                   health_score, recommendations_summary, metadata
            FROM context_snapshots
            WHERE workspace_id = ?
            ORDER BY captured_at DESC
            LIMIT ?
            "#,
        )
        .bind(workspace_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;

        let mut snapshots = Vec::new();
        for row in rows {
            snapshots.push(self.parse_snapshot_row(row)?);
        }

        Ok(snapshots)
    }

    /// Gets the most recent snapshot for a workspace.
    pub async fn get_latest_snapshot(
        &self,
        workspace_id: &str,
    ) -> Result<Option<ContextSnapshot>, DatabaseError> {
        let row = sqlx::query(
            r#"
            SELECT id, workspace_id, snapshot_type, captured_at, active_files,
                   session_summary, timeline_references, analytics_summary,
                   health_score, recommendations_summary, metadata
            FROM context_snapshots
            WHERE workspace_id = ?
            ORDER BY captured_at DESC
            LIMIT 1
            "#,
        )
        .bind(workspace_id)
        .fetch_optional(&self.pool)
        .await?;

        match row {
            Some(row) => Ok(Some(self.parse_snapshot_row(row)?)),
            None => Ok(None),
        }
    }

    /// Creates or updates a workspace relationship.
    pub async fn upsert_workspace_relationship(
        &self,
        source_id: &str,
        target_id: &str,
        relationship_type: WorkspaceRelationshipType,
        strength: f64,
        evidence: serde_json::Value,
    ) -> Result<WorkspaceRelationship, DatabaseError> {
        let rel_type_str = relationship_type.as_str();
        let evidence_json = serde_json::to_string(&evidence)?;
        let now = Utc::now().to_rfc3339();

        sqlx::query(
            r#"
            INSERT INTO workspace_relationships_v2 (
                source_workspace_id, target_workspace_id, relationship_type,
                strength, evidence, detected_at, last_updated
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_workspace_id, target_workspace_id, relationship_type)
            DO UPDATE SET
                strength = excluded.strength,
                evidence = excluded.evidence,
                last_updated = excluded.last_updated
            "#,
        )
        .bind(source_id)
        .bind(target_id)
        .bind(rel_type_str)
        .bind(strength)
        .bind(&evidence_json)
        .bind(&now)
        .bind(&now)
        .execute(&self.pool)
        .await?;

        Ok(WorkspaceRelationship {
            id: 0, // Will be updated by actual query
            source_workspace_id: source_id.to_string(),
            target_workspace_id: target_id.to_string(),
            relationship_type,
            strength,
            evidence,
            detected_at: Utc::now(),
            last_updated: Utc::now(),
        })
    }

    /// Gets related workspaces.
    pub async fn get_related_workspaces(
        &self,
        workspace_id: &str,
        min_strength: f64,
        limit: i64,
    ) -> Result<Vec<WorkspaceRelationship>, DatabaseError> {
        let rows = sqlx::query(
            r#"
            SELECT id, source_workspace_id, target_workspace_id, relationship_type,
                   strength, evidence, detected_at, last_updated
            FROM workspace_relationships_v2
            WHERE source_workspace_id = ? AND strength >= ?
            ORDER BY strength DESC
            LIMIT ?
            "#,
        )
        .bind(workspace_id)
        .bind(min_strength)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;

        let mut relationships = Vec::new();
        for row in rows {
            relationships.push(self.parse_relationship_row(row)?);
        }

        Ok(relationships)
    }

    fn parse_snapshot_row(
        &self,
        row: sqlx::sqlite::SqliteRow,
    ) -> Result<ContextSnapshot, DatabaseError> {
        let snapshot_type_str: String = row.get("snapshot_type");
        let snapshot_type = match snapshot_type_str.as_str() {
            "manual" => SnapshotType::Manual,
            "milestone" => SnapshotType::Milestone,
            "auto" => SnapshotType::Auto,
            _ => SnapshotType::Auto,
        };

        let active_files_json: String = row.get("active_files");
        let active_files: Vec<String> = serde_json::from_str(&active_files_json)?;

        let session_summary: Option<String> = row.get("session_summary");
        let session_summary_val = session_summary
            .as_deref()
            .map(serde_json::from_str)
            .transpose()?;

        let timeline_refs: Option<String> = row.get("timeline_references");
        let timeline_refs_val = timeline_refs
            .as_deref()
            .map(serde_json::from_str)
            .transpose()?;

        let analytics: Option<String> = row.get("analytics_summary");
        let analytics_val = analytics.as_deref().map(serde_json::from_str).transpose()?;

        let recommendations: Option<String> = row.get("recommendations_summary");
        let recommendations_val = recommendations
            .as_deref()
            .map(serde_json::from_str)
            .transpose()?;

        let metadata_str: String = row.get("metadata");
        let metadata: serde_json::Value = serde_json::from_str(&metadata_str)?;

        let captured_at_str: String = row.get("captured_at");
        let captured_at = DateTime::parse_from_rfc3339(&captured_at_str)
            .map_err(|e| DatabaseError::InvalidInput(format!("Invalid timestamp: {}", e)))?
            .with_timezone(&Utc);

        Ok(ContextSnapshot {
            id: row.get("id"),
            workspace_id: row.get("workspace_id"),
            snapshot_type,
            captured_at,
            active_files,
            session_summary: session_summary_val,
            timeline_references: timeline_refs_val,
            analytics_summary: analytics_val,
            health_score: row.get("health_score"),
            recommendations_summary: recommendations_val,
            metadata,
        })
    }

    fn parse_relationship_row(
        &self,
        row: sqlx::sqlite::SqliteRow,
    ) -> Result<WorkspaceRelationship, DatabaseError> {
        let rel_type_str: String = row.get("relationship_type");
        let relationship_type = match rel_type_str.as_str() {
            "shared_files" => WorkspaceRelationshipType::SharedFiles,
            "shared_folders" => WorkspaceRelationshipType::SharedFolders,
            "shared_tech" => WorkspaceRelationshipType::SharedTech,
            "similar_patterns" => WorkspaceRelationshipType::SimilarPatterns,
            _ => WorkspaceRelationshipType::SharedFiles,
        };

        let evidence_str: String = row.get("evidence");
        let evidence: serde_json::Value = serde_json::from_str(&evidence_str)?;

        let detected_at_str: String = row.get("detected_at");
        let detected_at = DateTime::parse_from_rfc3339(&detected_at_str)
            .map_err(|e| DatabaseError::InvalidInput(format!("Invalid timestamp: {}", e)))?
            .with_timezone(&Utc);

        let last_updated_str: String = row.get("last_updated");
        let last_updated = DateTime::parse_from_rfc3339(&last_updated_str)
            .map_err(|e| DatabaseError::InvalidInput(format!("Invalid timestamp: {}", e)))?
            .with_timezone(&Utc);

        Ok(WorkspaceRelationship {
            id: row.get("id"),
            source_workspace_id: row.get("source_workspace_id"),
            target_workspace_id: row.get("target_workspace_id"),
            relationship_type,
            strength: row.get("strength"),
            evidence,
            detected_at,
            last_updated,
        })
    }
}
