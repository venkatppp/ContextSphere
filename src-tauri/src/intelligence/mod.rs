//! Intelligence layer - recommendations and workspace health monitoring.
//!
//! This module provides intelligent insights and recommendations based on
//! user behavior, workspace state, and analytics data.

pub mod continuity;
pub mod health;
pub mod recommendation;
pub mod workspace;

pub use continuity::{
    ContextContinuityEngine, ContinuitySignal, ReconstructedContext, ReconstructedFile,
    ResumeAction,
};
pub use health::{HealthFactor, WorkspaceHealth, WorkspaceHealthEngine};
pub use recommendation::{
    Recommendation, RecommendationCategory, RecommendationEngine, RecommendationPriority,
};
pub use workspace::{
    ActiveWorkspaceInference, ConfidenceSignal, WorkEpisode, WorkspaceIntelligence,
    WorkspaceIntelligenceEngine, WorkspaceSuggestion,
};
