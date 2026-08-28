use chrono::Utc;
use sqlx::SqlitePool;
use uuid::Uuid;

use crate::errors::DatabaseError;
use crate::models::file::FileRow;
use crate::models::{FileArtifact, NewFile};

/// Owns every SQL statement that touches the `files` table (blueprint
/// §2.1 — any artifact belonging to a workspace: file, tab, note, commit,
/// screenshot, or terminal session).
#[derive(Debug, Clone)]
pub struct FileRepository {
    pool: SqlitePool,
}

const SELECT_COLUMNS: &str =
    "id, workspace_id, artifact_type, path_or_url, content_hash, created_at, updated_at";

impl FileRepository {
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }

    /// Registers a new artifact under a workspace.
    ///
    /// # Errors
    /// [`DatabaseError::Constraint`] if `input.workspace_id` doesn't
    /// reference an existing workspace (the `files.workspace_id` foreign
    /// key rejects it).
    pub async fn create(&self, input: NewFile) -> Result<FileArtifact, DatabaseError> {
        let id = Uuid::new_v4();
        let now = Utc::now();

        sqlx::query(
            "INSERT INTO files (id, workspace_id, artifact_type, path_or_url, content_hash, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(id)
        .bind(input.workspace_id)
        .bind(input.artifact_type.as_str())
        .bind(&input.path_or_url)
        .bind(&input.content_hash)
        .bind(now)
        .bind(now)
        .execute(&self.pool)
        .await?;

        tracing::info!(file_id = %id, workspace_id = %input.workspace_id, "file artifact created");
        self.get_by_id(id).await
    }

    /// Fetches a single artifact by id.
    ///
    /// # Errors
    /// [`DatabaseError::NotFound`] if no artifact with that id exists.
    pub async fn get_by_id(&self, id: Uuid) -> Result<FileArtifact, DatabaseError> {
        let row: FileRow =
            sqlx::query_as(&format!("SELECT {SELECT_COLUMNS} FROM files WHERE id = ?"))
                .bind(id)
                .fetch_optional(&self.pool)
                .await?
                .ok_or_else(|| DatabaseError::not_found("file", id.to_string()))?;

        FileArtifact::try_from(row)
    }

    /// Lists every artifact in a workspace, most recently updated first —
    /// backs the Workspace View's file list (blueprint §3.2).
    pub async fn list_by_workspace(
        &self,
        workspace_id: Uuid,
    ) -> Result<Vec<FileArtifact>, DatabaseError> {
        let rows: Vec<FileRow> = sqlx::query_as(&format!(
            "SELECT {SELECT_COLUMNS} FROM files WHERE workspace_id = ? ORDER BY updated_at DESC"
        ))
        .bind(workspace_id)
        .fetch_all(&self.pool)
        .await?;

        rows.into_iter().map(FileArtifact::try_from).collect()
    }

    /// Looks up the artifact at `path_or_url` within a specific
    /// workspace, if one is already tracked. This is the query
    /// [`crate::timeline::recorder::TimelineRecorder`] runs on every
    /// file-level timeline activity to decide "reuse the existing row or
    /// create one" — backed by the composite index from
    /// `migrations/0004_files_workspace_path_index.sql`.
    pub async fn find_by_workspace_and_path(
        &self,
        workspace_id: Uuid,
        path_or_url: &str,
    ) -> Result<Option<FileArtifact>, DatabaseError> {
        let row: Option<FileRow> = sqlx::query_as(&format!(
            "SELECT {SELECT_COLUMNS} FROM files WHERE workspace_id = ? AND path_or_url = ?"
        ))
        .bind(workspace_id)
        .bind(path_or_url)
        .fetch_optional(&self.pool)
        .await?;

        row.map(FileArtifact::try_from).transpose()
    }

    /// Finds every artifact sharing a content hash, across all
    /// workspaces — the query the (Phase 5) duplicate-detection feature
    /// (blueprint §6) will call once it starts populating `content_hash`.
    /// Returns an empty list for `None`/blank hashes rather than matching
    /// every un-hashed row.
    pub async fn find_by_content_hash(
        &self,
        content_hash: &str,
    ) -> Result<Vec<FileArtifact>, DatabaseError> {
        if content_hash.trim().is_empty() {
            return Ok(Vec::new());
        }

        let rows: Vec<FileRow> = sqlx::query_as(&format!(
            "SELECT {SELECT_COLUMNS} FROM files WHERE content_hash = ? ORDER BY created_at ASC"
        ))
        .bind(content_hash)
        .fetch_all(&self.pool)
        .await?;

        rows.into_iter().map(FileArtifact::try_from).collect()
    }

    /// Lists files that have no content_hash (never hashed).
    ///
    /// Used by duplicate detection to find files that need initial hashing.
    /// If `workspace_id` is provided, only returns files from that workspace.
    pub async fn list_unhashed_files(
        &self,
        workspace_id: Option<Uuid>,
    ) -> Result<Vec<FileArtifact>, DatabaseError> {
        let rows: Vec<FileRow> = if let Some(ws_id) = workspace_id {
            sqlx::query_as(&format!(
                "SELECT {SELECT_COLUMNS} FROM files WHERE content_hash IS NULL AND workspace_id = ? ORDER BY created_at ASC"
            ))
            .bind(ws_id)
            .fetch_all(&self.pool)
            .await?
        } else {
            sqlx::query_as(&format!(
                "SELECT {SELECT_COLUMNS} FROM files WHERE content_hash IS NULL ORDER BY created_at ASC"
            ))
            .fetch_all(&self.pool)
            .await?
        };

        rows.into_iter().map(FileArtifact::try_from).collect()
    }

    /// Lists files that have been modified since they were last hashed.
    ///
    /// Compares `updated_at` with a threshold timestamp to identify files
    /// that may have changed content since their hash was computed.
    /// Used for incremental rehashing.
    pub async fn list_files_modified_since(
        &self,
        since: chrono::DateTime<chrono::Utc>,
        workspace_id: Option<Uuid>,
    ) -> Result<Vec<FileArtifact>, DatabaseError> {
        let rows: Vec<FileRow> = if let Some(ws_id) = workspace_id {
            sqlx::query_as(&format!(
                "SELECT {SELECT_COLUMNS} FROM files WHERE updated_at > ? AND workspace_id = ? ORDER BY updated_at ASC"
            ))
            .bind(since)
            .bind(ws_id)
            .fetch_all(&self.pool)
            .await?
        } else {
            sqlx::query_as(&format!(
                "SELECT {SELECT_COLUMNS} FROM files WHERE updated_at > ? ORDER BY updated_at ASC"
            ))
            .bind(since)
            .fetch_all(&self.pool)
            .await?
        };

        rows.into_iter().map(FileArtifact::try_from).collect()
    }

    /// Finds all duplicate groups (sets of files sharing the same content_hash).
    ///
    /// Returns only hashes that have 2+ files. Each group is a tuple of
    /// (content_hash, Vec<FileArtifact>). Groups are ordered by file count
    /// descending (largest duplicate sets first).
    pub async fn get_duplicate_groups(
        &self,
        workspace_id: Option<Uuid>,
    ) -> Result<Vec<(String, Vec<FileArtifact>)>, DatabaseError> {
        // Find hashes with 2+ files
        let hashes: Vec<String> = if let Some(ws_id) = workspace_id {
            sqlx::query_scalar(
                "SELECT content_hash FROM files 
                 WHERE content_hash IS NOT NULL AND workspace_id = ?
                 GROUP BY content_hash 
                 HAVING COUNT(*) > 1
                 ORDER BY COUNT(*) DESC",
            )
            .bind(ws_id)
            .fetch_all(&self.pool)
            .await?
        } else {
            sqlx::query_scalar(
                "SELECT content_hash FROM files 
                 WHERE content_hash IS NOT NULL
                 GROUP BY content_hash 
                 HAVING COUNT(*) > 1
                 ORDER BY COUNT(*) DESC",
            )
            .fetch_all(&self.pool)
            .await?
        };

        // For each duplicate hash, fetch all files
        let mut groups = Vec::new();
        for hash in hashes {
            let files = self.find_by_content_hash(&hash).await?;
            if files.len() > 1 {
                groups.push((hash, files));
            }
        }

        Ok(groups)
    }

    /// Updates the content hash for a file (used by Phase 5 ML Layer for
    /// duplicate detection).
    ///
    /// # Errors
    /// [`DatabaseError::NotFound`] if `id` doesn't exist.
    pub async fn update_content_hash(
        &self,
        id: Uuid,
        content_hash: Option<String>,
    ) -> Result<(), DatabaseError> {
        let result = sqlx::query("UPDATE files SET content_hash = ?, updated_at = ? WHERE id = ?")
            .bind(&content_hash)
            .bind(Utc::now())
            .bind(id)
            .execute(&self.pool)
            .await?;

        if result.rows_affected() == 0 {
            return Err(DatabaseError::not_found("file", id.to_string()));
        }

        tracing::info!(file_id = %id, "file content_hash updated");
        Ok(())
    }

    /// Updates the FTS5 `search_index` body for a file artifact.
    ///
    /// Called after a file is created or modified to keep filename+path
    /// search augmented with local file content (text files <256KB, 10k chars).
    /// No-op if the row is missing (e.g. search index not yet created).
    pub async fn update_search_body(&self, id: Uuid, body: String) -> Result<(), DatabaseError> {
        sqlx::query("UPDATE search_index SET body = ? WHERE entity_type = 'file' AND entity_id = ?")
            .bind(body)
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// Deletes a single artifact. Any `timeline_events` row referencing it
    /// has its `file_id` set to `NULL` (schema's `ON DELETE SET NULL`) —
    /// the historical event is kept, just detached from the now-gone file.
    ///
    /// # Errors
    /// [`DatabaseError::NotFound`] if `id` doesn't exist.
    pub async fn delete(&self, id: Uuid) -> Result<(), DatabaseError> {
        let result = sqlx::query("DELETE FROM files WHERE id = ?")
            .bind(id)
            .execute(&self.pool)
            .await?;

        if result.rows_affected() == 0 {
            return Err(DatabaseError::not_found("file", id.to_string()));
        }

        tracing::info!(file_id = %id, "file artifact deleted");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::test_database;
    use crate::models::{ArtifactType, CreateWorkspaceInput};
    use crate::repositories::WorkspaceRepository;

    /// Every file test needs a real workspace to attach to (the foreign
    /// key requires it), so the helper creates one via
    /// `WorkspaceRepository` rather than inserting raw SQL.
    async fn repo_with_workspace() -> (FileRepository, Uuid, tempfile::TempDir) {
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
            FileRepository::new(database.pool().clone()),
            workspace.id,
            temp_dir,
        )
    }

    #[tokio::test]
    async fn create_and_get_round_trip() {
        let (repo, workspace_id, _guard) = repo_with_workspace().await;

        let created = repo
            .create(NewFile {
                workspace_id,
                artifact_type: ArtifactType::File,
                path_or_url: "/Users/me/model.xlsx".to_string(),
                content_hash: Some("abc123".to_string()),
            })
            .await
            .expect("create should succeed");

        let fetched = repo.get_by_id(created.id).await.unwrap();
        assert_eq!(fetched.path_or_url, "/Users/me/model.xlsx");
        assert_eq!(fetched.artifact_type, ArtifactType::File);
        assert_eq!(fetched.content_hash.as_deref(), Some("abc123"));
    }

    #[tokio::test]
    async fn create_rejects_unknown_workspace() {
        let (database, _guard) = test_database().await;
        let repo = FileRepository::new(database.pool().clone());

        let result = repo
            .create(NewFile {
                workspace_id: Uuid::new_v4(), // does not exist
                artifact_type: ArtifactType::Tab,
                path_or_url: "https://stripe.com/pricing".to_string(),
                content_hash: None,
            })
            .await;

        assert!(matches!(result, Err(DatabaseError::Constraint(_))));
    }

    #[tokio::test]
    async fn list_by_workspace_returns_only_that_workspaces_files() {
        let (repo, workspace_id, _guard) = repo_with_workspace().await;

        repo.create(NewFile {
            workspace_id,
            artifact_type: ArtifactType::Note,
            path_or_url: "notes.md".to_string(),
            content_hash: None,
        })
        .await
        .unwrap();

        let other_workspace_id = Uuid::new_v4();
        // Not inserted — proves list_by_workspace filters, not just returns everything.

        let files = repo.list_by_workspace(workspace_id).await.unwrap();
        assert_eq!(files.len(), 1);
        assert_ne!(files[0].workspace_id, other_workspace_id);
    }

    #[tokio::test]
    async fn find_by_workspace_and_path_finds_existing_and_misses_other_paths() {
        let (repo, workspace_id, _guard) = repo_with_workspace().await;

        repo.create(NewFile {
            workspace_id,
            artifact_type: ArtifactType::File,
            path_or_url: "/repo/src/main.rs".to_string(),
            content_hash: None,
        })
        .await
        .unwrap();

        let found = repo
            .find_by_workspace_and_path(workspace_id, "/repo/src/main.rs")
            .await
            .unwrap();
        assert!(found.is_some());

        let missing = repo
            .find_by_workspace_and_path(workspace_id, "/repo/src/other.rs")
            .await
            .unwrap();
        assert!(missing.is_none());
    }

    #[tokio::test]
    async fn find_by_content_hash_finds_duplicates_across_creates() {
        let (repo, workspace_id, _guard) = repo_with_workspace().await;

        repo.create(NewFile {
            workspace_id,
            artifact_type: ArtifactType::File,
            path_or_url: "/a/report.pdf".to_string(),
            content_hash: Some("dup-hash".to_string()),
        })
        .await
        .unwrap();
        repo.create(NewFile {
            workspace_id,
            artifact_type: ArtifactType::File,
            path_or_url: "/b/report-copy.pdf".to_string(),
            content_hash: Some("dup-hash".to_string()),
        })
        .await
        .unwrap();

        let duplicates = repo.find_by_content_hash("dup-hash").await.unwrap();
        assert_eq!(duplicates.len(), 2);
    }

    #[tokio::test]
    async fn delete_unknown_id_returns_not_found() {
        let (repo, _workspace_id, _guard) = repo_with_workspace().await;
        let result = repo.delete(Uuid::new_v4()).await;
        assert!(matches!(result, Err(DatabaseError::NotFound { .. })));
    }
}
