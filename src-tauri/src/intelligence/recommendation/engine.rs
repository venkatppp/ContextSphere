//! Main recommendation engine.

use std::sync::Arc;

use crate::errors::DatabaseError;
use crate::learning::engine::AdaptiveLearningEngine;
use crate::learning::models::FeedbackTargetType;
use crate::repositories::{FileRepository, WorkspaceRepository};
use crate::services::ContextService;
use parking_lot::RwLock;
use uuid::Uuid;

use super::generators::{
    ActivityRecommendationGenerator, ContextRecommendationGenerator,
    OrganizationRecommendationGenerator, RecommendationGenerator,
};
use super::models::{Recommendation, RecommendationCategory, RecommendationPriority};
use super::scoring::RecommendationScoringEngine;

/// Main recommendation engine that coordinates generators and scoring.
#[derive(Clone)]
pub struct RecommendationEngine {
    workspace_repository: WorkspaceRepository,
    file_repository: FileRepository,
    context_service: ContextService,
    scoring_engine: RecommendationScoringEngine,
    learning_engine: Arc<RwLock<Option<Arc<AdaptiveLearningEngine>>>>,
}

impl RecommendationEngine {
    /// Creates a new recommendation engine.
    pub fn new(
        workspace_repository: WorkspaceRepository,
        file_repository: FileRepository,
        context_service: ContextService,
    ) -> Self {
        Self {
            workspace_repository,
            file_repository,
            context_service,
            scoring_engine: RecommendationScoringEngine::new(),
            learning_engine: Arc::new(RwLock::new(None)),
        }
    }

    /// Attach the adaptive learning engine so future recommendations are
    /// confidence-adjusted based on real feedback/preferences (bounded,
    /// deterministic, workspace-aware). Call after both engines exist.
    pub fn with_learning_engine(self, engine: Arc<AdaptiveLearningEngine>) -> Self {
        *self.learning_engine.write() = Some(engine);
        self
    }

    /// Non-consuming setter for post-construction wiring (e.g. in `lib.rs`
    /// where the engine has already been cloned into workers).
    pub fn set_learning_engine(&self, engine: Arc<AdaptiveLearningEngine>) {
        *self.learning_engine.write() = Some(engine);
    }

    /// Generates all recommendations for a workspace.
    ///
    /// If an `AdaptiveLearningEngine` is wired, each recommendation's
    /// `confidence` is adjusted via `adjust_prediction_confidence` (bounded
    /// `historical_feedback` 0.7–1.2, preference boost 1.1, time-decayed
    /// adjustment 0.95) before scoring so the existing
    /// `(confidence*impact - effort*0.3)` formula and ranking remain the
    /// source of truth — learning only biases confidence.
    pub async fn generate_recommendations(
        &self,
        workspace_id: Uuid,
    ) -> Result<Vec<Recommendation>, DatabaseError> {
        // Create generators
        let activity_gen = ActivityRecommendationGenerator::new(self.workspace_repository.clone());
        let context_gen = ContextRecommendationGenerator::new(self.context_service.clone());
        let organization_gen = OrganizationRecommendationGenerator::new(
            self.workspace_repository.clone(),
            self.file_repository.clone(),
        );

        // Generate recommendations from all generators
        let mut all_recommendations = Vec::new();

        // Activity-based recommendations
        let activity_recs = activity_gen.generate(workspace_id).await?;
        all_recommendations.extend(activity_recs);

        // Context-based recommendations
        let context_recs = context_gen.generate(workspace_id).await?;
        all_recommendations.extend(context_recs);

        // Organization-based recommendations
        let org_recs = organization_gen.generate(workspace_id).await?;
        all_recommendations.extend(org_recs);

        // Learning-adjusted confidence (if wired). Deterministic, bounded,
        // workspace-aware via the recommendation's deterministic id.
        // No learning history → no adjustment (safe default).
        let learning = self.learning_engine.read().clone();
        if let Some(learning) = learning {
            for rec in &mut all_recommendations {
                let base = rec.confidence;
                match learning
                    .adjust_prediction_confidence(FeedbackTargetType::Recommendation, &rec.id, base)
                    .await
                {
                    Ok(expl) => rec.confidence = expl.adjusted_confidence.clamp(0.0, 1.0),
                    Err(e) => log::debug!("learning adjustment skipped for {}: {}", rec.id, e),
                }
            }
        }

        // Score and rank all recommendations (uses adjusted confidence)
        let scored = self.scoring_engine.score_and_rank(all_recommendations);

        // Filter expired recommendations
        let filtered = self.scoring_engine.filter_expired(scored);

        // Limit to top 10 recommendations
        let top_recommendations = self.scoring_engine.limit_top_n(filtered, 10);

        Ok(top_recommendations)
    }

    /// Generates recommendations for a specific category.
    pub async fn generate_category_recommendations(
        &self,
        workspace_id: Uuid,
        category: RecommendationCategory,
    ) -> Result<Vec<Recommendation>, DatabaseError> {
        // Generate all and filter by category
        let all_recommendations = self.generate_recommendations(workspace_id).await?;

        // Filter by category
        let filtered: Vec<_> = all_recommendations
            .into_iter()
            .filter(|rec| rec.category == category)
            .collect();

        Ok(filtered)
    }

    /// Generates top priority recommendations only.
    pub async fn generate_priority_recommendations(
        &self,
        workspace_id: Uuid,
        min_priority: RecommendationPriority,
    ) -> Result<Vec<Recommendation>, DatabaseError> {
        let all_recommendations = self.generate_recommendations(workspace_id).await?;

        let filtered: Vec<_> = all_recommendations
            .into_iter()
            .filter(|rec| rec.priority >= min_priority)
            .collect();

        Ok(filtered)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::test_database;
    use crate::learning::models::{FeedbackAction, FeedbackTargetType, FeedbackType};
    use crate::repositories::{FileRepository, TimelineRepository, WorkspaceRepository};
    use crate::services::ContextService;

    async fn make_engine(
        pool: sqlx::SqlitePool,
        with_learning: bool,
    ) -> (
        RecommendationEngine,
        Option<std::sync::Arc<crate::learning::engine::AdaptiveLearningEngine>>,
        crate::repositories::WorkspaceRepository,
        crate::repositories::FileRepository,
    ) {
        let ws_repo = WorkspaceRepository::new(pool.clone());
        let file_repo = FileRepository::new(pool.clone());
        let tl_repo = TimelineRepository::new(pool.clone());
        let settings_repo = crate::repositories::SettingsRepository::new(pool.clone());
        let ctx = ContextService::new(
            crate::session::SessionEngine::new(tl_repo.clone(), file_repo.clone()),
            ws_repo.clone(),
            settings_repo,
        );
        let engine = RecommendationEngine::new(ws_repo.clone(), file_repo.clone(), ctx);
        if with_learning {
            let learning_repo = crate::learning::repository::LearningRepository::new(pool.clone());
            let learning =
                std::sync::Arc::new(crate::learning::engine::AdaptiveLearningEngine::new(
                    std::sync::Arc::new(learning_repo),
                ));
            let eng_with = engine.clone().with_learning_engine(learning.clone());
            (eng_with, Some(learning), ws_repo, file_repo)
        } else {
            (engine, None, ws_repo, file_repo)
        }
    }

    #[tokio::test]
    async fn no_learning_history_is_deterministic() {
        let (db, _guard) = test_database().await;
        let pool = db.pool().clone();
        let (engine, _, ws_repo, _) = make_engine(pool, false).await;
        let ws = ws_repo
            .create(crate::models::CreateWorkspaceInput {
                name: "ws".into(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();
        let first = engine.generate_recommendations(ws.id).await.unwrap();
        let second = engine.generate_recommendations(ws.id).await.unwrap();
        assert_eq!(
            first.iter().map(|r| &r.id).collect::<Vec<_>>(),
            second.iter().map(|r| &r.id).collect::<Vec<_>>()
        );
        assert_eq!(
            first.iter().map(|r| r.confidence).collect::<Vec<_>>(),
            second.iter().map(|r| r.confidence).collect::<Vec<_>>()
        );
    }

    #[tokio::test]
    async fn scoring_formula_unchanged() {
        let engine = RecommendationScoringEngine::new();
        let mut rec = crate::intelligence::recommendation::models::Recommendation::new(
            "ws".into(),
            crate::intelligence::recommendation::models::RecommendationCategory::Productivity,
            "t",
            "d",
        );
        rec.confidence = 0.8;
        rec.impact = 0.9;
        rec.effort = 0.2;
        let scored = engine.score_recommendation(rec);
        // (0.8*0.9 - 0.2*0.3)=0.72-0.06=0.66 → High
        assert_eq!(
            scored.priority,
            crate::intelligence::recommendation::models::RecommendationPriority::High
        );
    }

    #[tokio::test]
    async fn learning_adjusts_recommendation_confidence() {
        let (db, _guard) = test_database().await;
        let pool = db.pool().clone();
        // Engine without learning (baseline) — need a workspace that triggers a rec
        let (engine_plain, _, ws_repo, file_repo) = make_engine(pool.clone(), false).await;
        let ws = ws_repo
            .create(crate::models::CreateWorkspaceInput {
                name: "ws".into(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();
        // Create 2 files to trigger "Small workspace with low activity" (1-4 files, <10 events)
        for i in 0..2 {
            file_repo
                .create(crate::models::NewFile {
                    workspace_id: ws.id,
                    artifact_type: crate::models::ArtifactType::File,
                    file_identifier: None,
                path_or_url: format!("/tmp/ws/file{}.rs", i),
                    content_hash: None,
                })
                .await
                .unwrap();
        }
        let baseline = engine_plain.generate_recommendations(ws.id).await.unwrap();
        assert!(
            !baseline.is_empty(),
            "should generate at least one rec (small workspace)"
        );
        let target = &baseline[0];
        let base_conf = target.confidence;

        // Engine with learning — record accepted feedback for that exact recommendation id
        let (engine_learn, learning_opt, _, _) = make_engine(pool.clone(), true).await;
        let learning = learning_opt.unwrap();
        learning
            .record_feedback(
                FeedbackType::Recommendation,
                FeedbackTargetType::Recommendation,
                target.id.clone(),
                FeedbackAction::Accepted,
                serde_json::json!({"category": format!("{:?}", target.category), "confidence": base_conf}),
            )
            .await
            .unwrap();

        let adjusted = engine_learn.generate_recommendations(ws.id).await.unwrap();
        let updated = adjusted
            .iter()
            .find(|r| r.id == target.id)
            .expect("same deterministic id must exist");
        assert!(
            updated.confidence > base_conf,
            "accepted feedback should increase confidence: {} -> {}",
            base_conf,
            updated.confidence
        );
        assert!(updated.confidence <= 1.0);
    }

    #[tokio::test]
    async fn rejected_feedback_decreases_confidence() {
        let (db, _guard) = test_database().await;
        let pool = db.pool().clone();
        let (engine_plain, _, ws_repo, file_repo) = make_engine(pool.clone(), false).await;
        let ws = ws_repo
            .create(crate::models::CreateWorkspaceInput {
                name: "ws".into(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();
        for i in 0..2 {
            file_repo
                .create(crate::models::NewFile {
                    workspace_id: ws.id,
                    artifact_type: crate::models::ArtifactType::File,
                    file_identifier: None,
                path_or_url: format!("/tmp/ws/file{}.rs", i),
                    content_hash: None,
                })
                .await
                .unwrap();
        }
        let baseline = engine_plain.generate_recommendations(ws.id).await.unwrap();
        assert!(!baseline.is_empty());
        let target = &baseline[0];
        let base_conf = target.confidence;

        let (engine_learn, learning_opt, _, _) = make_engine(pool.clone(), true).await;
        let learning = learning_opt.unwrap();
        learning
            .record_feedback(
                FeedbackType::Recommendation,
                FeedbackTargetType::Recommendation,
                target.id.clone(),
                FeedbackAction::Rejected,
                serde_json::json!({"category": format!("{:?}", target.category), "confidence": base_conf}),
            )
            .await
            .unwrap();
        let adjusted = engine_learn.generate_recommendations(ws.id).await.unwrap();
        let updated = adjusted.iter().find(|r| r.id == target.id).unwrap();
        assert!(
            updated.confidence < base_conf,
            "rejected should decrease: {} -> {}",
            base_conf,
            updated.confidence
        );
    }
}
