//! Model Manager - Handles model lifecycle, downloads, and versioning.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use chrono::Utc;
use parking_lot::RwLock;
use tokio::fs;
use tokio::io::AsyncWriteExt;

use crate::ai::models::{DownloadProgress, ModelInfo, ModelMetadata, ModelStatus, ModelType};
use crate::ai::settings::AISettings;
use crate::errors::DatabaseError;

/// Manages AI model lifecycle.
#[derive(Clone)]
pub struct ModelManager {
    settings: Arc<RwLock<AISettings>>,
    models: Arc<RwLock<HashMap<String, ModelInfo>>>,
    #[allow(dead_code)]
    available_models: Vec<ModelMetadata>,
}

impl ModelManager {
    /// Creates a new model manager.
    pub fn new(settings: AISettings) -> Self {
        let available_models = Self::default_models();
        let mut models_map = HashMap::new();

        // Initialize model info for all available models
        for metadata in &available_models {
            models_map.insert(
                metadata.id.clone(),
                ModelInfo {
                    metadata: metadata.clone(),
                    status: ModelStatus::NotDownloaded,
                    local_path: None,
                    downloaded_at: None,
                    loaded_at: None,
                    memory_usage_bytes: None,
                    error_message: None,
                },
            );
        }

        Self {
            settings: Arc::new(RwLock::new(settings)),
            models: Arc::new(RwLock::new(models_map)),
            available_models,
        }
    }

    /// Returns the list of default available models.
    fn default_models() -> Vec<ModelMetadata> {
        vec![
            // all-MiniLM-L6-v2: Popular lightweight embedding model
            // Actual ONNX artifact is ~90 MB (90_405_214 bytes); previous 23 MB was for quantized int8.
            ModelMetadata {
                id: "all-minilm-l6-v2".to_string(),
                name: "all-MiniLM-L6-v2".to_string(),
                model_type: ModelType::Embedding,
                version: "1.0.0".to_string(),
                dimensions: 384,
                max_sequence_length: 256,
                file_size_bytes: 90_405_214, // ~86 MB actual ONNX
                download_url: "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main/onnx/model.onnx".to_string(),
                tokenizer_url: Some("https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main/tokenizer.json".to_string()),
                description: "Fast and efficient embedding model, 384 dimensions".to_string(),
            },
            // all-MiniLM-L12-v2: Larger, more accurate model
            ModelMetadata {
                id: "all-minilm-l12-v2".to_string(),
                name: "all-MiniLM-L12-v2".to_string(),
                model_type: ModelType::Embedding,
                version: "1.0.0".to_string(),
                dimensions: 384,
                max_sequence_length: 256,
                file_size_bytes: 45_000_000, // ~45MB
                download_url: "https://huggingface.co/sentence-transformers/all-MiniLM-L12-v2/resolve/main/onnx/model.onnx".to_string(),
                tokenizer_url: Some("https://huggingface.co/sentence-transformers/all-MiniLM-L12-v2/resolve/main/tokenizer.json".to_string()),
                description: "More accurate embedding model, 384 dimensions".to_string(),
            },
            // Reranker model
            ModelMetadata {
                id: "bge-reranker-base".to_string(),
                name: "BGE Reranker Base".to_string(),
                model_type: ModelType::Reranker,
                version: "1.0.0".to_string(),
                dimensions: 768,
                max_sequence_length: 512,
                file_size_bytes: 110_000_000, // ~110MB
                download_url: "https://huggingface.co/BAAI/bge-reranker-base/resolve/main/onnx/model.onnx".to_string(),
                tokenizer_url: Some("https://huggingface.co/BAAI/bge-reranker-base/resolve/main/tokenizer.json".to_string()),
                description: "Cross-encoder reranker for improved search results".to_string(),
            },
        ]
    }

    /// Lists all available models.
    pub fn list_models(&self) -> Vec<ModelInfo> {
        let models = self.models.read();
        models.values().cloned().collect()
    }

    /// Gets information about a specific model.
    pub fn get_model(&self, model_id: &str) -> Option<ModelInfo> {
        let models = self.models.read();
        models.get(model_id).cloned()
    }

    /// Gets the active embedding model ID.
    pub fn active_embedding_model(&self) -> Option<String> {
        self.settings.read().active_embedding_model.clone()
    }

    /// Gets the active reranker model ID.
    pub fn active_reranker_model(&self) -> Option<String> {
        self.settings.read().active_reranker_model.clone()
    }

    /// Sets the active embedding model.
    pub fn set_active_embedding_model(&self, model_id: String) -> Result<(), DatabaseError> {
        // Verify model exists and is loaded
        let models = self.models.read();
        let model = models
            .get(&model_id)
            .ok_or_else(|| DatabaseError::NotFound {
                entity: "Model",
                id: model_id.clone(),
            })?;

        if model.metadata.model_type != ModelType::Embedding {
            return Err(DatabaseError::InvalidInput(
                "Model is not an embedding model".to_string(),
            ));
        }

        if model.status != ModelStatus::Loaded {
            return Err(DatabaseError::InvalidInput(
                "Model is not loaded".to_string(),
            ));
        }

        drop(models);
        self.settings.write().active_embedding_model = Some(model_id);
        Ok(())
    }

    /// Sets the active reranker model.
    pub fn set_active_reranker_model(&self, model_id: String) -> Result<(), DatabaseError> {
        // Verify model exists and is loaded
        let models = self.models.read();
        let model = models
            .get(&model_id)
            .ok_or_else(|| DatabaseError::NotFound {
                entity: "Model",
                id: model_id.clone(),
            })?;

        if model.metadata.model_type != ModelType::Reranker {
            return Err(DatabaseError::InvalidInput(
                "Model is not a reranker model".to_string(),
            ));
        }

        if model.status != ModelStatus::Loaded {
            return Err(DatabaseError::InvalidInput(
                "Model is not loaded".to_string(),
            ));
        }

        drop(models);
        self.settings.write().active_reranker_model = Some(model_id);
        Ok(())
    }

    /// Downloads a model with resumption support.
    pub async fn download_model<F>(
        &self,
        model_id: &str,
        progress_callback: F,
    ) -> Result<(), DatabaseError>
    where
        F: Fn(DownloadProgress) + Send + 'static,
    {
        // Get model metadata
        let metadata = {
            let models = self.models.read();
            let model = models
                .get(model_id)
                .ok_or_else(|| DatabaseError::NotFound {
                    entity: "Model",
                    id: model_id.to_string(),
                })?;

            if model.status == ModelStatus::Downloaded || model.status == ModelStatus::Loaded {
                return Ok(());
            }

            model.metadata.clone()
        };

        // Update status to downloading
        {
            let mut models = self.models.write();
            if let Some(model) = models.get_mut(model_id) {
                model.status = ModelStatus::Downloading;
                model.error_message = None;
            }
        }

        // Create models directory
        let models_dir = self.settings.read().models_dir.clone();
        fs::create_dir_all(&models_dir).await.map_err(|e| {
            DatabaseError::IoError(format!("Failed to create models directory: {}", e))
        })?;

        let model_dir = models_dir.join(&metadata.id);
        fs::create_dir_all(&model_dir).await.map_err(|e| {
            DatabaseError::IoError(format!("Failed to create model directory: {}", e))
        })?;

        // Download model file with recovery
        let model_path = model_dir.join("model.onnx");
        let model_temp_path = model_dir.join("model.onnx.tmp");

        if let Err(e) = self
            .download_file_with_recovery(
                &metadata.download_url,
                &model_path,
                &model_temp_path,
                metadata.file_size_bytes,
                model_id,
                &progress_callback,
            )
            .await
        {
            // Clean up partial downloads on error
            let _ = fs::remove_file(&model_temp_path).await;
            self.mark_error(model_id, e.to_string())?;
            return Err(e);
        }

        // Download tokenizer if available
        if let Some(tokenizer_url) = &metadata.tokenizer_url {
            let tokenizer_path = model_dir.join("tokenizer.json");
            let tokenizer_temp_path = model_dir.join("tokenizer.json.tmp");

            if let Err(e) = self
                .download_file_simple_with_recovery(
                    tokenizer_url,
                    &tokenizer_path,
                    &tokenizer_temp_path,
                )
                .await
            {
                // Clean up on error
                let _ = fs::remove_file(&tokenizer_temp_path).await;
                let _ = fs::remove_file(&model_path).await;
                self.mark_error(model_id, e.to_string())?;
                return Err(e);
            }
        }

        // Update status to downloaded
        {
            let mut models = self.models.write();
            if let Some(model) = models.get_mut(model_id) {
                model.status = ModelStatus::Downloaded;
                model.local_path = Some(model_dir);
                model.downloaded_at = Some(Utc::now());
                model.error_message = None;
            }
        }

        Ok(())
    }

    /// Downloads a file with progress tracking and resumption support.
    async fn download_file_with_recovery<F>(
        &self,
        url: &str,
        path: &Path,
        temp_path: &Path,
        total_size: u64,
        model_id: &str,
        progress_callback: &F,
    ) -> Result<(), DatabaseError>
    where
        F: Fn(DownloadProgress),
    {
        // Check if file already exists — treat any existing file as downloaded
        // (allows manual copy of the 86 MB ONNX file even though metadata says 23 MB).
        if path.exists() {
            return Ok(());
        }

        // Check for partial download
        let mut downloaded = 0u64;
        if temp_path.exists() {
            let metadata = fs::metadata(temp_path).await.map_err(|e| {
                DatabaseError::IoError(format!("Failed to get temp file metadata: {}", e))
            })?;
            downloaded = metadata.len();
        }

        let client = reqwest::Client::new();
        let mut request = client.get(url);

        // Resume from where we left off
        if downloaded > 0 {
            request = request.header("Range", format!("bytes={}-", downloaded));
        }

        let response = request
            .send()
            .await
            .map_err(|e| DatabaseError::IoError(format!("Failed to download model: {}", e)))?;

        if !response.status().is_success() && response.status().as_u16() != 206 {
            return Err(DatabaseError::IoError(format!(
                "Failed to download model: HTTP {}",
                response.status()
            )));
        }

        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(temp_path)
            .await
            .map_err(|e| DatabaseError::IoError(format!("Failed to create temp file: {}", e)))?;

        let mut stream = response.bytes_stream();

        use futures::StreamExt;
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|e| {
                DatabaseError::IoError(format!("Failed to read download chunk: {}", e))
            })?;

            file.write_all(&chunk)
                .await
                .map_err(|e| DatabaseError::IoError(format!("Failed to write temp file: {}", e)))?;

            downloaded += chunk.len() as u64;

            progress_callback(DownloadProgress {
                model_id: model_id.to_string(),
                bytes_downloaded: downloaded,
                total_bytes: total_size,
                progress_percent: (downloaded as f32 / total_size as f32) * 100.0,
                speed_bytes_per_sec: 0, // TODO: Calculate speed
            });
        }

        file.flush()
            .await
            .map_err(|e| DatabaseError::IoError(format!("Failed to flush temp file: {}", e)))?;

        drop(file);

        // Move temp file to final location
        fs::rename(temp_path, path)
            .await
            .map_err(|e| DatabaseError::IoError(format!("Failed to finalize download: {}", e)))?;

        Ok(())
    }

    /// Downloads a file without progress tracking, with resumption support.
    async fn download_file_simple_with_recovery(
        &self,
        url: &str,
        path: &Path,
        temp_path: &Path,
    ) -> Result<(), DatabaseError> {
        // Check if file already exists
        if path.exists() {
            return Ok(());
        }

        // Check for partial download and clean it up (tokenizers are small, just restart)
        if temp_path.exists() {
            let _ = fs::remove_file(temp_path).await;
        }

        let client = reqwest::Client::new();
        let response = client
            .get(url)
            .send()
            .await
            .map_err(|e| DatabaseError::IoError(format!("Failed to download file: {}", e)))?;

        if !response.status().is_success() {
            return Err(DatabaseError::IoError(format!(
                "Failed to download file: HTTP {}",
                response.status()
            )));
        }

        let bytes = response
            .bytes()
            .await
            .map_err(|e| DatabaseError::IoError(format!("Failed to read download: {}", e)))?;

        fs::write(temp_path, bytes)
            .await
            .map_err(|e| DatabaseError::IoError(format!("Failed to write temp file: {}", e)))?;

        // Move to final location
        fs::rename(temp_path, path)
            .await
            .map_err(|e| DatabaseError::IoError(format!("Failed to finalize download: {}", e)))?;

        Ok(())
    }

    /// Marks a model as loaded.
    pub fn mark_loaded(&self, model_id: &str, memory_usage: u64) -> Result<(), DatabaseError> {
        let mut models = self.models.write();
        let model = models
            .get_mut(model_id)
            .ok_or_else(|| DatabaseError::NotFound {
                entity: "Model",
                id: model_id.to_string(),
            })?;

        model.status = ModelStatus::Loaded;
        model.loaded_at = Some(Utc::now());
        model.memory_usage_bytes = Some(memory_usage);
        model.error_message = None;

        Ok(())
    }

    /// Marks a model as unloaded.
    pub fn mark_unloaded(&self, model_id: &str) -> Result<(), DatabaseError> {
        let mut models = self.models.write();
        let model = models
            .get_mut(model_id)
            .ok_or_else(|| DatabaseError::NotFound {
                entity: "Model",
                id: model_id.to_string(),
            })?;

        model.status = ModelStatus::Downloaded;
        model.loaded_at = None;
        model.memory_usage_bytes = None;

        Ok(())
    }

    /// Marks a model as having an error.
    pub fn mark_error(&self, model_id: &str, error: String) -> Result<(), DatabaseError> {
        let mut models = self.models.write();
        let model = models
            .get_mut(model_id)
            .ok_or_else(|| DatabaseError::NotFound {
                entity: "Model",
                id: model_id.to_string(),
            })?;

        model.status = ModelStatus::Error;
        model.error_message = Some(error);

        Ok(())
    }

    /// Gets the model directory path.
    pub fn get_model_path(&self, model_id: &str) -> Option<PathBuf> {
        let models = self.models.read();
        models.get(model_id)?.local_path.clone()
    }

    /// Persists the current loaded model state.
    pub fn persist_loaded_models(&self) -> Result<(), DatabaseError> {
        let models = self.models.read();
        let loaded_ids: Vec<String> = models
            .iter()
            .filter(|(_, info)| info.status == ModelStatus::Loaded)
            .map(|(id, _)| id.clone())
            .collect();

        drop(models);
        self.settings.write().loaded_model_ids = loaded_ids;
        Ok(())
    }

    /// Gets the list of models that should be auto-loaded on startup.
    pub fn get_persisted_models(&self) -> Vec<String> {
        self.settings.read().loaded_model_ids.clone()
    }

    /// Cleans up incomplete downloads and temporary files.
    pub async fn cleanup_partial_downloads(&self) -> Result<(), DatabaseError> {
        let models_dir = self.settings.read().models_dir.clone();

        if !models_dir.exists() {
            return Ok(());
        }

        let mut entries = fs::read_dir(&models_dir).await.map_err(|e| {
            DatabaseError::IoError(format!("Failed to read models directory: {}", e))
        })?;

        while let Some(entry) = entries
            .next_entry()
            .await
            .map_err(|e| DatabaseError::IoError(format!("Failed to read directory entry: {}", e)))?
        {
            let path = entry.path();

            if path.is_dir() {
                // Clean up .tmp files in model directories
                let mut model_entries = fs::read_dir(&path).await.map_err(|e| {
                    DatabaseError::IoError(format!("Failed to read model directory: {}", e))
                })?;

                while let Some(model_entry) = model_entries.next_entry().await.map_err(|e| {
                    DatabaseError::IoError(format!("Failed to read model entry: {}", e))
                })? {
                    let model_path = model_entry.path();
                    if let Some(ext) = model_path.extension() {
                        if ext == "tmp" {
                            let _ = fs::remove_file(&model_path).await;
                        }
                    }
                }
            }
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lists_default_models() {
        let settings = AISettings::default();
        let manager = ModelManager::new(settings);

        let models = manager.list_models();
        assert!(!models.is_empty());
        assert!(models
            .iter()
            .any(|m| m.metadata.model_type == ModelType::Embedding));
        assert!(models
            .iter()
            .any(|m| m.metadata.model_type == ModelType::Reranker));
    }

    #[test]
    fn gets_model_by_id() {
        let settings = AISettings::default();
        let manager = ModelManager::new(settings);

        let model = manager.get_model("all-minilm-l6-v2");
        assert!(model.is_some());
        assert_eq!(model.unwrap().metadata.id, "all-minilm-l6-v2");
    }

    #[test]
    fn sets_active_models_only_when_loaded() {
        let settings = AISettings::default();
        let manager = ModelManager::new(settings);

        // Should fail because model is not loaded
        let result = manager.set_active_embedding_model("all-minilm-l6-v2".to_string());
        assert!(result.is_err());
    }
}
