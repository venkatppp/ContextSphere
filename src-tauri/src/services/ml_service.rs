//! ML Service — business logic for ML operations (Phase 5).
//!
//! Composes MLRepository and FileRepository to coordinate ML inference
//! results with file metadata storage. Follows the same pattern as
//! WorkspaceService and TimelineService.

use uuid::Uuid;

use crate::errors::DatabaseError;
use crate::models::{Embedding, FileClassification, MLMetadata, NewEmbedding, NewMLMetadata};
use crate::repositories::{FileRepository, MLRepository};

/// Service layer for ML operations. Orchestrates ML metadata and embedding
/// storage, coordinating between MLRepository and FileRepository.
#[derive(Clone)]
pub struct MLService {
    ml_repository: MLRepository,
    file_repository: FileRepository,
}

impl MLService {
    /// Creates a new MLService with the given repositories.
    pub fn new(ml_repository: MLRepository, file_repository: FileRepository) -> Self {
        Self {
            ml_repository,
            file_repository,
        }
    }

    /// Creates ML metadata for a file. If metadata already exists for this
    /// (file_id, model_version) pair, returns an error due to the unique
    /// constraint.
    pub async fn create_metadata(&self, input: NewMLMetadata) -> Result<MLMetadata, DatabaseError> {
        // Verify the file exists before creating metadata
        self.file_repository.get_by_id(input.file_id).await?;

        self.ml_repository.create_metadata(input).await
    }

    /// Retrieves ML metadata for a file and specific model version.
    pub async fn get_metadata(
        &self,
        file_id: Uuid,
        model_version: &str,
    ) -> Result<Option<MLMetadata>, DatabaseError> {
        self.ml_repository
            .get_metadata_by_file(file_id, model_version)
            .await
    }

    /// Updates the classification for existing ML metadata.
    pub async fn update_classification(
        &self,
        metadata_id: Uuid,
        classification: FileClassification,
        confidence: f32,
    ) -> Result<(), DatabaseError> {
        self.ml_repository
            .update_classification(metadata_id, classification, confidence)
            .await
    }

    /// Stores an embedding and associates it with ML metadata.
    pub async fn store_embedding(
        &self,
        metadata_id: Uuid,
        embedding_input: NewEmbedding,
    ) -> Result<Embedding, DatabaseError> {
        // Create the embedding first
        let embedding = self
            .ml_repository
            .create_embedding(embedding_input.clone())
            .await?;

        // Update the metadata record to reference it
        self.ml_repository
            .update_embedding_id(metadata_id, embedding.id.clone())
            .await?;

        Ok(embedding)
    }

    /// Retrieves an embedding by its id.
    pub async fn get_embedding(&self, embedding_id: &str) -> Result<Embedding, DatabaseError> {
        self.ml_repository.get_embedding_by_id(embedding_id).await
    }

    /// Updates the content hash for a file (used by duplicate detection).
    pub async fn update_file_content_hash(
        &self,
        file_id: Uuid,
        content_hash: String,
    ) -> Result<(), DatabaseError> {
        self.file_repository
            .update_content_hash(file_id, Some(content_hash))
            .await
    }

    /// Finds files with the same content hash (duplicates).
    pub async fn find_duplicates(
        &self,
        content_hash: &str,
    ) -> Result<Vec<crate::models::FileArtifact>, DatabaseError> {
        self.file_repository
            .find_by_content_hash(content_hash)
            .await
    }

    /// Deletes ML metadata and optionally its associated embedding.
    pub async fn delete_metadata(
        &self,
        metadata_id: Uuid,
        delete_embedding: bool,
    ) -> Result<(), DatabaseError> {
        // Fetch the metadata to get the embedding_id before deletion
        let metadata = self.ml_repository.get_metadata_by_id(metadata_id).await?;

        // Delete the metadata record
        self.ml_repository.delete_metadata(metadata_id).await?;

        // If requested and an embedding exists, delete it too
        if delete_embedding {
            if let Some(embedding_id) = metadata.embedding_id {
                self.ml_repository.delete_embedding(&embedding_id).await?;
            }
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::test_database;
    use crate::models::{ArtifactType, CreateWorkspaceInput, NewFile};
    use crate::repositories::WorkspaceRepository;

    async fn setup_service() -> (MLService, Uuid, Uuid, tempfile::TempDir) {
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
                path_or_url: "/test/code.rs".to_string(),
                content_hash: None,
                file_identifier: None,
            })
            .await
            .unwrap();

        let ml_repo = MLRepository::new(pool.clone());
        let service = MLService::new(ml_repo, file_repo);

        (service, workspace.id, file.id, temp_dir)
    }

    #[tokio::test]
    async fn create_metadata_succeeds() {
        let (service, _workspace_id, file_id, _guard) = setup_service().await;

        let metadata = service
            .create_metadata(NewMLMetadata {
                file_id,
                model_version: "v1.0".to_string(),
                embedding_id: None,
                classification: Some(FileClassification::Code),
                confidence: Some(0.98),
            })
            .await
            .unwrap();

        assert_eq!(metadata.file_id, file_id);
        assert_eq!(metadata.classification, Some(FileClassification::Code));
    }

    #[tokio::test]
    async fn get_metadata_returns_none_for_missing() {
        let (service, _workspace_id, file_id, _guard) = setup_service().await;

        let result = service.get_metadata(file_id, "v1.0").await.unwrap();
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn update_classification_succeeds() {
        let (service, _workspace_id, file_id, _guard) = setup_service().await;

        let metadata = service
            .create_metadata(NewMLMetadata {
                file_id,
                model_version: "v1.0".to_string(),
                embedding_id: None,
                classification: Some(FileClassification::Unknown),
                confidence: Some(0.5),
            })
            .await
            .unwrap();

        service
            .update_classification(metadata.id, FileClassification::Document, 0.92)
            .await
            .unwrap();

        let updated = service
            .get_metadata(file_id, "v1.0")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(updated.classification, Some(FileClassification::Document));
        assert_eq!(updated.confidence, Some(0.92));
    }

    #[tokio::test]
    async fn store_and_get_embedding_succeeds() {
        let (service, _workspace_id, file_id, _guard) = setup_service().await;

        let metadata = service
            .create_metadata(NewMLMetadata {
                file_id,
                model_version: "v1.0".to_string(),
                embedding_id: None,
                classification: None,
                confidence: None,
            })
            .await
            .unwrap();

        let vector = vec![0.1, 0.2, 0.3];
        let embedding = service
            .store_embedding(
                metadata.id,
                NewEmbedding {
                    id: "emb-service-test".to_string(),
                    vector: vector.clone(),
                    model_version: "v1.0".to_string(),
                },
            )
            .await
            .unwrap();

        assert_eq!(embedding.vector, vector);

        let fetched = service.get_embedding("emb-service-test").await.unwrap();
        assert_eq!(fetched.vector, vector);
    }

    #[tokio::test]
    async fn delete_metadata_with_embedding_succeeds() {
        let (service, _workspace_id, file_id, _guard) = setup_service().await;

        let metadata = service
            .create_metadata(NewMLMetadata {
                file_id,
                model_version: "v1.0".to_string(),
                embedding_id: None,
                classification: None,
                confidence: None,
            })
            .await
            .unwrap();

        service
            .store_embedding(
                metadata.id,
                NewEmbedding {
                    id: "emb-delete".to_string(),
                    vector: vec![0.5],
                    model_version: "v1.0".to_string(),
                },
            )
            .await
            .unwrap();

        service.delete_metadata(metadata.id, true).await.unwrap();

        // Both metadata and embedding should be deleted
        let metadata_result = service.get_metadata(file_id, "v1.0").await.unwrap();
        assert!(metadata_result.is_none());

        let embedding_result = service.get_embedding("emb-delete").await;
        assert!(matches!(
            embedding_result,
            Err(DatabaseError::NotFound { .. })
        ));
    }
}
