//! Repository Pattern: the only layer allowed to run SQL.
//!
//! Each repository owns one aggregate's persistence (create/read/update/
//! delete plus a handful of aggregate-specific queries) and returns
//! strongly typed [`crate::models`] values or a [`crate::errors::DatabaseError`].
//! Services and commands depend on these types, never on `sqlx::SqlitePool`
//! directly — that keeps every SQL string in exactly one place per table
//! and makes each repository independently testable against a temporary
//! database (see the `#[cfg(test)]` modules in each file).

pub mod context_intel_repository;
pub mod file_repository;
pub mod graph_repository;
pub mod kg_live_repository;
pub mod kg_opt_repository;
pub mod kg_repository;
pub mod llm;
pub mod maintenance_repository;
pub mod ml_repository;
pub mod performance_repository;
pub mod recovery_repository;
pub mod search_repository;
pub mod activity_repository;
pub mod security_repository;
pub mod settings_repository;
pub mod timeline_repository;
pub mod workspace_repository;

pub use context_intel_repository::ContextIntelRepository;
pub use file_repository::FileRepository;
pub use graph_repository::GraphRepository;
pub use kg_live_repository::KgLiveRepository;
pub use kg_opt_repository::KgOptRepository;
pub use kg_repository::KgRepository;
pub use llm::LLMRepository;
pub use maintenance_repository::MaintenanceRepository;
pub use ml_repository::MLRepository;
pub use performance_repository::PerformanceRepository;
pub use recovery_repository::RecoveryRepository;
pub use search_repository::SearchRepository;
pub use security_repository::SecurityRepository;
pub use activity_repository::ActivityRepository;
pub use settings_repository::SettingsRepository;
pub use timeline_repository::TimelineRepository;
pub use workspace_repository::WorkspaceRepository;
