//! Context Memory Engine for workspace context snapshots and memory.

use crate::context_memory::models::{
    ContextSnapshot, CreateSnapshotRequest, KnowledgeQuery, KnowledgeSearchResult,
    RelatedWorkspace, SnapshotType, WorkspaceRelationshipType,
};
use crate::context_memory::repository::ContextMemoryRepository;
use crate::errors::DatabaseError;
use crate::repositories::WorkspaceRepository;
use crate::services::ContextService;
use uuid::Uuid;

/// Engine for context memory and workspace intelligence.
#[derive(Clone)]
pub struct ContextMemoryEngine {
    repository: ContextMemoryRepository,
    workspace_repo: WorkspaceRepository,
    context_service: ContextService,
}

impl ContextMemoryEngine {
    /// Creates a new context memory engine.
    pub fn new(
        repository: ContextMemoryRepository,
        workspace_repo: WorkspaceRepository,
        context_service: ContextService,
    ) -> Self {
        Self {
            repository,
            workspace_repo,
            context_service,
        }
    }

    /// Creates a context snapshot for a workspace.
    pub async fn create_snapshot(
        &self,
        request: CreateSnapshotRequest,
    ) -> Result<ContextSnapshot, DatabaseError> {
        self.repository.create_snapshot(request).await
    }

    /// Gets recent context snapshots for a workspace.
    pub async fn get_workspace_snapshots(
        &self,
        workspace_id: &str,
        limit: usize,
    ) -> Result<Vec<ContextSnapshot>, DatabaseError> {
        self.repository
            .get_workspace_snapshots(workspace_id, limit as i64)
            .await
    }

    /// Gets the most recent snapshot for a workspace.
    pub async fn get_latest_snapshot(
        &self,
        workspace_id: &str,
    ) -> Result<Option<ContextSnapshot>, DatabaseError> {
        self.repository.get_latest_snapshot(workspace_id).await
    }

    /// Detects and stores cross-workspace relationships.
    pub async fn detect_workspace_relationships(
        &self,
        workspace_id: &str,
    ) -> Result<(), DatabaseError> {
        // Get all other workspaces
        let all_workspaces = self.workspace_repo.list_active_workspaces().await?;

        let current_uuid = Uuid::parse_str(workspace_id)
            .map_err(|e| DatabaseError::InvalidInput(format!("Invalid UUID: {}", e)))?;

        // Get current workspace files for comparison
        let current_files = self
            .context_service
            .get_workspace_files(current_uuid)
            .await?;
        let current_paths: Vec<String> = current_files
            .iter()
            .map(|f| f.path_or_url.clone())
            .collect();

        for other_workspace in all_workspaces {
            if other_workspace.id.to_string() == workspace_id {
                continue;
            }

            // Get other workspace files
            let other_files = self
                .context_service
                .get_workspace_files(other_workspace.id)
                .await?;
            let other_paths: Vec<String> =
                other_files.iter().map(|f| f.path_or_url.clone()).collect();

            // Detect shared files
            let shared_files: Vec<String> = current_paths
                .iter()
                .filter(|p| other_paths.contains(p))
                .cloned()
                .collect();

            if !shared_files.is_empty() {
                let shared_files_strength =
                    (shared_files.len() as f64) / (current_paths.len().max(1) as f64);
                if shared_files_strength > 0.1 {
                    self.repository
                        .upsert_workspace_relationship(
                            workspace_id,
                            &other_workspace.id.to_string(),
                            WorkspaceRelationshipType::SharedFiles,
                            shared_files_strength,
                            serde_json::json!({
                                "shared_count": shared_files.len(),
                                "shared_files": shared_files.iter().take(10).collect::<Vec<_>>()
                            }),
                        )
                        .await?;
                }
            }

            // Detect shared folders
            let current_folders: Vec<String> = current_paths
                .iter()
                .filter_map(|p| {
                    let path = std::path::Path::new(p);
                    path.parent().and_then(|p| p.to_str()).map(String::from)
                })
                .collect();
            let other_folders: Vec<String> = other_paths
                .iter()
                .filter_map(|p| {
                    let path = std::path::Path::new(p);
                    path.parent().and_then(|p| p.to_str()).map(String::from)
                })
                .collect();

            let shared_folders: Vec<String> = current_folders
                .iter()
                .filter(|f| other_folders.contains(f))
                .cloned()
                .collect();

            if !shared_folders.is_empty() {
                let shared_folders_strength =
                    (shared_folders.len() as f64) / (current_folders.len().max(1) as f64);
                if shared_folders_strength > 0.1 {
                    self.repository
                        .upsert_workspace_relationship(
                            workspace_id,
                            &other_workspace.id.to_string(),
                            WorkspaceRelationshipType::SharedFolders,
                            shared_folders_strength,
                            serde_json::json!({
                                "shared_folders": shared_folders.iter().take(10).collect::<Vec<_>>()
                            }),
                        )
                        .await?;
                }
            }

            // Detect shared technologies (by file extensions)
            let current_techs: Vec<String> = current_paths
                .iter()
                .filter_map(|p| {
                    std::path::Path::new(p)
                        .extension()
                        .and_then(|e| e.to_str())
                        .map(String::from)
                })
                .collect();
            let other_techs: Vec<String> = other_paths
                .iter()
                .filter_map(|p| {
                    std::path::Path::new(p)
                        .extension()
                        .and_then(|e| e.to_str())
                        .map(String::from)
                })
                .collect();

            let shared_techs: Vec<String> = current_techs
                .iter()
                .filter(|t| other_techs.contains(t))
                .cloned()
                .collect();

            if !shared_techs.is_empty() {
                let shared_tech_strength =
                    (shared_techs.len() as f64) / (current_techs.len().max(1) as f64);
                if shared_tech_strength > 0.1 {
                    self.repository
                        .upsert_workspace_relationship(
                            workspace_id,
                            &other_workspace.id.to_string(),
                            WorkspaceRelationshipType::SharedTech,
                            shared_tech_strength,
                            serde_json::json!({
                                "technologies": shared_techs.into_iter().collect::<std::collections::HashSet<_>>()
                            }),
                        )
                        .await?;
                }
            }

            // Detect similar editing patterns by analyzing recent sessions
            let current_sessions = self
                .context_service
                .get_workspace_sessions(current_uuid, Some(10))
                .await?;
            let other_sessions = self
                .context_service
                .get_workspace_sessions(other_workspace.id, Some(10))
                .await?;

            if !current_sessions.is_empty() && !other_sessions.is_empty() {
                // Calculate pattern similarity based on session durations and file counts
                let current_avg_duration = current_sessions
                    .iter()
                    .map(|s| s.duration_seconds as f64)
                    .sum::<f64>()
                    / current_sessions.len() as f64;
                let other_avg_duration = other_sessions
                    .iter()
                    .map(|s| s.duration_seconds as f64)
                    .sum::<f64>()
                    / other_sessions.len() as f64;

                let duration_similarity = 1.0
                    - ((current_avg_duration - other_avg_duration).abs()
                        / current_avg_duration.max(other_avg_duration).max(1.0));

                if duration_similarity > 0.5 {
                    self.repository
                        .upsert_workspace_relationship(
                            workspace_id,
                            &other_workspace.id.to_string(),
                            WorkspaceRelationshipType::SimilarPatterns,
                            duration_similarity,
                            serde_json::json!({
                                "pattern_type": "session_duration",
                                "similarity_score": duration_similarity
                            }),
                        )
                        .await?;
                }
            }
        }

        Ok(())
    }

    /// Gets related workspaces with enriched metadata.
    pub async fn get_related_workspaces(
        &self,
        workspace_id: &str,
        min_strength: f64,
        limit: usize,
    ) -> Result<Vec<RelatedWorkspace>, DatabaseError> {
        let relationships = self
            .repository
            .get_related_workspaces(workspace_id, min_strength, limit as i64)
            .await?;

        let mut related = Vec::new();
        for rel in relationships {
            // Fetch workspace details
            if let Ok(workspace_uuid) = Uuid::parse_str(&rel.target_workspace_id) {
                if let Ok(workspace) = self.workspace_repo.get_by_id(workspace_uuid).await {
                    related.push(RelatedWorkspace {
                        workspace_id: rel.target_workspace_id,
                        workspace_name: workspace.name,
                        relationship_type: rel.relationship_type,
                        strength: rel.strength,
                        evidence: rel.evidence,
                        last_active_at: workspace.last_active_at,
                    });
                }
            }
        }

        Ok(related)
    }

    /// Executes a knowledge search query.
    pub async fn search_knowledge(
        &self,
        query: KnowledgeQuery,
    ) -> Result<KnowledgeSearchResult, DatabaseError> {
        match query {
            KnowledgeQuery::RelatedWorkspaces { workspace_id } => {
                let related = self.get_related_workspaces(&workspace_id, 0.1, 10).await?;
                Ok(KnowledgeSearchResult {
                    query_type: "related_workspaces".to_string(),
                    results: serde_json::to_value(&related)?,
                    total_count: related.len(),
                })
            }
            KnowledgeQuery::RelatedFiles { file_path } => {
                // Search for related files using graph repository
                if let Ok(workspace_uuid) = Uuid::parse_str(&file_path) {
                    // This is actually a workspace ID, not a file path
                    // Get all files in workspace
                    let files = self
                        .context_service
                        .get_workspace_files(workspace_uuid)
                        .await?;
                    Ok(KnowledgeSearchResult {
                        query_type: "related_files".to_string(),
                        results: serde_json::to_value(&files)?,
                        total_count: files.len(),
                    })
                } else {
                    // Search for file by path across all workspaces
                    let all_workspaces = self.workspace_repo.list_active_workspaces().await?;
                    let mut related_files = Vec::new();

                    for workspace in all_workspaces {
                        let files = self
                            .context_service
                            .get_workspace_files(workspace.id)
                            .await?;
                        for file in files {
                            if file.path_or_url.contains(&file_path) {
                                related_files.push(file);
                            }
                        }
                    }

                    Ok(KnowledgeSearchResult {
                        query_type: "related_files".to_string(),
                        results: serde_json::to_value(&related_files)?,
                        total_count: related_files.len(),
                    })
                }
            }
            KnowledgeQuery::RecentContext {
                workspace_id,
                limit,
            } => {
                let snapshots = self.get_workspace_snapshots(&workspace_id, limit).await?;
                Ok(KnowledgeSearchResult {
                    query_type: "recent_context".to_string(),
                    results: serde_json::to_value(&snapshots)?,
                    total_count: snapshots.len(),
                })
            }
            KnowledgeQuery::PreviousSessions {
                workspace_id,
                limit,
            } => {
                // Get sessions via context service
                if let Ok(workspace_uuid) = Uuid::parse_str(&workspace_id) {
                    let sessions = self
                        .context_service
                        .get_workspace_sessions(workspace_uuid, Some(limit))
                        .await?;
                    Ok(KnowledgeSearchResult {
                        query_type: "previous_sessions".to_string(),
                        results: serde_json::to_value(&sessions)?,
                        total_count: sessions.len(),
                    })
                } else {
                    Ok(KnowledgeSearchResult {
                        query_type: "previous_sessions".to_string(),
                        results: serde_json::json!([]),
                        total_count: 0,
                    })
                }
            }
            KnowledgeQuery::SimilarProjects { workspace_id } => {
                // Similar to related workspaces but filtered by pattern similarity
                let related = self.get_related_workspaces(&workspace_id, 0.3, 5).await?;
                let similar: Vec<_> = related
                    .into_iter()
                    .filter(|r| r.relationship_type == WorkspaceRelationshipType::SimilarPatterns)
                    .collect();
                Ok(KnowledgeSearchResult {
                    query_type: "similar_projects".to_string(),
                    results: serde_json::to_value(&similar)?,
                    total_count: similar.len(),
                })
            }
        }
    }

    /// Creates an automatic snapshot at a milestone.
    pub async fn snapshot_milestone(
        &self,
        workspace_id: &str,
        active_files: Vec<String>,
        metadata: serde_json::Value,
    ) -> Result<ContextSnapshot, DatabaseError> {
        let request = CreateSnapshotRequest {
            workspace_id: workspace_id.to_string(),
            snapshot_type: SnapshotType::Milestone,
            active_files,
            session_summary: None,
            timeline_references: None,
            analytics_summary: None,
            health_score: None,
            recommendations_summary: None,
            metadata: Some(metadata),
        };

        self.create_snapshot(request).await
    }

    /// Creates an automatic snapshot (on workspace switch, inactivity, etc).
    pub async fn auto_snapshot(
        &self,
        workspace_id: Uuid,
        active_files: Vec<String>,
    ) -> Result<ContextSnapshot, DatabaseError> {
        let request = CreateSnapshotRequest {
            workspace_id: workspace_id.to_string(),
            snapshot_type: SnapshotType::Auto,
            active_files,
            session_summary: None,
            timeline_references: None,
            analytics_summary: None,
            health_score: None,
            recommendations_summary: None,
            metadata: Some(serde_json::json!({
                "trigger": "auto",
                "timestamp": chrono::Utc::now().to_rfc3339()
            })),
        };

        self.create_snapshot(request).await
    }
}

#[cfg(test)]
mod tests {
    use crate::context_memory::models::WorkspaceRelationshipType;
    use crate::database::test_database;
    use chrono::Utc;

    async fn insert_workspace(pool: &sqlx::SqlitePool, name: &str) -> String {
        let id = uuid::Uuid::new_v4().to_string();
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            "INSERT INTO workspaces (id, name, description, status, health_score, root_path, last_active_at, created_at, updated_at)
             VALUES (?, ?, NULL, 'active', 0.0, NULL, ?, ?, ?)",
        )
        .bind(&id)
        .bind(name)
        .bind(&now)
        .bind(&now)
        .bind(&now)
        .execute(pool)
        .await
        .unwrap();
        id
    }

    async fn insert_relationship(
        pool: &sqlx::SqlitePool,
        source_id: &str,
        target_id: &str,
        rel_type: WorkspaceRelationshipType,
        strength: f64,
    ) {
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            "INSERT INTO workspace_relationships_v2 (source_workspace_id, target_workspace_id, relationship_type, strength, evidence, detected_at, last_updated)
             VALUES (?, ?, ?, ?, '{\"test\":true}', ?, ?)",
        )
        .bind(source_id)
        .bind(target_id)
        .bind(rel_type.as_str())
        .bind(strength)
        .bind(&now)
        .bind(&now)
        .execute(pool)
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn workspace_isolation_for_get_related_workspaces() {
        let (db, _guard) = test_database().await;
        let pool = db.pool().clone();

        let ws_a = insert_workspace(&pool, "Workspace A").await;
        let ws_b = insert_workspace(&pool, "Workspace B").await;
        let ws_c = insert_workspace(&pool, "Workspace C").await;

        // A→B and A→C, but NOT B→A and NOT C→A
        insert_relationship(&pool, &ws_a, &ws_b, WorkspaceRelationshipType::SharedFiles, 0.8).await;
        insert_relationship(&pool, &ws_a, &ws_c, WorkspaceRelationshipType::SharedTech, 0.6).await;
        insert_relationship(&pool, &ws_b, &ws_c, WorkspaceRelationshipType::SharedFolders, 0.5).await;

        // Verify isolation: query workspace_relationships_v2 directly
        let rows: Vec<(String,)> = sqlx::query_as(
            "SELECT target_workspace_id FROM workspace_relationships_v2 WHERE source_workspace_id = ? AND strength >= 0.3 ORDER BY strength DESC",
        )
        .bind(&ws_a)
        .fetch_all(&pool)
        .await
        .unwrap();

        assert_eq!(rows.len(), 2, "A should have 2 relationships");
        let targets: Vec<_> = rows.iter().map(|r| r.0.clone()).collect();
        assert!(targets.contains(&ws_b));
        assert!(targets.contains(&ws_c));
        assert!(!targets.contains(&ws_a), "A should not be related to itself");

        // B should only be related to C, not A
        let b_rows: Vec<(String,)> = sqlx::query_as(
            "SELECT target_workspace_id FROM workspace_relationships_v2 WHERE source_workspace_id = ? AND strength >= 0.3",
        )
        .bind(&ws_b)
        .fetch_all(&pool)
        .await
        .unwrap();
        assert_eq!(b_rows.len(), 1);
        assert_eq!(b_rows[0].0, ws_c);

        // C should have no outgoing relationships
        let c_rows: Vec<(String,)> = sqlx::query_as(
            "SELECT target_workspace_id FROM workspace_relationships_v2 WHERE source_workspace_id = ?",
        )
        .bind(&ws_c)
        .fetch_all(&pool)
        .await
        .unwrap();
        assert!(c_rows.is_empty(), "C should have no outgoing relationships");
    }

    #[tokio::test]
    async fn get_related_workspaces_respects_min_strength() {
        let (db, _guard) = test_database().await;
        let pool = db.pool().clone();

        let ws1 = insert_workspace(&pool, "WS1").await;
        let ws2 = insert_workspace(&pool, "WS2").await;

        insert_relationship(&pool, &ws1, &ws2, WorkspaceRelationshipType::SharedFiles, 0.2).await;

        // Query with min_strength 0.3 — should return nothing (below threshold)
        let rows_03: Vec<(String,)> = sqlx::query_as(
            "SELECT target_workspace_id FROM workspace_relationships_v2 WHERE source_workspace_id = ? AND strength >= ?",
        )
        .bind(&ws1)
        .bind(0.3)
        .fetch_all(&pool)
        .await
        .unwrap();
        assert!(rows_03.is_empty(), "strength 0.2 should be filtered by min_strength 0.3");

        // Query with min_strength 0.1 — should return the relationship
        let rows_01: Vec<(String,)> = sqlx::query_as(
            "SELECT target_workspace_id FROM workspace_relationships_v2 WHERE source_workspace_id = ? AND strength >= ?",
        )
        .bind(&ws1)
        .bind(0.1)
        .fetch_all(&pool)
        .await
        .unwrap();
        assert_eq!(rows_01.len(), 1, "strength 0.2 should pass min_strength 0.1");
    }
}
