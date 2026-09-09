use chrono::Utc;
use sqlx::SqlitePool;
use uuid::Uuid;

use crate::errors::DatabaseError;
use crate::models::search::{
    SavedSearch, SearchEntityType, SearchResult, SearchResultRow, SearchStats,
};

/// Repository for full-text search and search-related metadata.
#[derive(Debug, Clone)]
pub struct SearchRepository {
    pool: SqlitePool,
}

impl SearchRepository {
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }

    /// Performs a full-text search against the `search_index` virtual table.
    ///
    /// Uses BM25 ranking and `snippet()` for match highlighting.
    ///
    /// The query is sanitized for FTS5 by stripping `"` characters (which
    /// would break the outer phrase wrapping) and then wrapping the result
    /// in `"..."*` for safe phrase prefix matching. FTS5 syntax errors
    /// (e.g. from remaining special characters) are caught and returned as
    /// `DatabaseError::InvalidInput` with a user-friendly message.
    pub async fn search(
        &self,
        query: &str,
        entity_types: &[SearchEntityType],
        workspace_id: Option<Uuid>,
        limit: i64,
    ) -> Result<Vec<SearchResult>, DatabaseError> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Ok(Vec::new());
        }

        // Strip double quotes — they break FTS5 phrase syntax when
        // wrapping the input in outer quotes for the MATCH clause.
        let sanitized: String = trimmed.chars().filter(|&c| c != '"').collect();
        let sanitized = sanitized.trim();
        if sanitized.is_empty() {
            return Ok(Vec::new());
        }

        let fts_query = format!("\"{}\"*", sanitized);

        let mut sql = "
            SELECT 
                entity_type, 
                entity_id, 
                workspace_id, 
                title, 
                snippet(search_index, 3, '<b>', '</b>', '...', 10) as snippet,
                bm25(search_index) as rank
            FROM search_index
            WHERE search_index MATCH ?
        "
        .to_string();

        if !entity_types.is_empty() {
            let placeholders: Vec<&str> = entity_types.iter().map(|_| "?").collect();
            sql.push_str(&format!(" AND entity_type IN ({})", placeholders.join(",")));
        }

        if workspace_id.is_some() {
            sql.push_str(" AND workspace_id = ?");
        }

        sql.push_str(" ORDER BY rank LIMIT ?");

        let mut query = sqlx::query_as::<_, SearchResultRow>(&sql);
        query = query.bind(&fts_query);

        for t in entity_types {
            query = query.bind(t.as_str());
        }
        if let Some(ws_id) = workspace_id {
            query = query.bind(ws_id);
        }
        query = query.bind(limit);
        let rows: Vec<SearchResultRow> = match query.fetch_all(&self.pool).await {
            Ok(rows) => rows,
            Err(err) => {
                tracing::debug!(error = %err, query = %fts_query, "FTS5 query failed");
                return Err(DatabaseError::InvalidInput(format!(
                    "search query contains unsupported characters: '{}'",
                    trimmed.chars().take(80).collect::<String>()
                )));
            }
        };

        let result_count = rows.len();
        tracing::debug!(
            query = %trimmed,
            result_count,
            entity_type_count = entity_types.len(),
            has_workspace_filter = workspace_id.is_some(),
            "search performed"
        );

        rows.into_iter().map(SearchResult::try_from).collect()
    }

    /// Fetches the most recent search queries for auto-complete.
    pub async fn get_search_history(&self, limit: i64) -> Result<Vec<String>, DatabaseError> {
        let rows: Vec<(String,)> = sqlx::query_as(
            "SELECT query FROM search_history ORDER BY last_searched_at DESC LIMIT ?",
        )
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;

        Ok(rows.into_iter().map(|r| r.0).collect())
    }

    /// Records a search query in history, updating the timestamp if it already exists.
    pub async fn save_search_query(&self, query: &str) -> Result<(), DatabaseError> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Ok(());
        }

        sqlx::query(
            "INSERT INTO search_history (query, last_searched_at) 
             VALUES (?, ?)
             ON CONFLICT(query) DO UPDATE SET last_searched_at = excluded.last_searched_at",
        )
        .bind(trimmed)
        .bind(Utc::now())
        .execute(&self.pool)
        .await?;

        Ok(())
    }

    /// Clears the entire search history.
    pub async fn delete_search_history(&self) -> Result<(), DatabaseError> {
        sqlx::query("DELETE FROM search_history")
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// Persists a search query to the `saved_searches` table.
    pub async fn save_search(&self, query: &str) -> Result<SavedSearch, DatabaseError> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Err(DatabaseError::InvalidInput(
                "query must not be empty".to_string(),
            ));
        }

        let id = Uuid::new_v4();
        let now = Utc::now();

        sqlx::query("INSERT INTO saved_searches (id, query, created_at) VALUES (?, ?, ?)")
            .bind(id)
            .bind(trimmed)
            .bind(now)
            .execute(&self.pool)
            .await?;

        Ok(SavedSearch {
            id,
            query: trimmed.to_string(),
            created_at: now,
        })
    }

    /// Lists all saved searches.
    pub async fn list_saved_searches(&self) -> Result<Vec<SavedSearch>, DatabaseError> {
        let rows: Vec<SavedSearch> = sqlx::query_as(
            "SELECT id, query, created_at FROM saved_searches ORDER BY created_at DESC",
        )
        .fetch_all(&self.pool)
        .await?;

        Ok(rows)
    }

    /// Deletes a saved search by ID.
    pub async fn delete_saved_search(&self, id: Uuid) -> Result<(), DatabaseError> {
        let result = sqlx::query("DELETE FROM saved_searches WHERE id = ?")
            .bind(id)
            .execute(&self.pool)
            .await?;

        if result.rows_affected() == 0 {
            return Err(DatabaseError::not_found("saved_search", id.to_string()));
        }

        Ok(())
    }

    /// Returns the most recently updated files in a workspace, mapped to SearchResult.
    pub async fn get_recent_files(
        &self,
        workspace_id: Uuid,
        limit: i64,
    ) -> Result<Vec<SearchResult>, DatabaseError> {
        // `search_index` is alphabetical, not chronological — ordering by
        // `files.updated_at` is the source of truth for recency.
        let rows: Vec<SearchResultRow> = sqlx::query_as(
            "SELECT
                'file' as entity_type,
                id as entity_id,
                workspace_id,
                path_or_url as title,
                '' as snippet,
                0.0 as rank
             FROM files
             WHERE workspace_id = ?
             ORDER BY updated_at DESC
             LIMIT ?",
        )
        .bind(workspace_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;

        rows.into_iter().map(SearchResult::try_from).collect()
    }

    /// Aggregates search-related statistics for a workspace.
    pub async fn get_workspace_stats(
        &self,
        workspace_id: Uuid,
    ) -> Result<SearchStats, DatabaseError> {
        let total_files: (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM files WHERE workspace_id = ?")
                .bind(workspace_id)
                .fetch_one(&self.pool)
                .await?;

        let total_workspaces: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM workspaces")
            .fetch_one(&self.pool)
            .await?;

        // last_indexed isn't explicitly tracked in a dedicated table yet,
        // but we can infer it from the latest updated_at of any file in that workspace.
        let last_indexed: (Option<chrono::DateTime<Utc>>,) =
            sqlx::query_as("SELECT MAX(updated_at) FROM files WHERE workspace_id = ?")
                .bind(workspace_id)
                .fetch_one(&self.pool)
                .await?;

        Ok(SearchStats {
            total_files: total_files.0,
            total_workspaces: total_workspaces.0,
            last_indexed: last_indexed.0,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::test_database;
    use crate::models::CreateWorkspaceInput;
    use crate::repositories::WorkspaceRepository;

    async fn setup() -> (
        SearchRepository,
        WorkspaceRepository,
        SqlitePool,
        tempfile::TempDir,
    ) {
        let (database, temp_dir) = test_database().await;
        let pool = database.pool().clone();
        (
            SearchRepository::new(pool.clone()),
            WorkspaceRepository::new(pool.clone()),
            pool,
            temp_dir,
        )
    }

    #[tokio::test]
    async fn search_finds_indexed_workspace() {
        let (repo, ws_repo, _pool, _guard) = setup().await;

        ws_repo
            .create(CreateWorkspaceInput {
                name: "Research Project Alpha".to_string(),
                description: Some("Deep dive into Rust performance".to_string()),
                root_path: None,
            })
            .await
            .unwrap();

        // FTS might need a tiny bit of time or a commit, but SQLite is usually instant.
        let results = repo.search("Research", &[], None, 10).await.unwrap();
        assert!(!results.is_empty());
        assert_eq!(results[0].title, "Research Project Alpha");
    }

    #[tokio::test]
    async fn history_persistence() {
        let (repo, _, _, _guard) = setup().await;

        repo.save_search_query("rust language").await.unwrap();
        repo.save_search_query("tauri framework").await.unwrap();

        let history = repo.get_search_history(10).await.unwrap();
        assert_eq!(history.len(), 2);
        assert_eq!(history[0], "tauri framework");

        repo.delete_search_history().await.unwrap();
        let history = repo.get_search_history(10).await.unwrap();
        assert!(history.is_empty());
    }

    #[tokio::test]
    async fn saved_searches() {
        let (repo, _, _, _guard) = setup().await;

        let saved = repo.save_search("rust performance").await.unwrap();
        let list = repo.list_saved_searches().await.unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].query, "rust performance");

        repo.delete_saved_search(saved.id).await.unwrap();
        let list = repo.list_saved_searches().await.unwrap();
        assert!(list.is_empty());
    }
}
