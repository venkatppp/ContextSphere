use chrono::Utc;
use sqlx::SqlitePool;
use uuid::Uuid;

use crate::errors::DatabaseError;
use crate::models::workspace::{WorkspaceRow, WorkspaceStats};
use crate::models::{CreateWorkspaceInput, UpdateWorkspaceInput, Workspace, WorkspaceStatus};

/// Owns every SQL statement that touches the `workspaces` table.
///
/// No other module runs a query against `workspaces` directly — the
/// [`crate::services::workspace_service::WorkspaceService`] and, from
/// there, `commands::workspace` are the only callers, keeping this the
/// single place that knows the table's column list and constraints.
#[derive(Debug, Clone)]
pub struct WorkspaceRepository {
    pool: SqlitePool,
}

/// Columns selected by every read query in this repository, kept as one
/// constant so `create`/`update`'s writes and every `SELECT` can't
/// silently drift out of sync with each other.
const SELECT_COLUMNS: &str =
    "id, name, description, status, health_score, root_path, last_active_at, created_at, updated_at";

impl WorkspaceRepository {
    /// Builds a repository against an already-initialized connection
    /// pool. Cheap to call repeatedly — cloning the underlying
    /// `SqlitePool` is `Arc`-cheap, not a new connection.
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }

    /// Inserts a new workspace with `status = active` and
    /// `health_score = 0.0`, and both timestamp columns set to now.
    ///
    /// # Errors
    /// - [`DatabaseError::InvalidInput`] if `input.name` is empty (or
    ///   whitespace-only) after trimming.
    /// - [`DatabaseError::Constraint`] if `input.root_path` is `Some` and
    ///   already claimed by another workspace (the partial unique index
    ///   from `migrations/0002_workspace_root_path.sql`). Callers that
    ///   might race — e.g. the Workspace Engine's detector — should check
    ///   [`WorkspaceRepository::find_by_root_path`] first, but this is
    ///   still enforced at the database level as the source of truth.
    fn canonicalize_path(path: String) -> String {
        std::fs::canonicalize(&path)
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or(path)
    }

    pub async fn create(&self, input: CreateWorkspaceInput) -> Result<Workspace, DatabaseError> {
        let name = input.name.trim();
        if name.is_empty() {
            return Err(DatabaseError::InvalidInput(
                "workspace name must not be empty".to_string(),
            ));
        }
        let description = input.description.filter(|d| !d.trim().is_empty());
        let root_path = input
            .root_path
            .filter(|p| !p.trim().is_empty())
            .map(Self::canonicalize_path);

        let id = Uuid::new_v4();
        let now = Utc::now();

        sqlx::query(
            "INSERT INTO workspaces
                (id, name, description, status, health_score, root_path, last_active_at, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(id)
        .bind(name)
        .bind(&description)
        .bind(WorkspaceStatus::Active.as_str())
        .bind(0.0_f64)
        .bind(&root_path)
        .bind(now)
        .bind(now)
        .bind(now)
        .execute(&self.pool)
        .await?;

        tracing::info!(workspace_id = %id, name, root_path = ?root_path, "workspace created");
        self.get_by_id(id).await
    }

    /// Fetches a single workspace by id.
    ///
    /// # Errors
    /// [`DatabaseError::NotFound`] if no workspace with that id exists.
    pub async fn get_by_id(&self, id: Uuid) -> Result<Workspace, DatabaseError> {
        let row: WorkspaceRow = sqlx::query_as(&format!(
            "SELECT {SELECT_COLUMNS} FROM workspaces WHERE id = ?"
        ))
        .bind(id)
        .fetch_optional(&self.pool)
        .await?
        .ok_or_else(|| DatabaseError::not_found("workspace", id.to_string()))?;

        Workspace::try_from(row)
    }

    /// Applies a partial update (PATCH semantics — see
    /// [`UpdateWorkspaceInput`]) and returns the resulting workspace.
    ///
    /// Reads the current row first rather than building a dynamic
    /// `SET` clause: with at most four updatable columns the extra
    /// round-trip is negligible, and a fixed, fully-specified `UPDATE`
    /// statement is far easier to reason about (and to keep in sync with
    /// `SELECT_COLUMNS`) than assembling SQL at runtime.
    ///
    /// # Errors
    /// - [`DatabaseError::NotFound`] if `id` doesn't exist.
    /// - [`DatabaseError::InvalidInput`] if `name` would become empty, or
    ///   `health_score` is outside `0.0..=100.0`.
    pub async fn update(
        &self,
        id: Uuid,
        input: UpdateWorkspaceInput,
    ) -> Result<Workspace, DatabaseError> {
        let current = self.get_by_id(id).await?;

        let name = match input.name {
            Some(n) => {
                let trimmed = n.trim().to_string();
                if trimmed.is_empty() {
                    return Err(DatabaseError::InvalidInput(
                        "workspace name must not be empty".to_string(),
                    ));
                }
                trimmed
            }
            None => current.name,
        };

        // An explicit empty string clears the description to NULL — see
        // the doc comment on `UpdateWorkspaceInput::description`.
        let description = match input.description {
            Some(d) if d.trim().is_empty() => None,
            Some(d) => Some(d),
            None => current.description,
        };

        let status = input.status.unwrap_or(current.status);

        let health_score = match input.health_score {
            Some(score) if !(0.0..=100.0).contains(&score) => {
                return Err(DatabaseError::InvalidInput(format!(
                    "health_score must be between 0 and 100, got {score}"
                )));
            }
            Some(score) => score,
            None => current.health_score,
        };

        let now = Utc::now();

        sqlx::query(
            "UPDATE workspaces
             SET name = ?, description = ?, status = ?, health_score = ?, updated_at = ?
             WHERE id = ?",
        )
        .bind(&name)
        .bind(&description)
        .bind(status.as_str())
        .bind(health_score)
        .bind(now)
        .bind(id)
        .execute(&self.pool)
        .await?;

        tracing::info!(workspace_id = %id, "workspace updated");
        self.get_by_id(id).await
    }

    /// Deletes a workspace. Every `files`, `timeline_events`,
    /// `workspace_tags`, `workspace_relationships`, and `recent_activity`
    /// row referencing it is removed automatically by the schema's
    /// `ON DELETE CASCADE` foreign keys — no manual cleanup needed here.
    ///
    /// # Errors
    /// [`DatabaseError::NotFound`] if `id` doesn't exist.
    pub async fn delete(&self, id: Uuid) -> Result<(), DatabaseError> {
        let result = sqlx::query("DELETE FROM workspaces WHERE id = ?")
            .bind(id)
            .execute(&self.pool)
            .await?;

        if result.rows_affected() == 0 {
            return Err(DatabaseError::not_found("workspace", id.to_string()));
        }

        tracing::info!(workspace_id = %id, "workspace deleted");
        Ok(())
    }

    /// Sets `last_active_at` (and `updated_at`) to now, without touching
    /// any other column.
    ///
    /// Kept separate from [`WorkspaceRepository::update`] deliberately:
    /// "the user just opened this workspace" and "the user edited this
    /// workspace's name/description/status" are different signals with
    /// different callers (the former fires on every open, the latter only
    /// from an explicit edit action), and conflating them would make
    /// `updated_at` churn on every open instead of only on real edits.
    ///
    /// # Errors
    /// [`DatabaseError::NotFound`] if `id` doesn't exist.
    pub async fn touch_last_active(&self, id: Uuid) -> Result<Workspace, DatabaseError> {
        let now = Utc::now();

        let result =
            sqlx::query("UPDATE workspaces SET last_active_at = ?, updated_at = ? WHERE id = ?")
                .bind(now)
                .bind(now)
                .bind(id)
                .execute(&self.pool)
                .await?;

        if result.rows_affected() == 0 {
            return Err(DatabaseError::not_found("workspace", id.to_string()));
        }

        self.get_by_id(id).await
    }

    /// Looks up the workspace whose `root_path` exactly matches `path`,
    /// if any. This is the query [`crate::workspace::manager::WorkspaceManager`]
    /// runs before creating a workspace for a newly detected directory —
    /// an indexed point lookup against the partial unique index from
    /// `migrations/0002_workspace_root_path.sql`, not a scan.
    ///
    /// The lookup canonicalizes `path` (e.g. `/tmp` → `/private/tmp` on
    /// macOS) so callers passing either spelling match the same row.
    pub async fn find_by_root_path(&self, path: &str) -> Result<Option<Workspace>, DatabaseError> {
        let canonical = Self::canonicalize_path(path.to_string());
        let row: Option<WorkspaceRow> = sqlx::query_as(&format!(
            "SELECT {SELECT_COLUMNS} FROM workspaces WHERE root_path = ?"
        ))
        .bind(&canonical)
        .fetch_optional(&self.pool)
        .await?;
        // Fallback to original spelling for legacy rows created before
        // canonicalization was enforced (e.g. manual `/tmp` workspaces).
        if row.is_none() && canonical != path {
            let row2: Option<WorkspaceRow> = sqlx::query_as(&format!(
                "SELECT {SELECT_COLUMNS} FROM workspaces WHERE root_path = ?"
            ))
            .bind(path)
            .fetch_optional(&self.pool)
            .await?;
            return row2.map(Workspace::try_from).transpose();
        }

        row.map(Workspace::try_from).transpose()
    }

    /// Looks up the most recently active manually-created workspace —
    /// one with no filesystem root bound (`root_path IS NULL`) — whose
    /// name exactly matches `name`, if any. The workspace manager uses
    /// this to adopt an existing filesystem-less workspace as a watched
    /// folder's workspace instead of creating a duplicate-named one.
    pub async fn find_unbound_by_name(
        &self,
        name: &str,
    ) -> Result<Option<Workspace>, DatabaseError> {
        let row: Option<WorkspaceRow> = sqlx::query_as(&format!(
            "SELECT {SELECT_COLUMNS} FROM workspaces
             WHERE root_path IS NULL AND name = ?
             ORDER BY last_active_at DESC LIMIT 1"
        ))
        .bind(name)
        .fetch_optional(&self.pool)
        .await?;

        row.map(Workspace::try_from).transpose()
    }

    /// Binds a filesystem root to an existing workspace — the adoption
    /// step that turns a manually-created, filesystem-less workspace into
    /// a watched folder's workspace. Uniqueness of `root_path` across
    /// workspaces is enforced by the partial unique index from
    /// `migrations/0002_workspace_root_path.sql`.
    ///
    /// # Errors
    /// - [`DatabaseError::NotFound`] if `id` doesn't exist.
    /// - [`DatabaseError::Constraint`] if `root_path` is already claimed
    ///   by another workspace.
    pub async fn set_root_path(&self, id: Uuid, root_path: &str) -> Result<Workspace, DatabaseError> {
        let canonical = Self::canonicalize_path(root_path.to_string());
        let result = sqlx::query("UPDATE workspaces SET root_path = ?, updated_at = ? WHERE id = ?")
            .bind(&canonical)
            .bind(Utc::now())
            .bind(id)
            .execute(&self.pool)
            .await?;

        if result.rows_affected() == 0 {
            return Err(DatabaseError::not_found("workspace", id.to_string()));
        }

        tracing::info!(workspace_id = %id, root_path, "workspace root path bound");
        self.get_by_id(id).await
    }

    /// Returns the single most recently active `status = active`
    /// workspace, if any — the workspace a "resume where you left off"
    /// action on app launch would restore.
    pub async fn get_active_workspace(&self) -> Result<Option<Workspace>, DatabaseError> {
        let row: Option<WorkspaceRow> = sqlx::query_as(&format!(
            "SELECT {SELECT_COLUMNS} FROM workspaces
             WHERE status = ? ORDER BY last_active_at DESC LIMIT 1"
        ))
        .bind(WorkspaceStatus::Active.as_str())
        .fetch_optional(&self.pool)
        .await?;

        row.map(Workspace::try_from).transpose()
    }

    /// Lists every `status = active` workspace, most-recently-active
    /// first — backs the dashboard's "Active workspaces" grid.
    pub async fn list_active_workspaces(&self) -> Result<Vec<Workspace>, DatabaseError> {
        self.list_workspaces_by_status(WorkspaceStatus::Active)
            .await
    }

    /// Lists every `status = archived` workspace, most-recently-active
    /// first — backs the "Archived" filter tab on the Workspaces screen.
    pub async fn list_archived_workspaces(&self) -> Result<Vec<Workspace>, DatabaseError> {
        self.list_workspaces_by_status(WorkspaceStatus::Archived)
            .await
    }

    /// Internal helper: lists workspaces with a given status,
    /// most-recently-active first.
    async fn list_workspaces_by_status(
        &self,
        status: WorkspaceStatus,
    ) -> Result<Vec<Workspace>, DatabaseError> {
        let rows: Vec<WorkspaceRow> = sqlx::query_as(&format!(
            "SELECT {SELECT_COLUMNS} FROM workspaces
             WHERE status = ? ORDER BY last_active_at DESC"
        ))
        .bind(status.as_str())
        .fetch_all(&self.pool)
        .await?;

        rows.into_iter().map(Workspace::try_from).collect()
    }

    /// Aggregated statistics for a single workspace — file count, timeline
    /// event count, recency, and health score — in one round-trip.
    ///
    /// Uses correlated subqueries against indexed columns
    /// (`idx_files_workspace_id`, `idx_timeline_events_workspace_occurred`),
    /// so each count is a fast index scan even as the tables grow.
    ///
    /// # Errors
    /// [`DatabaseError::NotFound`] if no workspace with that id exists.
    pub async fn get_workspace_stats(
        &self,
        workspace_id: Uuid,
    ) -> Result<WorkspaceStats, DatabaseError> {
        let row: WorkspaceStatsRow = sqlx::query_as(
            "SELECT
                w.id,
                (SELECT COUNT(*) FROM files WHERE workspace_id = w.id) as file_count,
                (SELECT COUNT(*) FROM timeline_events WHERE workspace_id = w.id) as timeline_event_count,
                w.last_active_at,
                w.health_score
             FROM workspaces w
             WHERE w.id = ?",
        )
        .bind(workspace_id)
        .fetch_optional(&self.pool)
        .await?
        .ok_or_else(|| DatabaseError::not_found("workspace", workspace_id.to_string()))?;

        Ok(WorkspaceStats {
            workspace_id: row.id,
            file_count: row.file_count,
            timeline_event_count: row.timeline_event_count,
            last_activity: row.last_active_at,
            health_score: row.health_score,
        })
    }

    /// Case-insensitive substring search over `name` and `description`,
    /// most-recently-active first. Returns an empty list (not an error)
    /// for a blank query — callers don't need to special-case "no query
    /// typed yet".
    pub async fn search_workspaces(&self, query: &str) -> Result<Vec<Workspace>, DatabaseError> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Ok(Vec::new());
        }

        let pattern = format!("%{}%", escape_like(trimmed));

        let rows: Vec<WorkspaceRow> = sqlx::query_as(&format!(
            "SELECT {SELECT_COLUMNS} FROM workspaces
             WHERE name LIKE ? ESCAPE '\\' OR description LIKE ? ESCAPE '\\'
             ORDER BY last_active_at DESC"
        ))
        .bind(&pattern)
        .bind(&pattern)
        .fetch_all(&self.pool)
        .await?;

        rows.into_iter().map(Workspace::try_from).collect()
    }
}

/// Raw shape of the `get_workspace_stats` query result. Kept private to
/// this module — `WorkspaceStats` is what callers see.
#[derive(Debug, sqlx::FromRow)]
struct WorkspaceStatsRow {
    id: Uuid,
    file_count: i64,
    timeline_event_count: i64,
    last_active_at: chrono::DateTime<chrono::Utc>,
    health_score: f64,
}

/// Escapes `\`, `%`, and `_` so user-typed search text can't inject
/// unintended `LIKE` wildcards (e.g. searching for a literal underscore
/// in a workspace name shouldn't match every single-character gap).
fn escape_like(input: &str) -> String {
    input
        .replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::test_database;

    async fn repo() -> (WorkspaceRepository, SqlitePool, tempfile::TempDir) {
        let (database, temp_dir) = test_database().await;
        (
            WorkspaceRepository::new(database.pool().clone()),
            database.pool().clone(),
            temp_dir,
        )
    }

    #[tokio::test]
    async fn create_sets_defaults_and_is_retrievable() {
        let (repo, _pool, _guard) = repo().await;

        let workspace = repo
            .create(CreateWorkspaceInput {
                name: "Pricing Model Q3".to_string(),
                description: Some("Q3 pricing tiers".to_string()),
                root_path: None,
            })
            .await
            .expect("create should succeed");

        assert_eq!(workspace.name, "Pricing Model Q3");
        assert_eq!(workspace.status, WorkspaceStatus::Active);
        assert_eq!(workspace.health_score, 0.0);

        let fetched = repo
            .get_by_id(workspace.id)
            .await
            .expect("workspace should be retrievable immediately after creation");
        assert_eq!(fetched.id, workspace.id);
    }

    #[tokio::test]
    async fn create_rejects_empty_name() {
        let (repo, _pool, _guard) = repo().await;

        let result = repo
            .create(CreateWorkspaceInput {
                name: "   ".to_string(),
                description: None,
                root_path: None,
            })
            .await;

        assert!(matches!(result, Err(DatabaseError::InvalidInput(_))));
    }

    #[tokio::test]
    async fn get_by_id_returns_not_found_for_unknown_id() {
        let (repo, _pool, _guard) = repo().await;

        let result = repo.get_by_id(Uuid::new_v4()).await;

        assert!(matches!(result, Err(DatabaseError::NotFound { .. })));
    }

    #[tokio::test]
    async fn update_applies_partial_patch_and_clears_description() {
        let (repo, _pool, _guard) = repo().await;

        let workspace = repo
            .create(CreateWorkspaceInput {
                name: "Thesis Draft".to_string(),
                description: Some("Chapter 1".to_string()),
                root_path: None,
            })
            .await
            .expect("create should succeed");

        // Only touch `status`; `name` and `description` must survive untouched.
        let updated = repo
            .update(
                workspace.id,
                UpdateWorkspaceInput {
                    status: Some(WorkspaceStatus::Archived),
                    ..Default::default()
                },
            )
            .await
            .expect("update should succeed");

        assert_eq!(updated.name, "Thesis Draft");
        assert_eq!(updated.description.as_deref(), Some("Chapter 1"));
        assert_eq!(updated.status, WorkspaceStatus::Archived);

        // Empty-string description means "clear to NULL".
        let cleared = repo
            .update(
                workspace.id,
                UpdateWorkspaceInput {
                    description: Some(String::new()),
                    ..Default::default()
                },
            )
            .await
            .expect("update should succeed");
        assert_eq!(cleared.description, None);
    }

    #[tokio::test]
    async fn update_rejects_out_of_range_health_score() {
        let (repo, _pool, _guard) = repo().await;
        let workspace = repo
            .create(CreateWorkspaceInput {
                name: "Test".to_string(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();

        let result = repo
            .update(
                workspace.id,
                UpdateWorkspaceInput {
                    health_score: Some(150.0),
                    ..Default::default()
                },
            )
            .await;

        assert!(matches!(result, Err(DatabaseError::InvalidInput(_))));
    }

    #[tokio::test]
    async fn delete_removes_workspace_and_cascades_to_files() {
        let (repo, pool, _guard) = repo().await;
        let workspace = repo
            .create(CreateWorkspaceInput {
                name: "ContextSphere Dev".to_string(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();

        // Insert a dependent `files` row directly to prove the foreign
        // key's ON DELETE CASCADE fires, without needing FileRepository.
        sqlx::query(
            "INSERT INTO files (id, workspace_id, artifact_type, path_or_url, created_at, updated_at)
             VALUES (?, ?, 'file', '/tmp/example.txt', ?, ?)",
        )
        .bind(Uuid::new_v4())
        .bind(workspace.id)
        .bind(Utc::now())
        .bind(Utc::now())
        .execute(&pool)
        .await
        .unwrap();

        repo.delete(workspace.id)
            .await
            .expect("delete should succeed");

        let remaining_files: (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM files WHERE workspace_id = ?")
                .bind(workspace.id)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(
            remaining_files.0, 0,
            "cascade delete should remove dependent files"
        );

        let result = repo.get_by_id(workspace.id).await;
        assert!(matches!(result, Err(DatabaseError::NotFound { .. })));
    }

    #[tokio::test]
    async fn delete_unknown_id_returns_not_found() {
        let (repo, _pool, _guard) = repo().await;
        let result = repo.delete(Uuid::new_v4()).await;
        assert!(matches!(result, Err(DatabaseError::NotFound { .. })));
    }

    #[tokio::test]
    async fn touch_last_active_updates_only_the_timestamp() {
        let (repo, _pool, _guard) = repo().await;
        let workspace = repo
            .create(CreateWorkspaceInput {
                name: "ContextSphere Dev".to_string(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();

        // Force a measurable gap so the "before" and "after" timestamps
        // can't land in the same instant.
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;

        let touched = repo.touch_last_active(workspace.id).await.unwrap();

        assert!(touched.last_active_at > workspace.last_active_at);
        assert_eq!(touched.name, workspace.name);
        assert_eq!(touched.status, workspace.status);
    }

    #[tokio::test]
    async fn touch_last_active_unknown_id_returns_not_found() {
        let (repo, _pool, _guard) = repo().await;
        let result = repo.touch_last_active(Uuid::new_v4()).await;
        assert!(matches!(result, Err(DatabaseError::NotFound { .. })));
    }

    #[tokio::test]
    async fn list_active_workspaces_excludes_archived() {
        let (repo, _pool, _guard) = repo().await;

        let active = repo
            .create(CreateWorkspaceInput {
                name: "Active One".to_string(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();
        let to_archive = repo
            .create(CreateWorkspaceInput {
                name: "Will Be Archived".to_string(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();
        repo.update(
            to_archive.id,
            UpdateWorkspaceInput {
                status: Some(WorkspaceStatus::Archived),
                ..Default::default()
            },
        )
        .await
        .unwrap();

        let listed = repo.list_active_workspaces().await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, active.id);
    }

    #[tokio::test]
    async fn search_workspaces_matches_name_case_insensitively() {
        let (repo, _pool, _guard) = repo().await;
        repo.create(CreateWorkspaceInput {
            name: "Pricing Model Q3".to_string(),
            description: None,
            root_path: None,
        })
        .await
        .unwrap();
        repo.create(CreateWorkspaceInput {
            name: "Thesis Draft".to_string(),
            description: None,
            root_path: None,
        })
        .await
        .unwrap();

        let results = repo.search_workspaces("pricing").await.unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].name, "Pricing Model Q3");
    }

    #[tokio::test]
    async fn search_workspaces_blank_query_returns_empty() {
        let (repo, _pool, _guard) = repo().await;
        repo.create(CreateWorkspaceInput {
            name: "Anything".to_string(),
            description: None,
            root_path: None,
        })
        .await
        .unwrap();

        let results = repo.search_workspaces("   ").await.unwrap();
        assert!(results.is_empty());
    }
}
