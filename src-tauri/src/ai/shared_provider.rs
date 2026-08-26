//! Shared embedding provider — the single local semantic representation
//! for memory, search, graph and the Context Field.
//!
//! Holds an `RwLock` around the current `VectorProvider`/`EmbeddingProvider`
//! so `MemoryVectorSystem`, `SemanticMemoryEngine` and `KgOptService` can
//! all share the same ONNX model when it is loaded, with deterministic
//! `LocalVectorProvider` (n-gram) as the fallback. No new embedding logic,
//! no external service, no second vector DB.

use std::sync::Arc;

use async_trait::async_trait;
use parking_lot::RwLock;

use crate::copilot::memory::vector::provider::VectorProvider;
use crate::errors::DatabaseError;
use crate::models::kg_live::GraphEmbedder;
use crate::semantic::embeddings::EmbeddingProvider;

/// A `VectorProvider` + `EmbeddingProvider` + `GraphEmbedder` that delegates
/// to an inner provider held behind an `RwLock`. `MemoryEngine`,
/// `SemanticMemoryEngine` and the graph services all share one `Arc<Self>`,
/// so a single `load_model` that swaps the inner provider instantly upgrades
/// every consumer without rewriting each service.
pub struct SharedProvider {
    inner: RwLock<Arc<dyn VectorProvider>>,
    name: RwLock<String>,
}

impl SharedProvider {
    /// Creates a shared provider wrapping `initial` (typically
    /// `LocalVectorProvider::default()`).
    pub fn new(initial: Arc<dyn VectorProvider>) -> Self {
        let name = initial.name().to_string();
        Self {
            inner: RwLock::new(initial),
            name: RwLock::new(name),
        }
    }

    /// Swaps the inner provider (e.g. to an `ONNXEmbeddingProvider` wrapped
    /// as `VectorProvider`). Cheap, no reallocation of the outer `Arc`.
    pub fn set_provider(&self, new_provider: Arc<dyn VectorProvider>) {
        let name = new_provider.name().to_string();
        {
            let mut guard = self.inner.write();
            *guard = new_provider;
        }
        {
            let mut n = self.name.write();
            *n = name;
        }
    }

    /// Current provider name for diagnostics.
    pub fn current_name(&self) -> String {
        self.name.read().clone()
    }
}

#[async_trait]
impl VectorProvider for SharedProvider {
    async fn embed(&self, text: &str) -> Result<Vec<f32>, DatabaseError> {
        let provider = { self.inner.read().clone() };
        provider.embed(text).await
    }

    async fn embed_batch(&self, texts: &[&str]) -> Result<Vec<Vec<f32>>, DatabaseError> {
        let provider = { self.inner.read().clone() };
        provider.embed_batch(texts).await
    }

    fn dimensions(&self) -> usize {
        self.inner.read().dimensions()
    }

    fn name(&self) -> &str {
        Box::leak(self.name.read().clone().into_boxed_str())
    }
}

#[async_trait]
impl EmbeddingProvider for SharedProvider {
    async fn embed(&self, text: &str) -> Result<Vec<f32>, DatabaseError> {
        let provider = { self.inner.read().clone() };
        provider.embed(text).await
    }

    fn dimensions(&self) -> usize {
        self.inner.read().dimensions()
    }

    fn name(&self) -> &str {
        Box::leak(self.name.read().clone().into_boxed_str())
    }
}

#[async_trait]
impl GraphEmbedder for SharedProvider {
    async fn embed(&self, text: &str) -> Option<Vec<f32>> {
        let provider = { self.inner.read().clone() };
        provider.embed(text).await.ok()
    }
}
