//! Duplicate detection engine with incremental, resumable scanning.

use std::path::Path;
use std::sync::Arc;
use tokio::sync::RwLock;
use uuid::Uuid;

use crate::app_events::AppEventEmitter;
use crate::errors::DatabaseError;
use crate::hashing::{HashingError, HashingService};
use crate::models::DuplicateFile;
use crate::repositories::FileRepository;

pub use crate::models::{DuplicateGroup, ScanProgress};

/// Engine for detecting duplicate files via content hashing.
///
/// Designed for background operation with progress reporting through the
/// existing [`AppEventEmitter`] infrastructure. Supports incremental scanning,
/// resumption, and cancellation without blocking the UI thread.
#[derive(Clone)]
pub struct DuplicateDetectionEngine {
    file_repository: FileRepository,
    hashing_service: HashingService,
    event_emitter: Option<Arc<dyn AppEventEmitter>>,
    progress: Arc<RwLock<Option<ScanProgress>>>,
}

impl DuplicateDetectionEngine {
    /// Creates a new duplicate detection engine.
    pub fn new(file_repository: FileRepository) -> Self {
        Self {
            file_repository,
            hashing_service: HashingService::new(),
            event_emitter: None,
            progress: Arc::new(RwLock::new(None)),
        }
    }

    /// Attaches an event emitter for progress updates.
    pub fn with_event_emitter(mut self, emitter: Arc<dyn AppEventEmitter>) -> Self {
        self.event_emitter = Some(emitter);
        self
    }

    /// Hashes a single file and updates its content_hash in the database.
    ///
    /// # Errors
    /// - [`HashingError`] if the file cannot be read
    /// - [`DatabaseError`] if the database update fails
    pub async fn hash_single_file(
        &self,
        file_id: Uuid,
        path: impl AsRef<Path>,
    ) -> Result<String, DuplicateDetectionError> {
        let hash = self
            .hashing_service
            .hash_file(path)
            .map_err(DuplicateDetectionError::Hashing)?;

        self.file_repository
            .update_content_hash(file_id, Some(hash.clone()))
            .await
            .map_err(DuplicateDetectionError::Database)?;

        tracing::info!(file_id = %file_id, hash = %hash, "file hashed");
        Ok(hash)
    }

    /// Performs an incremental workspace scan, hashing all unhashed files.
    ///
    /// Progress is reported via the event emitter (if attached) and can be
    /// queried via [`get_scan_progress`]. The scan is resumable: if cancelled
    /// or interrupted, calling this again will only hash files that still need it.
    ///
    /// # Errors
    /// Returns an error if the initial file list cannot be retrieved from the
    /// database. Individual file hashing errors are logged but don't stop the scan.
    pub async fn hash_workspace_incremental(
        &self,
        workspace_id: Uuid,
    ) -> Result<ScanProgress, DuplicateDetectionError> {
        let files_to_hash = self
            .file_repository
            .list_unhashed_files(Some(workspace_id))
            .await
            .map_err(DuplicateDetectionError::Database)?;

        let total = files_to_hash.len();
        let mut progress = ScanProgress::new(total);

        // Store initial progress
        {
            let mut guard = self.progress.write().await;
            *guard = Some(progress.clone());
        }

        self.emit_progress(&progress).await;

        tracing::info!(
            workspace_id = %workspace_id,
            total_files = total,
            "starting incremental duplicate scan"
        );

        for file in files_to_hash {
            // Check for cancellation
            if self.is_cancelled().await {
                tracing::info!("scan cancelled by user");
                break;
            }

            match self.hash_single_file(file.id, &file.path_or_url).await {
                Ok(_) => {
                    progress.increment_scanned(file.path_or_url.clone());
                    tracing::debug!(path = %file.path_or_url, "file hashed successfully");
                }
                Err(e) => {
                    progress.increment_failed();
                    tracing::warn!(
                        path = %file.path_or_url,
                        error = %e,
                        "failed to hash file, continuing scan"
                    );
                }
            }

            // Update and emit progress
            {
                let mut guard = self.progress.write().await;
                *guard = Some(progress.clone());
            }
            self.emit_progress(&progress).await;
        }

        progress.mark_complete();
        {
            let mut guard = self.progress.write().await;
            *guard = Some(progress.clone());
        }
        self.emit_progress(&progress).await;

        tracing::info!(
            workspace_id = %workspace_id,
            files_scanned = progress.files_scanned,
            files_failed = progress.files_failed,
            "incremental duplicate scan complete"
        );

        Ok(progress)
    }

    /// Detects all duplicate file groups in a workspace (or all workspaces).
    ///
    /// Returns groups of files that share the same content hash. Only files
    /// that have been hashed (via [`hash_workspace_incremental`] or
    /// [`hash_single_file`]) are included.
    ///
    /// # Errors
    /// Returns an error if the database query fails.
    pub async fn detect_duplicates(
        &self,
        workspace_id: Option<Uuid>,
    ) -> Result<Vec<DuplicateGroup>, DuplicateDetectionError> {
        let groups = self
            .file_repository
            .get_duplicate_groups(workspace_id)
            .await
            .map_err(DuplicateDetectionError::Database)?;

        let result = groups
            .into_iter()
            .map(|(content_hash, files)| {
                let file_count = files.len();
                let total_size = 0; // TODO: Add size tracking to files table

                let duplicate_files: Vec<DuplicateFile> = files
                    .into_iter()
                    .map(DuplicateFile::from_artifact)
                    .collect();

                DuplicateGroup {
                    content_hash,
                    files: duplicate_files,
                    file_count,
                    total_size,
                }
            })
            .collect();

        Ok(result)
    }

    /// Gets duplicate groups, a convenience wrapper around [`detect_duplicates`].
    pub async fn get_duplicate_groups(
        &self,
        workspace_id: Option<Uuid>,
    ) -> Result<Vec<DuplicateGroup>, DuplicateDetectionError> {
        self.detect_duplicates(workspace_id).await
    }

    /// Gets the current scan progress, if a scan is in progress.
    pub async fn get_scan_progress(&self) -> Option<ScanProgress> {
        self.progress.read().await.clone()
    }

    /// Cancels an ongoing scan.
    ///
    /// The scan will stop after completing the current file. Already-hashed
    /// files remain hashed, so resuming will skip them.
    pub async fn cancel_scan(&self) {
        let mut guard = self.progress.write().await;
        if let Some(progress) = guard.as_mut() {
            progress.mark_complete();
            tracing::info!("scan cancellation requested");
        }
    }

    /// Checks if the scan has been cancelled.
    async fn is_cancelled(&self) -> bool {
        let guard = self.progress.read().await;
        guard.as_ref().is_some_and(|p| p.is_complete)
    }

    /// Emits progress via the event emitter if one is attached.
    async fn emit_progress(&self, progress: &ScanProgress) {
        if let Some(emitter) = &self.event_emitter {
            emitter.emit_event(
                "duplicates:scan-progress",
                serde_json::to_value(progress).unwrap_or_default(),
            );
        }
    }
}

/// Errors that can occur during duplicate detection.
#[derive(Debug, thiserror::Error)]
pub enum DuplicateDetectionError {
    /// Failed to hash a file.
    #[error("hashing error: {0}")]
    Hashing(#[from] HashingError),

    /// Database operation failed.
    #[error("database error: {0}")]
    Database(#[from] DatabaseError),
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::test_database;
    use crate::models::{ArtifactType, CreateWorkspaceInput, NewFile};
    use crate::repositories::WorkspaceRepository;
    use std::io::Write;
    use tempfile::NamedTempFile;

    async fn setup_engine() -> (DuplicateDetectionEngine, Uuid, tempfile::TempDir) {
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

        let file_repo = FileRepository::new(database.pool().clone());
        let engine = DuplicateDetectionEngine::new(file_repo);

        (engine, workspace.id, temp_dir)
    }

    #[tokio::test]
    async fn hash_single_file_updates_database() {
        let (engine, workspace_id, _guard) = setup_engine().await;

        // Create a temporary file with known content
        let mut temp_file = NamedTempFile::new().unwrap();
        temp_file.write_all(b"test content").unwrap();
        let path = temp_file.path().to_path_buf();

        // Create a file record
        let file = engine
            .file_repository
            .create(NewFile {
                workspace_id,
                artifact_type: ArtifactType::File,
                path_or_url: path.to_string_lossy().to_string(),
                content_hash: None,
                file_identifier: None,
            })
            .await
            .unwrap();

        // Hash the file
        let hash = engine.hash_single_file(file.id, &path).await.unwrap();

        // Verify the hash was stored
        let updated = engine.file_repository.get_by_id(file.id).await.unwrap();
        assert_eq!(updated.content_hash, Some(hash));
    }

    #[tokio::test]
    async fn detect_duplicates_finds_matching_hashes() {
        let (engine, workspace_id, _guard) = setup_engine().await;

        // Create two files with the same hash
        let hash = "duplicate-hash-123";
        engine
            .file_repository
            .create(NewFile {
                workspace_id,
                artifact_type: ArtifactType::File,
                path_or_url: "/path/file1.txt".to_string(),
                content_hash: Some(hash.to_string()),
                file_identifier: None,})
            .await
            .unwrap();

        engine
            .file_repository
            .create(NewFile {
                workspace_id,
                artifact_type: ArtifactType::File,
                path_or_url: "/path/file2.txt".to_string(),
                content_hash: Some(hash.to_string()),
                file_identifier: None,})
            .await
            .unwrap();

        // Detect duplicates
        let groups = engine.detect_duplicates(Some(workspace_id)).await.unwrap();

        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].file_count, 2);
        assert_eq!(groups[0].content_hash, hash);
    }

    #[tokio::test]
    async fn detect_duplicates_ignores_unique_files() {
        let (engine, workspace_id, _guard) = setup_engine().await;

        // Create files with unique hashes
        engine
            .file_repository
            .create(NewFile {
                workspace_id,
                artifact_type: ArtifactType::File,
                path_or_url: "/path/unique1.txt".to_string(),
                content_hash: Some("hash1".to_string()),
                file_identifier: None,})
            .await
            .unwrap();

        engine
            .file_repository
            .create(NewFile {
                workspace_id,
                artifact_type: ArtifactType::File,
                path_or_url: "/path/unique2.txt".to_string(),
                content_hash: Some("hash2".to_string()),
                file_identifier: None,})
            .await
            .unwrap();

        // Should find no duplicate groups
        let groups = engine.detect_duplicates(Some(workspace_id)).await.unwrap();
        assert_eq!(groups.len(), 0);
    }

    #[tokio::test]
    async fn scan_progress_tracks_state() {
        let mut progress = ScanProgress::new(10);

        assert_eq!(progress.files_scanned, 0);
        assert_eq!(progress.total_files, 10);
        assert!(!progress.is_complete);

        progress.increment_scanned("file1.txt".to_string());
        assert_eq!(progress.files_scanned, 1);
        assert_eq!(progress.current_file, Some("file1.txt".to_string()));

        progress.increment_failed();
        assert_eq!(progress.files_failed, 1);

        progress.mark_complete();
        assert!(progress.is_complete);
        assert_eq!(progress.current_file, None);
    }

    #[tokio::test]
    async fn scan_progress_calculates_percentage() {
        let mut progress = ScanProgress::new(100);
        assert_eq!(progress.percentage(), 0.0);

        progress.files_scanned = 50;
        assert_eq!(progress.percentage(), 50.0);

        progress.files_scanned = 100;
        assert_eq!(progress.percentage(), 100.0);
    }
}
