//! Organization-based recommendation generator.

use uuid::Uuid;

use crate::errors::DatabaseError;
use crate::intelligence::recommendation::models::{
    Recommendation, RecommendationCategory,
};
use crate::repositories::{FileRepository, WorkspaceRepository};

use super::RecommendationGenerator;

/// Generates recommendations based on workspace organization.
pub struct OrganizationRecommendationGenerator {
    workspace_repository: WorkspaceRepository,
    #[allow(dead_code)]
    file_repository: FileRepository,
}

impl OrganizationRecommendationGenerator {
    /// Creates a new organization recommendation generator.
    pub fn new(workspace_repository: WorkspaceRepository, file_repository: FileRepository) -> Self {
        Self {
            workspace_repository,
            file_repository,
        }
    }
}

#[async_trait::async_trait]
impl RecommendationGenerator for OrganizationRecommendationGenerator {
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

        let file_count = stats.file_count;

        // Check for large workspaces
        if file_count > 100 {
            recommendations.push(
                Recommendation::new(
                    workspace_id.to_string(),
                    RecommendationCategory::Organization,
                    "Large workspace detected",
                    format!(
                        "This workspace has {} files. Consider organizing into subdirectories.",
                        file_count
                    ),
                )
                .with_confidence(0.75)
                .with_impact(0.6)
                .with_effort(0.7),
            );
        }

        // Check for medium workspaces that might benefit from organization
        if file_count > 50 && file_count <= 100 {
            recommendations.push(
                Recommendation::new(
                    workspace_id.to_string(),
                    RecommendationCategory::Organization,
                    "Growing workspace",
                    format!(
                        "{} files in workspace. Good time to organize before it gets too large.",
                        file_count
                    ),
                )
                .with_confidence(0.65)
                .with_impact(0.5)
                .with_effort(0.4),
            );
        }

        // Duplicate scan recommendation — informational only until a safe,
        // permitted duplicate-scan tool exists in ToolRegistry. Must not
        // produce an unsupported ExecuteCommand that would surface as a
        // runnable "Scan for duplicate files" Run button (the screenshot
        // regression). Surfacing as Info keeps the insight without a Run.
        if file_count > 50 {
            recommendations.push(
                Recommendation::new(
                    workspace_id.to_string(),
                    RecommendationCategory::Files,
                    "Scan for duplicate files",
                    "Run a duplicate scan to identify and clean up redundant files.",
                )
                .with_confidence(0.6)
                .with_impact(0.4)
                .with_effort(0.2),
            );
        }

        // Check for very small workspaces that might need consolidation
        if file_count > 0 && file_count < 5 && stats.timeline_event_count < 10 {
            recommendations.push(
                Recommendation::new(
                    workspace_id.to_string(),
                    RecommendationCategory::Organization,
                    "Small workspace with low activity",
                    format!(
                        "Only {} files. Consider merging with related workspaces.",
                        file_count
                    ),
                )
                .with_confidence(0.7)
                .with_impact(0.4)
                .with_effort(0.3),
            );
        }

        Ok(recommendations)
    }
}
