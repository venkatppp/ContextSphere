//! Knowledge Graph repository (RC-8 M1).
//!
//! Owns every SQL statement behind the RC-8 knowledge graph: the
//! `graph_nodes` / `graph_relationships` CRUD, the source extraction
//! queries that feed the automatic construction pass, and the statistics
//! rollups. Traversal/ranking logic lives in `services::KgService` —
//! this module only moves rows in and out of SQLite.
//!
//! All construction writes are idempotent upserts keyed on the natural
//! graph keys, so `sync` is safe to run repeatedly.

use chrono::Utc;
use sqlx::SqlitePool;
use uuid::Uuid;

use crate::errors::DatabaseError;
use crate::models::kg::{
    GraphNodeType, GraphRelationshipType, GraphSource, KgEdge, KgEdgeRow, KgNode, KgNodeRow,
    KgStats, TypeCount,
};
use crate::models::kg_live::StructuralLink;

/// Repository for the RC-8 knowledge graph (`graph_nodes` +
/// `graph_relationships`).
#[derive(Debug, Clone)]
pub struct KgRepository {
    pool: SqlitePool,
}

/// Canonical 32-char lowercase hex for a uuid column that may be stored
/// as BLOB(16) (`Uuid` binds: workspaces, files, graph tables) or dashed
/// TEXT (`to_string()` binds: execution_memory, plan_executions,
/// plan_execution_reports, copilot_*). `Uuid::parse_str` accepts the
/// simple form, so reads go String -> parse.
fn canon(col: &str) -> String {
    format!(
        "CASE typeof({col}) WHEN 'blob' THEN lower(hex({col})) ELSE replace(lower({col}), '-', '') END"
    )
}

fn parse_canon_uuid(raw: String) -> Result<Uuid, DatabaseError> {
    Uuid::parse_str(&raw)
        .map_err(|e| DatabaseError::InvalidInput(format!("invalid uuid '{raw}': {e}")))
}

impl KgRepository {
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }

    // ------------------------------------------------------------------
    // Node CRUD
    // ------------------------------------------------------------------

    /// Upserts one graph node. Returns `true` when a row was created,
    /// `false` when an existing row was updated.
    pub async fn upsert_node(
        &self,
        node_type: GraphNodeType,
        source: &GraphSource,
    ) -> Result<bool, DatabaseError> {
        let now = Utc::now();
        let metadata = serde_json::to_string(&source.metadata).unwrap_or_else(|_| "{}".into());

        let row: KgNodeRow = sqlx::query_as(
            "INSERT INTO graph_nodes
                 (node_type, entity_id, title, workspace_id, summary, metadata, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(node_type, entity_id) DO UPDATE SET
                 title = excluded.title,
                 workspace_id = excluded.workspace_id,
                 summary = excluded.summary,
                 metadata = excluded.metadata,
                 updated_at = excluded.updated_at
             RETURNING *",
        )
        .bind(node_type.as_str())
        .bind(source.entity_id)
        .bind(&source.title)
        .bind(source.workspace_id)
        .bind(&source.summary)
        .bind(&metadata)
        .bind(now)
        .bind(now)
        .fetch_one(&self.pool)
        .await?;

        Ok(row.created_at == row.updated_at)
    }

    pub async fn get_node(
        &self,
        node_type: GraphNodeType,
        entity_id: Uuid,
    ) -> Result<Option<KgNode>, DatabaseError> {
        let row: Option<KgNodeRow> =
            sqlx::query_as("SELECT * FROM graph_nodes WHERE node_type = ? AND entity_id = ?")
                .bind(node_type.as_str())
                .bind(entity_id)
                .fetch_optional(&self.pool)
                .await?;

        row.map(KgNode::try_from).transpose()
    }

    /// Lists nodes, optionally scoped to a workspace and/or a set of
    /// node types, newest-first, capped at `limit` (default 500).
    pub async fn list_nodes(
        &self,
        workspace_id: Option<Uuid>,
        node_types: Option<&[GraphNodeType]>,
        limit: Option<u32>,
    ) -> Result<Vec<KgNode>, DatabaseError> {
        let mut sql = String::from("SELECT * FROM graph_nodes WHERE 1=1");
        if workspace_id.is_some() {
            sql.push_str(" AND workspace_id = ?");
        }
        if let Some(types) = node_types {
            if !types.is_empty() {
                let placeholders: Vec<&str> = types.iter().map(|_| "?").collect();
                sql.push_str(&format!(" AND node_type IN ({})", placeholders.join(",")));
            }
        }
        sql.push_str(" ORDER BY created_at DESC LIMIT ?");

        let mut query = sqlx::query_as::<_, KgNodeRow>(&sql);
        if let Some(ws_id) = workspace_id {
            query = query.bind(ws_id);
        }
        if let Some(types) = node_types {
            for t in types {
                query = query.bind(t.as_str());
            }
        }
        query = query.bind(limit.unwrap_or(500) as i64);

        let rows: Vec<KgNodeRow> = query.fetch_all(&self.pool).await?;
        rows.into_iter().map(KgNode::try_from).collect()
    }

    /// Case-insensitive substring search over node titles and summaries.
    pub async fn search_nodes(
        &self,
        query: &str,
        node_types: Option<&[GraphNodeType]>,
        limit: u32,
    ) -> Result<Vec<KgNode>, DatabaseError> {
        let mut sql =
            String::from("SELECT * FROM graph_nodes WHERE (title LIKE ? OR summary LIKE ?)");
        if let Some(types) = node_types {
            if !types.is_empty() {
                let placeholders: Vec<&str> = types.iter().map(|_| "?").collect();
                sql.push_str(&format!(" AND node_type IN ({})", placeholders.join(",")));
            }
        }
        sql.push_str(" ORDER BY updated_at DESC LIMIT ?");

        let pattern = format!("%{}%", query.replace('%', "\\%").replace('_', "\\_"));
        let mut q = sqlx::query_as::<_, KgNodeRow>(&sql)
            .bind(&pattern)
            .bind(&pattern);
        if let Some(types) = node_types {
            for t in types {
                q = q.bind(t.as_str());
            }
        }
        q = q.bind(limit as i64);

        let rows: Vec<KgNodeRow> = q.fetch_all(&self.pool).await?;
        rows.into_iter().map(KgNode::try_from).collect()
    }

    /// Removes a node; relationships cascade via FK. Returns whether a
    /// row was actually removed.
    pub async fn delete_node(
        &self,
        node_type: GraphNodeType,
        entity_id: Uuid,
    ) -> Result<bool, DatabaseError> {
        let result = sqlx::query("DELETE FROM graph_nodes WHERE node_type = ? AND entity_id = ?")
            .bind(node_type.as_str())
            .bind(entity_id)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected() > 0)
    }

    // ------------------------------------------------------------------
    // Relationship CRUD
    // ------------------------------------------------------------------

    /// Upserts one relationship. Returns `true` when created, `false`
    /// when an existing row was updated.
    #[allow(clippy::too_many_arguments)]
    pub async fn upsert_relationship(
        &self,
        source_type: GraphNodeType,
        source_id: Uuid,
        target_type: GraphNodeType,
        target_id: Uuid,
        relationship_type: GraphRelationshipType,
        weight: f64,
        metadata: serde_json::Value,
    ) -> Result<bool, DatabaseError> {
        let now = Utc::now();
        let meta = serde_json::to_string(&metadata).unwrap_or_else(|_| "{}".into());

        let row: KgEdgeRow = sqlx::query_as(
            "INSERT INTO graph_relationships
                 (id, source_node_type, source_entity_id, target_node_type, target_entity_id,
                  relationship_type, weight, metadata, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(source_node_type, source_entity_id, target_node_type, target_entity_id,
                         relationship_type)
             DO UPDATE SET weight = excluded.weight, metadata = excluded.metadata,
                           updated_at = excluded.updated_at
             RETURNING *",
        )
        .bind(Uuid::new_v4())
        .bind(source_type.as_str())
        .bind(source_id)
        .bind(target_type.as_str())
        .bind(target_id)
        .bind(relationship_type.as_str())
        .bind(weight)
        .bind(&meta)
        .bind(now)
        .bind(now)
        .fetch_one(&self.pool)
        .await?;

        Ok(row.created_at == row.updated_at)
    }

    /// All relationships touching a node (either direction).
    pub async fn get_edges_for_node(
        &self,
        node_type: GraphNodeType,
        entity_id: Uuid,
    ) -> Result<Vec<KgEdge>, DatabaseError> {
        let rows: Vec<KgEdgeRow> = sqlx::query_as(
            "SELECT * FROM graph_relationships
             WHERE (source_node_type = ? AND source_entity_id = ?)
                OR (target_node_type = ? AND target_entity_id = ?)",
        )
        .bind(node_type.as_str())
        .bind(entity_id)
        .bind(node_type.as_str())
        .bind(entity_id)
        .fetch_all(&self.pool)
        .await?;

        rows.into_iter().map(KgEdge::try_from).collect()
    }

    /// Direct neighbors of a node (nodes reachable over any relationship
    /// in either direction).
    pub async fn get_neighbors(
        &self,
        node_type: GraphNodeType,
        entity_id: Uuid,
        limit: u32,
    ) -> Result<Vec<KgNode>, DatabaseError> {
        let rows: Vec<KgNodeRow> = sqlx::query_as(
            "SELECT n.* FROM graph_relationships r
             JOIN graph_nodes n
               ON (n.node_type = r.target_node_type AND n.entity_id = r.target_entity_id)
             WHERE r.source_node_type = ? AND r.source_entity_id = ?
             UNION
             SELECT n.* FROM graph_relationships r
             JOIN graph_nodes n
               ON (n.node_type = r.source_node_type AND n.entity_id = r.source_entity_id)
             WHERE r.target_node_type = ? AND r.target_entity_id = ?
             ORDER BY created_at DESC
             LIMIT ?",
        )
        .bind(node_type.as_str())
        .bind(entity_id)
        .bind(node_type.as_str())
        .bind(entity_id)
        .bind(limit as i64)
        .fetch_all(&self.pool)
        .await?;

        rows.into_iter().map(KgNode::try_from).collect()
    }

    // ------------------------------------------------------------------
    // Source extraction (automatic construction)
    // ------------------------------------------------------------------

    /// Every workspace as a graph source. Metadata carries its status.
    pub async fn workspace_sources(&self) -> Result<Vec<GraphSource>, DatabaseError> {
        let rows: Vec<(Uuid, String, String, String)> =
            sqlx::query_as("SELECT id, name, status, COALESCE(description, '') FROM workspaces")
                .fetch_all(&self.pool)
                .await?;

        Ok(rows
            .into_iter()
            .map(|(id, name, status, description)| GraphSource {
                entity_id: id,
                title: name,
                workspace_id: Some(id),
                summary: Some(description).filter(|s| !s.is_empty()),
                metadata: serde_json::json!({ "status": status }),
            })
            .collect())
    }

    /// Every file as a graph source. Metadata carries its artifact type.
    pub async fn file_sources(&self) -> Result<Vec<GraphSource>, DatabaseError> {
        let rows: Vec<(Uuid, Uuid, String, String)> =
            sqlx::query_as("SELECT id, workspace_id, path_or_url, artifact_type FROM files")
                .fetch_all(&self.pool)
                .await?;

        Ok(rows
            .into_iter()
            .map(|(id, workspace_id, path, artifact_type)| GraphSource {
                entity_id: id,
                title: path
                    .rsplit('/')
                    .next()
                    .filter(|name| !name.is_empty())
                    .unwrap_or(&path)
                    .to_string(),
                workspace_id: Some(workspace_id),
                summary: Some(path),
                metadata: serde_json::json!({ "artifact_type": artifact_type }),
            })
            .collect())
    }

    /// Every planner report as a graph source. The report node is keyed
    /// on the execution id it summarizes (the table's primary key), and
    /// its summary is the report body, truncated.
    pub async fn planner_report_sources(&self) -> Result<Vec<GraphSource>, DatabaseError> {
        let rows: Vec<(String, String, String)> = sqlx::query_as(&format!(
            "SELECT {}, report, created_at FROM plan_execution_reports",
            canon("execution_id")
        ))
        .fetch_all(&self.pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|(raw_id, report, created_at)| {
                let execution_id = parse_canon_uuid(raw_id)?;
                let summary: String = report.chars().take(400).collect();
                Ok(GraphSource {
                    entity_id: execution_id,
                    title: format!("Planner Report {}", short(&execution_id)),
                    workspace_id: None,
                    summary: Some(summary).filter(|s| !s.is_empty()),
                    metadata: serde_json::json!({
                        "execution_id": execution_id.to_string(),
                        "created_at": created_at,
                    }),
                })
            })
            .collect::<Result<Vec<_>, DatabaseError>>()?)
    }

    /// Every plan execution as a graph source. The title is the plan
    /// goal (joined through `copilot_plans`), the workspace comes from
    /// the owning conversation.
    pub async fn execution_sources(&self) -> Result<Vec<GraphSource>, DatabaseError> {
        let id_key = canon("pe.id");
        let ws_key = canon("c.workspace_id");
        let rows: Vec<(String, Option<String>, String, String, String, String)> = sqlx::query_as(
            &format!(
                "SELECT {id_key}, {ws_key} AS workspace_id,
                    COALESCE(p.goal, 'Execution ' || substr({id_key}, 1, 8)),
                    pe.status, pe.started_at, pe.completed_at
             FROM plan_executions pe
             LEFT JOIN copilot_conversations c ON c.id = pe.conversation_id
             LEFT JOIN copilot_plans p ON p.id = pe.plan_id"
            ),
        )
        .fetch_all(&self.pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(
                |(raw_id, raw_workspace_id, title, status, started_at, completed_at)| {
                    Ok(GraphSource {
                        entity_id: parse_canon_uuid(raw_id)?,
                        title,
                        workspace_id: raw_workspace_id
                            .map(parse_canon_uuid)
                            .transpose()?,
                        summary: Some(format!("Status: {status}")),
                        metadata: serde_json::json!({
                            "status": status,
                            "started_at": started_at,
                            "completed_at": completed_at,
                        }),
                    })
                },
            )
            .collect::<Result<Vec<_>, DatabaseError>>()?)
    }

    /// Memory records as graph sources (execution + planner-report
    /// kinds; autonomous sessions have their own node type and are
    /// excluded here).
    pub async fn memory_record_sources(&self) -> Result<Vec<GraphSource>, DatabaseError> {
        let rows: Vec<(String, Option<String>, String, String, String)> = sqlx::query_as(
            &format!(
                "SELECT {} AS id_key, {} AS workspace_id, goal, kind, status
                 FROM execution_memory
                 WHERE kind != 'autonomous_session'",
                canon("id"),
                canon("workspace_id")
            ),
        )
        .fetch_all(&self.pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|(raw_id, raw_workspace_id, goal, kind, status)| {
                Ok(GraphSource {
                    entity_id: parse_canon_uuid(raw_id)?,
                    title: goal,
                    workspace_id: raw_workspace_id.map(parse_canon_uuid).transpose()?,
                    summary: Some(format!("{kind} · {status}")),
                    metadata: serde_json::json!({ "kind": kind, "status": status }),
                })
            })
            .collect::<Result<Vec<_>, DatabaseError>>()?)
    }

    /// Autonomous sessions as graph sources. The session node is keyed
    /// on the session id (the memory row's `source_id`).
    pub async fn autonomous_session_sources(&self) -> Result<Vec<GraphSource>, DatabaseError> {
        let rows: Vec<(String, Option<String>, String, String, String)> = sqlx::query_as(
            &format!(
                "SELECT {} AS source_key, {} AS workspace_id, goal, status, error
                 FROM execution_memory
                 WHERE kind = 'autonomous_session'",
                canon("source_id"),
                canon("workspace_id")
            ),
        )
        .fetch_all(&self.pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(
                |(raw_source_id, raw_workspace_id, goal, status, error)| {
                    Ok(GraphSource {
                        entity_id: parse_canon_uuid(raw_source_id)?,
                        title: format!("Session: {goal}"),
                        workspace_id: raw_workspace_id.map(parse_canon_uuid).transpose()?,
                        summary: Some(error)
                            .filter(|e| !e.is_empty())
                            .or_else(|| Some(format!("Status: {status}"))),
                        metadata: serde_json::json!({ "status": status }),
                    })
                },
            )
            .collect::<Result<Vec<_>, DatabaseError>>()?)
    }

    // ------------------------------------------------------------------
    // Structural links (edges built during construction)
    // ------------------------------------------------------------------

    /// `(file_id, workspace_id)` pairs for `contains` edges.
    pub async fn file_workspace_links(&self) -> Result<Vec<(Uuid, Uuid)>, DatabaseError> {
        let rows: Vec<(Uuid, Uuid)> = sqlx::query_as("SELECT id, workspace_id FROM files")
            .fetch_all(&self.pool)
            .await?;
        Ok(rows)
    }

    /// `(execution_id, workspace_id)` pairs for `runs_in` edges.
    pub async fn execution_workspace_links(&self) -> Result<Vec<(Uuid, Uuid)>, DatabaseError> {
        let rows: Vec<(String, String)> = sqlx::query_as(&format!(
            "SELECT {} AS id_key, {} AS ws_key
             FROM plan_executions pe
             JOIN copilot_conversations c ON c.id = pe.conversation_id
             WHERE c.workspace_id IS NOT NULL",
            canon("pe.id"),
            canon("c.workspace_id")
        ))
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter()
            .map(|(raw_id, raw_ws)| Ok((parse_canon_uuid(raw_id)?, parse_canon_uuid(raw_ws)?)))
            .collect()
    }

    /// Execution ids that have a planner report (`reports_on` edges —
    /// the report node and the execution node share the id).
    pub async fn planner_report_links(&self) -> Result<Vec<Uuid>, DatabaseError> {
        let rows: Vec<(String,)> = sqlx::query_as(&format!(
            "SELECT {} FROM plan_execution_reports",
            canon("execution_id")
        ))
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter()
            .map(|(id,)| parse_canon_uuid(id))
            .collect()
    }

    /// `(memory_id, execution_id)` pairs for `derived_from` edges
    /// (memory records learned from an engine execution).
    pub async fn memory_execution_links(&self) -> Result<Vec<(Uuid, Uuid)>, DatabaseError> {
        let rows: Vec<(String, String)> = sqlx::query_as(&format!(
            "SELECT {} AS id_key, {} AS source_key FROM execution_memory
             WHERE kind = 'execution' AND source_id IS NOT NULL",
            canon("id"),
            canon("source_id")
        ))
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter()
            .map(|(raw_id, raw_source_id)| {
                Ok((parse_canon_uuid(raw_id)?, parse_canon_uuid(raw_source_id)?))
            })
            .collect()
    }

    /// `(memory_id, workspace_id)` pairs for `runs_in` edges of memory
    /// records and autonomous sessions (both live in `execution_memory`).
    pub async fn memory_workspace_links(&self) -> Result<Vec<(Uuid, Uuid)>, DatabaseError> {
        let rows: Vec<(String, String)> = sqlx::query_as(&format!(
            "SELECT {} AS id_key, {} AS ws_key FROM execution_memory
             WHERE kind != 'autonomous_session' AND workspace_id IS NOT NULL",
            canon("id"),
            canon("workspace_id")
        ))
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter()
            .map(|(raw_id, raw_ws)| Ok((parse_canon_uuid(raw_id)?, parse_canon_uuid(raw_ws)?)))
            .collect()
    }

    /// `(session_id, workspace_id)` pairs for `runs_in` edges of
    /// autonomous sessions.
    pub async fn session_workspace_links(&self) -> Result<Vec<(Uuid, Uuid)>, DatabaseError> {
        let rows: Vec<(String, String)> = sqlx::query_as(&format!(
            "SELECT {} AS source_key, {} AS ws_key FROM execution_memory
             WHERE kind = 'autonomous_session' AND workspace_id IS NOT NULL",
            canon("source_id"),
            canon("workspace_id")
        ))
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter()
            .map(|(raw_id, raw_ws)| Ok((parse_canon_uuid(raw_id)?, parse_canon_uuid(raw_ws)?)))
            .collect()
    }

    // ------------------------------------------------------------------
    // Incremental sync primitives (RC-8 M2)
    // ------------------------------------------------------------------

    /// Single-source extraction: reuses the full aggregate scan and picks
    /// the matching row, so node-build logic (titles, summaries,
    /// metadata) exists in exactly one place.
    pub async fn source_for(
        &self,
        node_type: GraphNodeType,
        entity_id: Uuid,
    ) -> Result<Option<GraphSource>, DatabaseError> {
        let sources = match node_type {
            GraphNodeType::Workspace => self.workspace_sources().await?,
            GraphNodeType::File => self.file_sources().await?,
            GraphNodeType::PlannerReport => self.planner_report_sources().await?,
            GraphNodeType::Execution => self.execution_sources().await?,
            GraphNodeType::MemoryRecord => self.memory_record_sources().await?,
            GraphNodeType::AutonomousSession => self.autonomous_session_sources().await?,
        };
        Ok(sources.into_iter().find(|s| s.entity_id == entity_id))
    }

    /// Entity ids of one aggregate whose source row changed after
    /// `since` — the increment a watermark-based sync processes.
    pub async fn sources_changed(
        &self,
        node_type: GraphNodeType,
        since: chrono::DateTime<chrono::Utc>,
    ) -> Result<Vec<Uuid>, DatabaseError> {
        let since = since.to_rfc3339();
        // Every arm selects the canonical 32-hex form so both storage
        // contracts (BLOB ids and dashed-TEXT ids) decode identically.
        let rows: Vec<(String,)> = match node_type {
            GraphNodeType::Workspace => {
                sqlx::query_as(&format!(
                    "SELECT {} FROM workspaces WHERE updated_at > ?",
                    canon("id")
                ))
                .bind(&since)
                .fetch_all(&self.pool)
                .await?
            }
            GraphNodeType::File => {
                sqlx::query_as(&format!(
                    "SELECT {} FROM files WHERE updated_at > ?",
                    canon("id")
                ))
                .bind(&since)
                .fetch_all(&self.pool)
                .await?
            }
            GraphNodeType::PlannerReport => {
                sqlx::query_as(&format!(
                    "SELECT {} FROM plan_execution_reports WHERE created_at > ?",
                    canon("execution_id")
                ))
                .bind(&since)
                .fetch_all(&self.pool)
                .await?
            }
            GraphNodeType::Execution => {
                sqlx::query_as(&format!(
                    "SELECT {} FROM plan_executions WHERE updated_at > ?",
                    canon("id")
                ))
                .bind(&since)
                .fetch_all(&self.pool)
                .await?
            }
            GraphNodeType::MemoryRecord => {
                sqlx::query_as(&format!(
                    "SELECT {} FROM execution_memory
                     WHERE kind != 'autonomous_session' AND updated_at > ?",
                    canon("id")
                ))
                .bind(&since)
                .fetch_all(&self.pool)
                .await?
            }
            GraphNodeType::AutonomousSession => {
                sqlx::query_as(&format!(
                    "SELECT {} FROM execution_memory
                     WHERE kind = 'autonomous_session' AND updated_at > ?",
                    canon("source_id")
                ))
                .bind(&since)
                .fetch_all(&self.pool)
                .await?
            }
        };
        rows.into_iter()
            .map(|(id,)| parse_canon_uuid(id))
            .collect()
    }

    /// Structural links for one entity — the incremental analogue of the
    /// full-sync link queries: a workspace links to all of its files, a
    /// file links back to its workspace, executions/sessions/memories
    /// link to their workspace, memories additionally to the execution
    /// they were learned from, and planner reports to their execution.
    pub async fn links_for(
        &self,
        node_type: GraphNodeType,
        entity_id: Uuid,
    ) -> Result<Vec<StructuralLink>, DatabaseError> {
        let mut links = Vec::new();
        match node_type {
            GraphNodeType::Workspace => {
                let files: Vec<(Uuid,)> =
                    sqlx::query_as("SELECT id FROM files WHERE workspace_id = ?")
                        .bind(entity_id)
                        .fetch_all(&self.pool)
                        .await?;
                for (file_id,) in files {
                    links.push(StructuralLink {
                        source_type: GraphNodeType::Workspace,
                        source_id: entity_id,
                        target_type: GraphNodeType::File,
                        target_id: file_id,
                        relationship_type: GraphRelationshipType::Contains,
                    });
                }
            }
            GraphNodeType::File => {
                let workspace: Option<(Uuid,)> = sqlx::query_as(
                    "SELECT workspace_id FROM files WHERE id = ? AND workspace_id IS NOT NULL",
                )
                .bind(entity_id)
                .fetch_optional(&self.pool)
                .await?;
                if let Some((workspace_id,)) = workspace {
                    links.push(StructuralLink {
                        source_type: GraphNodeType::Workspace,
                        source_id: workspace_id,
                        target_type: GraphNodeType::File,
                        target_id: entity_id,
                        relationship_type: GraphRelationshipType::Contains,
                    });
                }
            }
            GraphNodeType::Execution => {
                let workspace: Option<(String,)> = sqlx::query_as(&format!(
                    "SELECT {} AS ws_key
                     FROM plan_executions pe
                     JOIN copilot_conversations c ON c.id = pe.conversation_id
                     WHERE {} = ? AND c.workspace_id IS NOT NULL",
                    canon("c.workspace_id"),
                    canon("pe.id")
                ))
                .bind(entity_id.simple().to_string())
                .fetch_optional(&self.pool)
                .await?;
                if let Some((raw_workspace_id,)) = workspace {
                    let workspace_id = parse_canon_uuid(raw_workspace_id)?;
                    links.push(StructuralLink {
                        source_type: GraphNodeType::Execution,
                        source_id: entity_id,
                        target_type: GraphNodeType::Workspace,
                        target_id: workspace_id,
                        relationship_type: GraphRelationshipType::RunsIn,
                    });
                }
            }
            GraphNodeType::PlannerReport => {
                let report: Option<(String,)> = sqlx::query_as(&format!(
                    "SELECT {} FROM plan_execution_reports WHERE {} = ?",
                    canon("execution_id"),
                    canon("execution_id")
                ))
                .bind(entity_id.simple().to_string())
                .fetch_optional(&self.pool)
                .await?;
                if report.is_some() {
                    links.push(StructuralLink {
                        source_type: GraphNodeType::PlannerReport,
                        source_id: entity_id,
                        target_type: GraphNodeType::Execution,
                        target_id: entity_id,
                        relationship_type: GraphRelationshipType::ReportsOn,
                    });
                }
            }
            GraphNodeType::MemoryRecord => {
                let workspace: Option<(String,)> = sqlx::query_as(&format!(
                    "SELECT {} AS ws_key FROM execution_memory
                     WHERE {} = ? AND kind != 'autonomous_session' AND workspace_id IS NOT NULL",
                    canon("workspace_id"),
                    canon("id")
                ))
                .bind(entity_id.simple().to_string())
                .fetch_optional(&self.pool)
                .await?;
                if let Some((raw_workspace_id,)) = workspace {
                    let workspace_id = parse_canon_uuid(raw_workspace_id)?;
                    links.push(StructuralLink {
                        source_type: GraphNodeType::MemoryRecord,
                        source_id: entity_id,
                        target_type: GraphNodeType::Workspace,
                        target_id: workspace_id,
                        relationship_type: GraphRelationshipType::RunsIn,
                    });
                }
                let execution: Option<(String,)> = sqlx::query_as(&format!(
                    "SELECT {} AS source_key FROM execution_memory
                     WHERE {} = ? AND kind = 'execution' AND source_id IS NOT NULL",
                    canon("source_id"),
                    canon("id")
                ))
                .bind(entity_id.simple().to_string())
                .fetch_optional(&self.pool)
                .await?;
                if let Some((raw_source_id,)) = execution {
                    let execution_id = parse_canon_uuid(raw_source_id)?;
                    links.push(StructuralLink {
                        source_type: GraphNodeType::MemoryRecord,
                        source_id: entity_id,
                        target_type: GraphNodeType::Execution,
                        target_id: execution_id,
                        relationship_type: GraphRelationshipType::DerivedFrom,
                    });
                }
            }
            GraphNodeType::AutonomousSession => {
                let workspace: Option<(String,)> = sqlx::query_as(&format!(
                    "SELECT {} AS ws_key FROM execution_memory
                     WHERE {} = ? AND kind = 'autonomous_session' AND workspace_id IS NOT NULL",
                    canon("workspace_id"),
                    canon("source_id")
                ))
                .bind(entity_id.simple().to_string())
                .fetch_optional(&self.pool)
                .await?;
                if let Some((raw_workspace_id,)) = workspace {
                    let workspace_id = parse_canon_uuid(raw_workspace_id)?;
                    links.push(StructuralLink {
                        source_type: GraphNodeType::AutonomousSession,
                        source_id: entity_id,
                        target_type: GraphNodeType::Workspace,
                        target_id: workspace_id,
                        relationship_type: GraphRelationshipType::RunsIn,
                    });
                }
            }
        }
        Ok(links)
    }

    /// Removes graph nodes whose source aggregate no longer has the row
    /// (workspace/file/execution/... deleted). Relationships cascade.
    pub async fn prune_missing_nodes(
        &self,
        node_type: GraphNodeType,
    ) -> Result<u64, DatabaseError> {
        let sql: String = match node_type {
            GraphNodeType::Workspace => format!(
                "DELETE FROM graph_nodes WHERE node_type = 'workspace'
                 AND lower(hex(entity_id)) NOT IN
                     (SELECT {} FROM workspaces)",
                canon("id")
            ),
            GraphNodeType::File => format!(
                "DELETE FROM graph_nodes WHERE node_type = 'file'
                 AND lower(hex(entity_id)) NOT IN
                     (SELECT {} FROM files)",
                canon("id")
            ),
            // Compare in the canonical 32-hex space so the KG's BLOB ids
            // line up with aggregates stored as dashed TEXT.
            GraphNodeType::PlannerReport => format!(
                "DELETE FROM graph_nodes WHERE node_type = 'planner_report'
                 AND lower(hex(entity_id)) NOT IN
                     (SELECT {} FROM plan_execution_reports)",
                canon("execution_id")
            ),
            GraphNodeType::Execution => format!(
                "DELETE FROM graph_nodes WHERE node_type = 'execution'
                 AND lower(hex(entity_id)) NOT IN
                     (SELECT {} FROM plan_executions)",
                canon("id")
            ),
            GraphNodeType::MemoryRecord => format!(
                "DELETE FROM graph_nodes WHERE node_type = 'memory_record'
                 AND lower(hex(entity_id)) NOT IN (
                     SELECT {} FROM execution_memory WHERE kind != 'autonomous_session')",
                canon("id")
            ),
            GraphNodeType::AutonomousSession => format!(
                "DELETE FROM graph_nodes WHERE node_type = 'autonomous_session'
                 AND lower(hex(entity_id)) NOT IN (
                     SELECT {} FROM execution_memory WHERE kind = 'autonomous_session')",
                canon("source_id")
            ),
        };
        let result = sqlx::query(&sql).execute(&self.pool).await?;
        Ok(result.rows_affected())
    }

    /// Reads the sync watermark for one aggregate (`None` on first run).
    pub async fn sync_state_get(
        &self,
        node_type: GraphNodeType,
    ) -> Result<Option<chrono::DateTime<chrono::Utc>>, DatabaseError> {
        let row: Option<(String,)> = sqlx::query_as(
            "SELECT last_synced_at FROM graph_sync_state WHERE source_aggregate = ?",
        )
        .bind(node_type.as_str())
        .fetch_optional(&self.pool)
        .await?;
        match row {
            Some((stamp,)) => {
                let parsed = chrono::DateTime::parse_from_rfc3339(&stamp)
                    .map_err(|e| DatabaseError::IoError(e.to_string()))?;
                Ok(Some(parsed.with_timezone(&chrono::Utc)))
            }
            None => Ok(None),
        }
    }

    /// Advances the sync watermark for one aggregate.
    pub async fn sync_state_set(
        &self,
        node_type: GraphNodeType,
        at: chrono::DateTime<chrono::Utc>,
    ) -> Result<(), DatabaseError> {
        sqlx::query(
            "INSERT INTO graph_sync_state (source_aggregate, last_synced_at)
             VALUES (?, ?)
             ON CONFLICT(source_aggregate) DO UPDATE SET last_synced_at = excluded.last_synced_at",
        )
        .bind(node_type.as_str())
        .bind(at.to_rfc3339())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    // ------------------------------------------------------------------
    // Statistics
    // ------------------------------------------------------------------

    pub async fn stats(&self) -> Result<KgStats, DatabaseError> {
        let (node_count,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM graph_nodes")
            .fetch_one(&self.pool)
            .await?;
        let (edge_count,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM graph_relationships")
            .fetch_one(&self.pool)
            .await?;

        let nodes_by_type: Vec<(String, i64)> =
            sqlx::query_as("SELECT node_type, COUNT(*) FROM graph_nodes GROUP BY node_type")
                .fetch_all(&self.pool)
                .await?;
        let edges_by_type: Vec<(String, i64)> = sqlx::query_as(
            "SELECT relationship_type, COUNT(*) FROM graph_relationships
             GROUP BY relationship_type",
        )
        .fetch_all(&self.pool)
        .await?;

        Ok(KgStats {
            node_count,
            edge_count,
            nodes_by_type: nodes_by_type
                .into_iter()
                .map(|(name, count)| TypeCount { name, count })
                .collect(),
            edges_by_type: edges_by_type
                .into_iter()
                .map(|(name, count)| TypeCount { name, count })
                .collect(),
        })
    }
}

fn short(id: &Uuid) -> String {
    id.to_string().chars().take(8).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::test_database;
    use crate::models::CreateWorkspaceInput;
    use crate::repositories::WorkspaceRepository;
    use serde_json::json;

    async fn setup() -> (
        KgRepository,
        WorkspaceRepository,
        sqlx::SqlitePool,
        tempfile::TempDir,
    ) {
        let (database, temp_dir) = test_database().await;
        let pool = database.pool().clone();
        (
            KgRepository::new(pool.clone()),
            WorkspaceRepository::new(pool.clone()),
            pool,
            temp_dir,
        )
    }

    fn source(id: Uuid, title: &str, workspace_id: Option<Uuid>) -> GraphSource {
        GraphSource {
            entity_id: id,
            title: title.into(),
            workspace_id,
            summary: Some("test summary".into()),
            metadata: json!({ "test": true }),
        }
    }

    #[tokio::test]
    async fn upsert_node_is_idempotent_and_reports_created_vs_updated() {
        let (repo, _ws_repo, _pool, _guard) = setup().await;
        let id = Uuid::new_v4();

        let created = repo
            .upsert_node(GraphNodeType::File, &source(id, "first title", None))
            .await
            .unwrap();
        assert!(created, "first insert creates the node");

        let updated = repo
            .upsert_node(GraphNodeType::File, &source(id, "second title", None))
            .await
            .unwrap();
        assert!(!updated, "second upsert updates, not creates");

        let node = repo
            .get_node(GraphNodeType::File, id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(node.title, "second title");
        assert!(node.created_at < node.updated_at);
    }

    #[tokio::test]
    async fn list_and_search_nodes_filter_by_type_and_workspace() {
        let (repo, ws_repo, _pool, _guard) = setup().await;
        let ws = ws_repo
            .create(CreateWorkspaceInput {
                name: "Graph Workspace".into(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();
        let other = Uuid::new_v4();

        repo.upsert_node(
            GraphNodeType::Workspace,
            &source(ws.id, "Graph Workspace", Some(ws.id)),
        )
        .await
        .unwrap();
        repo.upsert_node(GraphNodeType::File, &source(other, "alpha.rs", Some(ws.id)))
            .await
            .unwrap();
        repo.upsert_node(
            GraphNodeType::MemoryRecord,
            &source(other, "beta.goal", Some(ws.id)),
        )
        .await
        .unwrap();

        let files = repo
            .list_nodes(Some(ws.id), Some(&[GraphNodeType::File]), Some(10))
            .await
            .unwrap();
        assert_eq!(files.len(), 1);
        assert!(matches!(files[0].node_type, GraphNodeType::File));

        let hits = repo.search_nodes("alpha", None, 10).await.unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].title, "alpha.rs");

        let miss = repo.search_nodes("zeta", None, 10).await.unwrap();
        assert!(miss.is_empty());
    }

    #[tokio::test]
    async fn relationships_round_trip_with_direction_agnostic_neighbors() {
        let (repo, ws_repo, _pool, _guard) = setup().await;
        let ws = ws_repo
            .create(CreateWorkspaceInput {
                name: "WS".into(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();
        let file_id = Uuid::new_v4();
        let exec_id = Uuid::new_v4();

        repo.upsert_node(GraphNodeType::Workspace, &source(ws.id, "WS", Some(ws.id)))
            .await
            .unwrap();
        repo.upsert_node(GraphNodeType::File, &source(file_id, "a.rs", Some(ws.id)))
            .await
            .unwrap();
        repo.upsert_node(
            GraphNodeType::Execution,
            &source(exec_id, "goal", Some(ws.id)),
        )
        .await
        .unwrap();

        repo.upsert_relationship(
            GraphNodeType::Workspace,
            ws.id,
            GraphNodeType::File,
            file_id,
            GraphRelationshipType::Contains,
            1.0,
            json!({}),
        )
        .await
        .unwrap();
        repo.upsert_relationship(
            GraphNodeType::Execution,
            exec_id,
            GraphNodeType::Workspace,
            ws.id,
            GraphRelationshipType::RunsIn,
            1.0,
            json!({}),
        )
        .await
        .unwrap();

        let file_neighbors = repo
            .get_neighbors(GraphNodeType::File, file_id, 10)
            .await
            .unwrap();
        assert_eq!(file_neighbors.len(), 1);
        assert!(matches!(
            file_neighbors[0].node_type,
            GraphNodeType::Workspace
        ));

        let ws_neighbors = repo
            .get_neighbors(GraphNodeType::Workspace, ws.id, 10)
            .await
            .unwrap();
        assert_eq!(ws_neighbors.len(), 2, "both directions resolve");

        let edges = repo
            .get_edges_for_node(GraphNodeType::Workspace, ws.id)
            .await
            .unwrap();
        assert_eq!(edges.len(), 2);
    }

    #[tokio::test]
    async fn delete_node_cascades_relationships() {
        let (repo, ws_repo, _pool, _guard) = setup().await;
        let ws = ws_repo
            .create(CreateWorkspaceInput {
                name: "WS".into(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();
        let file_id = Uuid::new_v4();

        repo.upsert_node(GraphNodeType::Workspace, &source(ws.id, "WS", Some(ws.id)))
            .await
            .unwrap();
        repo.upsert_node(GraphNodeType::File, &source(file_id, "a.rs", Some(ws.id)))
            .await
            .unwrap();
        repo.upsert_relationship(
            GraphNodeType::Workspace,
            ws.id,
            GraphNodeType::File,
            file_id,
            GraphRelationshipType::Contains,
            1.0,
            json!({}),
        )
        .await
        .unwrap();

        assert!(repo
            .delete_node(GraphNodeType::File, file_id)
            .await
            .unwrap());
        let edges = repo
            .get_edges_for_node(GraphNodeType::Workspace, ws.id)
            .await
            .unwrap();
        assert!(edges.is_empty(), "relationship cascaded with the node");
    }

    #[tokio::test]
    async fn construction_sources_cover_all_six_aggregates() {
        let (repo, ws_repo, pool, _guard) = setup().await;
        let ws = ws_repo
            .create(CreateWorkspaceInput {
                name: "Source WS".into(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();

        // files
        sqlx::query(
            "INSERT INTO files (id, workspace_id, artifact_type, path_or_url, created_at, updated_at)
             VALUES (?, ?, 'file', ?, datetime('now'), datetime('now'))",
        )
        .bind(Uuid::new_v4())
        .bind(ws.id)
        .bind("/tmp/source.rs")
        .execute(&pool)
        .await
        .unwrap();

        // plan + conversation + execution
        sqlx::query(
            "INSERT INTO copilot_conversations (id, workspace_id, title, created_at, updated_at)
             VALUES (?, ?, 'conv', datetime('now'), datetime('now'))",
        )
        .bind(Uuid::new_v4())
        .bind(ws.id)
        .execute(&pool)
        .await
        .unwrap();

        // planner report (also creates an implicit execution node source? no — plan_execution_reports references plan_executions via FK; insert execution first)
        let exec_id = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO plan_executions
                 (id, plan_id, status, current_step, total_steps, created_at, updated_at)
             VALUES (?, ?, 'completed', 0, 2, datetime('now'), datetime('now'))",
        )
        .bind(exec_id)
        .bind(Uuid::new_v4())
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO plan_execution_reports (execution_id, report) VALUES (?, 'all good')",
        )
        .bind(exec_id)
        .execute(&pool)
        .await
        .unwrap();

        // memory record (kind=execution) + autonomous session (kind=autonomous_session)
        let memory_id = Uuid::new_v4();
        let session_id = Uuid::new_v4();
        let now = chrono::Utc::now().to_rfc3339();
        sqlx::query(
            "INSERT INTO execution_memory
                 (id, kind, source_id, workspace_id, goal, status, created_at, updated_at)
             VALUES (?, 'execution', ?, ?, 'learn goal', 'success', ?, ?)",
        )
        .bind(memory_id)
        .bind(exec_id)
        .bind(ws.id)
        .bind(&now)
        .bind(&now)
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO execution_memory
                 (id, kind, source_id, workspace_id, goal, status, created_at, updated_at)
             VALUES (?, 'autonomous_session', ?, ?, 'session goal', 'success', ?, ?)",
        )
        .bind(Uuid::new_v4())
        .bind(session_id)
        .bind(ws.id)
        .bind(&now)
        .bind(&now)
        .execute(&pool)
        .await
        .unwrap();

        assert_eq!(repo.workspace_sources().await.unwrap().len(), 1);
        assert_eq!(repo.file_sources().await.unwrap().len(), 1);
        assert_eq!(repo.planner_report_sources().await.unwrap().len(), 1);
        assert_eq!(repo.execution_sources().await.unwrap().len(), 1);
        assert_eq!(repo.memory_record_sources().await.unwrap().len(), 1);
        assert_eq!(repo.autonomous_session_sources().await.unwrap().len(), 1);

        assert_eq!(repo.planner_report_links().await.unwrap(), vec![exec_id]);
        assert_eq!(
            repo.memory_execution_links().await.unwrap(),
            vec![(memory_id, exec_id)]
        );
    }

    #[tokio::test]
    async fn stats_roll_up_counts_by_type() {
        let (repo, ws_repo, _pool, _guard) = setup().await;
        let ws = ws_repo
            .create(CreateWorkspaceInput {
                name: "WS".into(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();
        let file_id = Uuid::new_v4();

        repo.upsert_node(GraphNodeType::Workspace, &source(ws.id, "WS", Some(ws.id)))
            .await
            .unwrap();
        repo.upsert_node(GraphNodeType::File, &source(file_id, "a.rs", Some(ws.id)))
            .await
            .unwrap();
        repo.upsert_relationship(
            GraphNodeType::Workspace,
            ws.id,
            GraphNodeType::File,
            file_id,
            GraphRelationshipType::Contains,
            1.0,
            json!({}),
        )
        .await
        .unwrap();

        let stats = repo.stats().await.unwrap();
        assert_eq!(stats.node_count, 2);
        assert_eq!(stats.edge_count, 1);
        assert_eq!(stats.nodes_by_type.len(), 2);
        assert_eq!(stats.edges_by_type[0].name, "contains");
        assert_eq!(stats.edges_by_type[0].count, 1);
    }
}
