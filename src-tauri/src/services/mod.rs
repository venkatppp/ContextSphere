//! Business logic layer.
//!
//! Services sit between `commands` and `repositories`: they orchestrate
//! one or more repositories to implement a rule that no single
//! repository could own on its own (e.g. "opening an archived workspace
//! implicitly reactivates it, and that fact belongs in the timeline").
//! Repositories stay mechanical — pure column reads/writes — precisely so
//! that this kind of cross-cutting rule has one obvious home instead of
//! leaking into command handlers or being duplicated across repositories.

pub mod context_intel_service;
pub mod context_service;
pub mod graph_health_service;
pub mod graph_service;
pub mod kg_live_service;
pub mod kg_opt_service;
pub mod kg_service;
pub mod activity_service;
pub mod ml_service;
pub mod search_service;
pub mod timeline_service;
pub mod workspace_service;

pub use context_intel_service::ContextIntelService;
pub use context_service::ContextService;
pub use graph_health_service::GraphHealthService;
pub use graph_service::GraphService;
pub use kg_live_service::KgLiveService;
pub use kg_opt_service::KgOptService;
pub use kg_service::KgService;
pub use activity_service::ActivityService;
pub use ml_service::MLService;
pub use search_service::SearchService;
pub use timeline_service::TimelineService;
pub use workspace_service::WorkspaceService;
