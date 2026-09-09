//! Activity-based recommendation generator.

use chrono::{Duration, Utc};
use uuid::Uuid;

use crate::errors::DatabaseError;
use crate::intelligence::recommendation::models::{
    Recommendation, RecommendationCategory,
};
use crate::repositories::WorkspaceRepository;

use super::RecommendationGenerator;

/// Generates recommendations based on workspace activity patterns.
pub struct ActivityRecommendationGenerator {
    workspace_repository: WorkspaceRepository,
}

impl ActivityRecommendationGenerator {
    /// Creates a new activity recommendation generator.
    pub fn new(workspace_repository: WorkspaceRepository) -> Self {
        Self {
            workspace_repository,
        }
    }
}

#[async_trait::async_trait]
impl RecommendationGenerator for ActivityRecommendationGenerator {
    async fn generate(&self, workspace_id: Uuid) -> Result<Vec<Recommendation>, DatabaseError> {
        let mut recommendations = Vec::new();

        // Get workspace stats
        let stats = match self
            .workspace_repository
            .get_workspace_stats(workspace_id)
            .await
        {
            Ok(stats) => stats,
            Err(_) => return Ok(recommendations), // Workspace not found, return empty
        };

        let now = Utc::now();
        let time_since_last_activity = now.signed_duration_since(stats.last_activity);

        // Check for inactivity (no activity in 7+ days) — informational
        // until a permitted settings tool exists. OpenView maps to `navigate`
        // which is not in ToolRegistry (would be Unsupported).
        if time_since_last_activity > Duration::days(7) {
            recommendations.push(
                Recommendation::new(
                    workspace_id.to_string(),
                    RecommendationCategory::Productivity,
                    "Workspace appears inactive",
                    format!(
                        "No activity in {} days. Consider archiving if no longer needed.",
                        time_since_last_activity.num_days()
                    ),
                )
                .with_confidence(0.9)
                .with_impact(0.4)
                .with_effort(0.1),
            );
        } else if time_since_last_activity > Duration::days(3) {
            // Low activity warning
            recommendations.push(
                Recommendation::new(
                    workspace_id.to_string(),
                    RecommendationCategory::Productivity,
                    "Low recent activity",
                    format!(
                        "Last active {} days ago. Consider consolidating workspaces.",
                        time_since_last_activity.num_days()
                    ),
                )
                .with_confidence(0.7)
                .with_impact(0.3)
                .with_effort(0.2),
            );
        }

        // Check for high activity (many timeline events)
        if stats.timeline_event_count > 500 && time_since_last_activity < Duration::days(1) {
            recommendations.push(
                Recommendation::new(
                    workspace_id.to_string(),
                    RecommendationCategory::Productivity,
                    "High productivity workspace",
                    format!(
                        "Very active workspace with {} events. Great work!",
                        stats.timeline_event_count
                    ),
                )
                .with_confidence(0.8)
                .with_impact(0.5)
                .with_effort(0.0),
            );
        }

        // Check if workspace needs organization (many files but few events recently)
        // — informational; OpenView "files" would be `navigate` Unsupported.
        if stats.file_count > 100 && stats.timeline_event_count < 50 {
            recommendations.push(
                Recommendation::new(
                    workspace_id.to_string(),
                    RecommendationCategory::Organization,
                    "Large workspace with low activity",
                    format!(
                        "{} files but only {} events. Consider organizing or archiving unused files.",
                        stats.file_count, stats.timeline_event_count
                    ),
                )
                .with_confidence(0.75)
                .with_impact(0.6)
                .with_effort(0.5),
            );
        }

        Ok(recommendations)
    }
}
