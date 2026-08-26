//! AI Module - Local ONNX-based Intelligence
//!
//! Provides model management, embeddings, reranking, and inference caching.

pub mod benchmark;
pub mod cache;
pub mod diagnostics;
pub mod inference;
pub mod manager;
pub mod models;
pub mod onnx_provider;
pub mod reranker;
pub mod settings;
pub mod shared_provider;
pub mod tokenizer;
pub mod workers;

pub use benchmark::{run_benchmark, run_benchmark_async, Benchmark, BenchmarkResult};
pub use cache::{EmbeddingCache, InferenceCache};
pub use diagnostics::AIDiagnostics;
pub use inference::{EmbeddingInferenceEngine, InferenceEnginePool, RerankerInferenceEngine};
pub use manager::ModelManager;
pub use models::{
    DownloadProgress, InferenceStats, ModelInfo, ModelMetadata, ModelStatus, ModelType,
};
pub use onnx_provider::ONNXEmbeddingProvider;
pub use reranker::Reranker;
pub use settings::AISettings;
pub use shared_provider::SharedProvider;
pub use tokenizer::BertTokenizer;
pub use workers::EmbeddingWorker;
