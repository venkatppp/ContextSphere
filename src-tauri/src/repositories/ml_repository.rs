use chrono::Utc;
use sqlx::SqlitePool;
use uuid::Uuid;

use crate::errors::DatabaseError;
use crate::models::ml::{EmbeddingRow, MLMetadataRow};
use crate::models::{Embedding, FileClassification, MLMetadata, NewEmbedding, NewMLMetadata};

/// Owns every SQL statement that touches the `ml_metadata` and `embeddings`
/// tables (Phase 5 ML Layer).
#[derive(Debug, Clone)]
pub struct MLRepository {
    pool: SqlitePool,
}

const ML_METADATA_COLUMNS: &str =
    "id, file_id, model_version, embedding_id, classification, confidence, created_at";

const EMBEDDINGS_COLUMNS: &str = "id, vector, dimensions, model_version, created_at";

impl MLRepository {
    /// Creates a new MLRepository with the given connection pool.
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }

    // --- ML Metadata operations ---

    /// Creates a new ML metadata record for a file.
    ///
    /// # Errors
    /// [`DatabaseError::Constraint`] if `input.file_id` doesn't reference an
    /// existing file, or if a record for this `(file_id, model_version)` pair
    /// already exists (unique constraint).
    pub async fn create_metadata(&self, input: NewMLMetadata) -> Result<MLMetadata, DatabaseError> {
        let id = Uuid::new_v4();
        let now = Utc::now();

        let classification_str = input.classification.map(|c| c.as_str().to_string());

        sqlx::query(
            "INSERT INTO ml_metadata (id, file_id, model_version, embedding_id, classification, confidence, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(id)
        .bind(input.file_id)
        .bind(&input.model_version)
        .bind(&input.embedding_id)
        .bind(&classification_str)
        .bind(input.confidence)
        .bind(now)
        .execute(&self.pool)
        .await?;

        tracing::info!(
            metadata_id = %id,
            file_id = %input.file_id,
            model_version = %input.model_version,
            "ML metadata created"
        );

        self.get_metadata_by_id(id).await
    }

    /// Fetches ML metadata by its id.
    ///
    /// # Errors
    /// [`DatabaseError::NotFound`] if no metadata with that id exists.
    pub async fn get_metadata_by_id(&self, id: Uuid) -> Result<MLMetadata, DatabaseError> {
        let row: MLMetadataRow = sqlx::query_as(&format!(
            "SELECT {ML_METADATA_COLUMNS} FROM ml_metadata WHERE id = ?"
        ))
        .bind(id)
        .fetch_optional(&self.pool)
        .await?
        .ok_or_else(|| DatabaseError::not_found("ml_metadata", id.to_string()))?;

        MLMetadata::try_from(row)
    }

    /// Fetches ML metadata by file_id and model_version.
    pub async fn get_metadata_by_file(
        &self,
        file_id: Uuid,
        model_version: &str,
    ) -> Result<Option<MLMetadata>, DatabaseError> {
        let row: Option<MLMetadataRow> = sqlx::query_as(&format!(
            "SELECT {ML_METADATA_COLUMNS} FROM ml_metadata WHERE file_id = ? AND model_version = ?"
        ))
        .bind(file_id)
        .bind(model_version)
        .fetch_optional(&self.pool)
        .await?;

        row.map(MLMetadata::try_from).transpose()
    }

    /// Updates the classification for an existing ML metadata record.
    pub async fn update_classification(
        &self,
        id: Uuid,
        classification: FileClassification,
        confidence: f32,
    ) -> Result<(), DatabaseError> {
        let result =
            sqlx::query("UPDATE ml_metadata SET classification = ?, confidence = ? WHERE id = ?")
                .bind(classification.as_str())
                .bind(confidence)
                .bind(id)
                .execute(&self.pool)
                .await?;

        if result.rows_affected() == 0 {
            return Err(DatabaseError::not_found("ml_metadata", id.to_string()));
        }

        tracing::info!(metadata_id = %id, classification = %classification, "ML metadata classification updated");
        Ok(())
    }

    /// Updates the embedding_id reference for an existing ML metadata record.
    pub async fn update_embedding_id(
        &self,
        id: Uuid,
        embedding_id: String,
    ) -> Result<(), DatabaseError> {
        let result = sqlx::query("UPDATE ml_metadata SET embedding_id = ? WHERE id = ?")
            .bind(&embedding_id)
            .bind(id)
            .execute(&self.pool)
            .await?;

        if result.rows_affected() == 0 {
            return Err(DatabaseError::not_found("ml_metadata", id.to_string()));
        }

        tracing::info!(metadata_id = %id, embedding_id = %embedding_id, "ML metadata embedding_id updated");
        Ok(())
    }

    /// Deletes ML metadata by id. The embedding it references (if any) is not
    /// automatically deleted — call `delete_embedding` separately if needed.
    pub async fn delete_metadata(&self, id: Uuid) -> Result<(), DatabaseError> {
        let result = sqlx::query("DELETE FROM ml_metadata WHERE id = ?")
            .bind(id)
            .execute(&self.pool)
            .await?;

        if result.rows_affected() == 0 {
            return Err(DatabaseError::not_found("ml_metadata", id.to_string()));
        }

        tracing::info!(metadata_id = %id, "ML metadata deleted");
        Ok(())
    }

    // --- Embedding operations ---

    /// Creates a new embedding record.
    pub async fn create_embedding(&self, input: NewEmbedding) -> Result<Embedding, DatabaseError> {
        let now = Utc::now();
        let dimensions = input.vector.len() as i32;

        // Serialize Vec<f32> to BLOB (little-endian bytes)
        let vector_bytes: Vec<u8> = input.vector.iter().flat_map(|f| f.to_le_bytes()).collect();

        sqlx::query(
            "INSERT INTO embeddings (id, vector, dimensions, model_version, created_at)
             VALUES (?, ?, ?, ?, ?)",
        )
        .bind(&input.id)
        .bind(&vector_bytes)
        .bind(dimensions)
        .bind(&input.model_version)
        .bind(now)
        .execute(&self.pool)
        .await?;

        tracing::info!(
            embedding_id = %input.id,
            dimensions = dimensions,
            model_version = %input.model_version,
            "Embedding created"
        );

        self.get_embedding_by_id(&input.id).await
    }

    /// Fetches an embedding by its id.
    ///
    /// # Errors
    /// [`DatabaseError::NotFound`] if no embedding with that id exists.
    pub async fn get_embedding_by_id(&self, id: &str) -> Result<Embedding, DatabaseError> {
        let row: EmbeddingRow = sqlx::query_as(&format!(
            "SELECT {EMBEDDINGS_COLUMNS} FROM embeddings WHERE id = ?"
        ))
        .bind(id)
        .fetch_optional(&self.pool)
        .await?
        .ok_or_else(|| DatabaseError::not_found("embedding", id.to_string()))?;

        Embedding::try_from(row)
    }

    /// Deletes an embedding by id.
    pub async fn delete_embedding(&self, id: &str) -> Result<(), DatabaseError> {
        let result = sqlx::query("DELETE FROM embeddings WHERE id = ?")
            .bind(id)
            .execute(&self.pool)
            .await?;

        if result.rows_affected() == 0 {
            return Err(DatabaseError::not_found("embedding", id.to_string()));
        }

        tracing::info!(embedding_id = %id, "Embedding deleted");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::test_database;
    use crate::models::{ArtifactType, CreateWorkspaceInput, NewFile};
    use crate::repositories::{FileRepository, WorkspaceRepository};

    /// Every ML metadata test needs a real file to attach to (the foreign
    /// key requires it), so the helper creates both a workspace and a file.
    async fn repo_with_file() -> (MLRepository, Uuid, Uuid, tempfile::TempDir) {
        let (database, temp_dir) = test_database().await;
        let pool = database.pool().clone();

        let workspace_repo = WorkspaceRepository::new(pool.clone());
        let workspace = workspace_repo
            .create(CreateWorkspaceInput {
                name: "Test Workspace".to_string(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();

        let file_repo = FileRepository::new(pool.clone());
        let file = file_repo
            .create(NewFile {
                workspace_id: workspace.id,
                artifact_type: ArtifactType::File,
                path_or_url: "/test/file.rs".to_string(),
                content_hash: None,
                file_identifier: None,
            })
            .await
            .unwrap();

        (MLRepository::new(pool), workspace.id, file.id, temp_dir)
    }

    #[tokio::test]
    async fn create_and_get_metadata_round_trip() {
        let (repo, _workspace_id, file_id, _guard) = repo_with_file().await;

        let created = repo
            .create_metadata(NewMLMetadata {
                file_id,
                model_version: "v1.0".to_string(),
                embedding_id: None,
                classification: Some(FileClassification::Code),
                confidence: Some(0.95),
            })
            .await
            .expect("create should succeed");

        let fetched = repo.get_metadata_by_id(created.id).await.unwrap();
        assert_eq!(fetched.file_id, file_id);
        assert_eq!(fetched.model_version, "v1.0");
        assert_eq!(fetched.classification, Some(FileClassification::Code));
        assert_eq!(fetched.confidence, Some(0.95));
    }

    #[tokio::test]
    async fn get_metadata_by_file_returns_none_for_missing() {
        let (repo, _workspace_id, file_id, _guard) = repo_with_file().await;

        let result = repo.get_metadata_by_file(file_id, "v1.0").await.unwrap();
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn update_classification_persists() {
        let (repo, _workspace_id, file_id, _guard) = repo_with_file().await;

        let created = repo
            .create_metadata(NewMLMetadata {
                file_id,
                model_version: "v1.0".to_string(),
                embedding_id: None,
                classification: Some(FileClassification::Unknown),
                confidence: Some(0.5),
            })
            .await
            .unwrap();

        repo.update_classification(created.id, FileClassification::Document, 0.92)
            .await
            .unwrap();

        let fetched = repo.get_metadata_by_id(created.id).await.unwrap();
        assert_eq!(fetched.classification, Some(FileClassification::Document));
        assert_eq!(fetched.confidence, Some(0.92));
    }

    #[tokio::test]
    async fn update_embedding_id_persists() {
        let (repo, _workspace_id, file_id, _guard) = repo_with_file().await;

        let created = repo
            .create_metadata(NewMLMetadata {
                file_id,
                model_version: "v1.0".to_string(),
                embedding_id: None,
                classification: None,
                confidence: None,
            })
            .await
            .unwrap();

        repo.update_embedding_id(created.id, "emb-12345".to_string())
            .await
            .unwrap();

        let fetched = repo.get_metadata_by_id(created.id).await.unwrap();
        assert_eq!(fetched.embedding_id, Some("emb-12345".to_string()));
    }

    #[tokio::test]
    async fn create_and_get_embedding_round_trip() {
        let (repo, _workspace_id, _file_id, _guard) = repo_with_file().await;

        let vector = vec![0.1, 0.2, 0.3, 0.4];
        let created = repo
            .create_embedding(NewEmbedding {
                id: "emb-test-001".to_string(),
                vector: vector.clone(),
                model_version: "all-MiniLM-L6-v2".to_string(),
            })
            .await
            .expect("create should succeed");

        assert_eq!(created.id, "emb-test-001");
        assert_eq!(created.dimensions, 4);
        assert_eq!(created.vector, vector);

        let fetched = repo.get_embedding_by_id("emb-test-001").await.unwrap();
        assert_eq!(fetched.vector, vector);
    }

    #[tokio::test]
    async fn delete_metadata_succeeds() {
        let (repo, _workspace_id, file_id, _guard) = repo_with_file().await;

        let created = repo
            .create_metadata(NewMLMetadata {
                file_id,
                model_version: "v1.0".to_string(),
                embedding_id: None,
                classification: None,
                confidence: None,
            })
            .await
            .unwrap();

        repo.delete_metadata(created.id).await.unwrap();

        let result = repo.get_metadata_by_id(created.id).await;
        assert!(matches!(result, Err(DatabaseError::NotFound { .. })));
    }

    #[tokio::test]
    async fn delete_embedding_succeeds() {
        let (repo, _workspace_id, _file_id, _guard) = repo_with_file().await;

        repo.create_embedding(NewEmbedding {
            id: "emb-delete-test".to_string(),
            vector: vec![0.5, 0.6],
            model_version: "v1".to_string(),
        })
        .await
        .unwrap();

        repo.delete_embedding("emb-delete-test").await.unwrap();

        let result = repo.get_embedding_by_id("emb-delete-test").await;
        assert!(matches!(result, Err(DatabaseError::NotFound { .. })));
    }
}
