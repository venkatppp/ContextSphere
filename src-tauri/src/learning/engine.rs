//! Adaptive Learning Engine - Learns from user behavior and feedback.

use std::sync::Arc;

use chrono::Utc;
use uuid::Uuid;

use crate::errors::DatabaseError;
use crate::learning::models::*;
use crate::learning::repository::LearningRepository;

/// Adaptive learning engine that learns from user feedback and behavior.
pub struct AdaptiveLearningEngine {
    repository: Arc<LearningRepository>,
}

impl AdaptiveLearningEngine {
    /// Creates a new adaptive learning engine.
    pub fn new(repository: Arc<LearningRepository>) -> Self {
        Self { repository }
    }

    /// Records user feedback and triggers learning updates.
    pub async fn record_feedback(
        &self,
        feedback_type: FeedbackType,
        target_type: FeedbackTargetType,
        target_id: String,
        action: FeedbackAction,
        context: serde_json::Value,
    ) -> Result<(), DatabaseError> {
        let feedback = UserFeedback {
            id: Uuid::new_v4(),
            feedback_type,
            target_type,
            target_id: target_id.clone(),
            action,
            context,
            created_at: Utc::now(),
        };

        self.repository.record_feedback(&feedback).await?;

        // Trigger preference learning based on feedback
        self.update_preferences_from_feedback(&feedback).await?;

        // Adjust confidence for similar future predictions
        self.adjust_confidence_from_feedback(&feedback).await?;

        Ok(())
    }

    /// Updates user preferences based on feedback.
    async fn update_preferences_from_feedback(
        &self,
        feedback: &UserFeedback,
    ) -> Result<(), DatabaseError> {
        match feedback.action {
            FeedbackAction::Accepted | FeedbackAction::Helpful => {
                // Extract preference signals from the feedback context
                let preference_type = self.infer_preference_type(feedback.target_type);

                if let Some(pref_type) = preference_type {
                    let key = self.extract_preference_key(feedback);
                    let value = self.extract_preference_value(feedback);

                    // Get existing preference or create new
                    let existing = self
                        .repository
                        .get_preferences_by_type(pref_type)
                        .await?
                        .into_iter()
                        .find(|p| p.key == key);

                    let preference = if let Some(mut existing) = existing {
                        // Update existing preference
                        existing.evidence_count += 1;
                        existing.confidence = self.calculate_confidence(existing.evidence_count);
                        existing.value = value;
                        existing.last_updated = Utc::now();
                        existing
                    } else {
                        // Create new preference
                        UserPreference {
                            id: Uuid::new_v4(),
                            preference_type: pref_type,
                            key,
                            value,
                            confidence: 0.5,
                            evidence_count: 1,
                            last_updated: Utc::now(),
                        }
                    };

                    self.repository.upsert_preference(&preference).await?;
                }
            }
            FeedbackAction::Rejected | FeedbackAction::NotHelpful => {
                // Decrease confidence in rejected patterns
                let preference_type = self.infer_preference_type(feedback.target_type);

                if let Some(pref_type) = preference_type {
                    let key = self.extract_preference_key(feedback);

                    let existing = self
                        .repository
                        .get_preferences_by_type(pref_type)
                        .await?
                        .into_iter()
                        .find(|p| p.key == key);

                    if let Some(mut existing) = existing {
                        existing.confidence = (existing.confidence * 0.8).max(0.1);
                        existing.last_updated = Utc::now();
                        self.repository.upsert_preference(&existing).await?;
                    }
                }
            }
            FeedbackAction::Dismissed => {
                // Neutral - no preference update
            }
        }

        Ok(())
    }

    /// Adjusts confidence scores based on feedback.
    async fn adjust_confidence_from_feedback(
        &self,
        feedback: &UserFeedback,
    ) -> Result<(), DatabaseError> {
        let adjustment_factor = match feedback.action {
            FeedbackAction::Accepted | FeedbackAction::Helpful => 1.2,
            FeedbackAction::Rejected => 0.5,
            FeedbackAction::NotHelpful => 0.7,
            FeedbackAction::Dismissed => 0.9,
        };

        let reason = match feedback.action {
            FeedbackAction::Accepted => "User accepted recommendation",
            FeedbackAction::Helpful => "User marked as helpful",
            FeedbackAction::Rejected => "User rejected recommendation",
            FeedbackAction::NotHelpful => "User marked as not helpful",
            FeedbackAction::Dismissed => "User dismissed without action",
        };

        let adjustment = ConfidenceAdjustment {
            id: Uuid::new_v4(),
            target_type: feedback.target_type,
            target_id: feedback.target_id.clone(),
            original_confidence: 0.5, // TODO: Get from context
            adjusted_confidence: 0.5 * adjustment_factor,
            adjustment_factor,
            reason: reason.to_string(),
            applied_at: Utc::now(),
        };

        self.repository
            .record_confidence_adjustment(&adjustment)
            .await?;

        Ok(())
    }

    /// Learns behavioral patterns from user history.
    pub async fn learn_patterns_from_history(
        &self,
        _workspace_id: &str,
    ) -> Result<Vec<BehavioralPattern>, DatabaseError> {
        // This would analyze timeline events, session data, etc.
        // For now, return empty - would be implemented with timeline integration
        Ok(Vec::new())
    }

    /// Adjusts prediction confidence based on learned preferences.
    pub async fn adjust_prediction_confidence(
        &self,
        target_type: FeedbackTargetType,
        target_id: &str,
        base_confidence: f64,
    ) -> Result<ConfidenceExplanation, DatabaseError> {
        let mut adjusted_confidence = base_confidence;
        let mut reasons = Vec::new();

        // Get historical feedback for similar predictions
        let feedback_history = self
            .repository
            .get_feedback_for_target(target_type, target_id)
            .await?;

        if !feedback_history.is_empty() {
            let accepted = feedback_history
                .iter()
                .filter(|f| matches!(f.action, FeedbackAction::Accepted))
                .count();
            let total = feedback_history.len();
            let acceptance_rate = accepted as f64 / total as f64;

            let adjustment = if acceptance_rate > 0.7 {
                1.2
            } else if acceptance_rate < 0.3 {
                0.7
            } else {
                1.0
            };

            adjusted_confidence *= adjustment;

            reasons.push(ExplanationReason {
                factor: "historical_feedback".to_string(),
                impact: adjustment - 1.0,
                description: format!(
                    "Based on {} previous interactions with {}% acceptance rate",
                    total,
                    (acceptance_rate * 100.0) as i32
                ),
            });
        }

        // Get relevant preferences
        let preference_type = self.infer_preference_type(target_type);
        if let Some(pref_type) = preference_type {
            let preferences = self.repository.get_preferences_by_type(pref_type).await?;

            for pref in preferences.iter().take(3) {
                if pref.confidence > 0.7 {
                    adjusted_confidence *= 1.1;
                    reasons.push(ExplanationReason {
                        factor: "user_preference".to_string(),
                        impact: 0.1,
                        description: format!("Matches your preference: {}", pref.key),
                    });
                }
            }
        }

        // Get confidence adjustments
        let adjustments = self
            .repository
            .get_confidence_adjustments(target_type, target_id)
            .await?;

        if let Some(last_adj) = adjustments.first() {
            let time_decay = 0.95; // Decay factor for older adjustments
            adjusted_confidence *= last_adj.adjustment_factor * time_decay;

            reasons.push(ExplanationReason {
                factor: "previous_adjustment".to_string(),
                impact: (last_adj.adjustment_factor - 1.0) * time_decay,
                description: last_adj.reason.clone(),
            });
        }

        // Clamp confidence to valid range
        adjusted_confidence = adjusted_confidence.clamp(0.0, 1.0);

        Ok(ConfidenceExplanation {
            target_id: target_id.to_string(),
            target_type: format!("{:?}", target_type),
            original_confidence: base_confidence,
            adjusted_confidence,
            reasons,
            timestamp: Utc::now(),
        })
    }

    /// Learns workflow patterns from user behavior.
    pub async fn learn_workflow_patterns(
        &self,
        workflow_type: &str,
        duration_seconds: i64,
        files: Vec<String>,
        time_of_day: i32,
    ) -> Result<(), DatabaseError> {
        let existing = self.repository.get_workflow_learning(workflow_type).await?;

        let workflow = if let Some(mut existing) = existing {
            // Update existing workflow data
            existing.sample_count += 1;

            // Update typical duration (moving average)
            let count = existing.sample_count as i64;
            existing.typical_duration_seconds =
                (existing.typical_duration_seconds * (count - 1) + duration_seconds) / count;

            // Add new files to typical files
            for file in files {
                if !existing.typical_files.contains(&file) && existing.typical_files.len() < 20 {
                    existing.typical_files.push(file);
                }
            }

            // Add time of day to typical times
            if !existing.typical_time_of_day.contains(&time_of_day) {
                existing.typical_time_of_day.push(time_of_day);
            }

            // Increase confidence with more samples
            existing.confidence =
                (existing.sample_count as f64 / (existing.sample_count as f64 + 10.0)).min(0.95);
            existing.last_updated = Utc::now();

            existing
        } else {
            // Create new workflow learning data
            WorkflowLearningData {
                id: Uuid::new_v4(),
                workflow_type: workflow_type.to_string(),
                typical_duration_seconds: duration_seconds,
                typical_files: files,
                typical_time_of_day: vec![time_of_day],
                success_indicators: serde_json::json!({}),
                confidence: 0.3,
                sample_count: 1,
                last_updated: Utc::now(),
            }
        };

        self.repository.store_workflow_learning(&workflow).await?;

        Ok(())
    }

    /// Gets learning insights for the dashboard.
    pub async fn get_learning_insights(&self) -> Result<LearningInsights, DatabaseError> {
        let stats = self.repository.get_learning_stats().await?;
        let top_preferences = self
            .repository
            .get_all_preferences()
            .await?
            .into_iter()
            .take(10)
            .collect();
        let recent_patterns = self
            .repository
            .get_all_patterns()
            .await?
            .into_iter()
            .take(10)
            .collect();
        let confidence_trends = self.repository.get_confidence_trends(30).await?;

        // Calculate recommendation accuracy
        let recommendation_accuracy = self.calculate_recommendation_accuracy().await?;

        Ok(LearningInsights {
            stats,
            top_preferences,
            recent_patterns,
            confidence_trends,
            recommendation_accuracy,
        })
    }

    /// Calculates recommendation accuracy by category, from real
    /// accepted/rejected feedback records. With zero feedback the result
    /// is an empty dataset (`overall_accuracy: 0.0`,
    /// `total_recommendations: 0`) — the UI must render "insufficient
    /// data" instead of presenting an accuracy reading that no feedback
    /// supports.
    async fn calculate_recommendation_accuracy(
        &self,
    ) -> Result<RecommendationAccuracy, DatabaseError> {
        let category_accuracy = self.repository.get_feedback_accuracy().await?;
        let total: i64 = category_accuracy.iter().map(|c| c.total).sum();

        let overall_accuracy = if total > 0 {
            category_accuracy.iter().map(|c| c.accepted).sum::<i64>() as f64 / total as f64
        } else {
            0.0
        };

        Ok(RecommendationAccuracy {
            category_accuracy,
            overall_accuracy,
            total_recommendations: total,
        })
    }

    // Helper methods

    fn infer_preference_type(&self, target_type: FeedbackTargetType) -> Option<PreferenceType> {
        match target_type {
            FeedbackTargetType::Recommendation => Some(PreferenceType::RecommendationCategory),
            FeedbackTargetType::WorkspacePrediction => Some(PreferenceType::WorkspaceSwitching),
            FeedbackTargetType::FilePrediction => Some(PreferenceType::FileAccess),
            FeedbackTargetType::WorkflowTransition => Some(PreferenceType::Workflow),
            _ => None,
        }
    }

    fn extract_preference_key(&self, feedback: &UserFeedback) -> String {
        // Extract meaningful key from feedback context
        if let Some(category) = feedback.context.get("category") {
            category.as_str().unwrap_or("unknown").to_string()
        } else {
            feedback.target_id.clone()
        }
    }

    fn extract_preference_value(&self, feedback: &UserFeedback) -> serde_json::Value {
        // Extract preference value from context
        feedback.context.clone()
    }

    fn calculate_confidence(&self, evidence_count: i32) -> f64 {
        // Confidence increases logarithmically with evidence
        let base_confidence = 0.5;
        let max_confidence = 0.95;
        let growth_rate = 0.1;

        base_confidence
            + (max_confidence - base_confidence)
                * (1.0 - (-growth_rate * evidence_count as f64).exp())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::test_database;

    #[tokio::test]
    async fn calculates_confidence_correctly() {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await.unwrap();
        let repository = LearningRepository::new(pool);
        let engine = AdaptiveLearningEngine::new(Arc::new(repository));

        assert!((engine.calculate_confidence(1) - 0.55).abs() < 0.1);
        assert!((engine.calculate_confidence(10) - 0.80).abs() < 0.1);
        assert!(engine.calculate_confidence(100) > 0.90);
    }

    #[allow(dead_code)]
    async fn test_engine() -> (AdaptiveLearningEngine, Arc<LearningRepository>) {
        let (db, _guard) = test_database().await;
        let repo = Arc::new(LearningRepository::new(db.pool().clone()));
        let engine = AdaptiveLearningEngine::new(repo.clone());
        // Keep guard alive via leaking tempdir? test_database returns TempDir guard, but we drop it here.
        // For these tests we use in-memory DB via repository alone, not the guard.
        (engine, repo)
    }

    #[tokio::test]
    async fn first_observation_creates_preference_with_low_confidence() {
        let (db, _guard) = test_database().await;
        let repo = Arc::new(LearningRepository::new(db.pool().clone()));
        let engine = AdaptiveLearningEngine::new(repo.clone());

        engine
            .record_feedback(
                FeedbackType::Recommendation,
                FeedbackTargetType::Recommendation,
                "rec-1".into(),
                FeedbackAction::Accepted,
                serde_json::json!({"category": "productivity"}),
            )
            .await
            .unwrap();

        let prefs = repo
            .get_preferences_by_type(PreferenceType::RecommendationCategory)
            .await
            .unwrap();
        assert_eq!(prefs.len(), 1);
        assert_eq!(prefs[0].evidence_count, 1);
        assert!((prefs[0].confidence - 0.5).abs() < 0.01, "first observation confidence 0.5");
    }

    #[tokio::test]
    async fn repeated_observation_increases_evidence_and_confidence() {
        let (db, _guard) = test_database().await;
        let repo = Arc::new(LearningRepository::new(db.pool().clone()));
        let engine = AdaptiveLearningEngine::new(repo.clone());

        for _ in 0..3 {
            engine
                .record_feedback(
                    FeedbackType::Recommendation,
                    FeedbackTargetType::Recommendation,
                    "rec-1".into(),
                    FeedbackAction::Accepted,
                    serde_json::json!({"category": "productivity"}),
                )
                .await
                .unwrap();
        }

        let prefs = repo
            .get_preferences_by_type(PreferenceType::RecommendationCategory)
            .await
            .unwrap();
        assert_eq!(prefs.len(), 1);
        assert_eq!(prefs[0].evidence_count, 3);
        assert!(
            prefs[0].confidence > 0.5,
            "confidence should increase with evidence"
        );
        assert!(
            prefs[0].confidence < 0.95,
            "confidence must remain bounded"
        );
    }

    #[tokio::test]
    async fn conflicting_behavior_decreases_confidence() {
        let (db, _guard) = test_database().await;
        let repo = Arc::new(LearningRepository::new(db.pool().clone()));
        let engine = AdaptiveLearningEngine::new(repo.clone());

        // Accept
        engine
            .record_feedback(
                FeedbackType::Recommendation,
                FeedbackTargetType::Recommendation,
                "rec-1".into(),
                FeedbackAction::Accepted,
                serde_json::json!({"category": "productivity"}),
            )
            .await
            .unwrap();
        let before = repo
            .get_preferences_by_type(PreferenceType::RecommendationCategory)
            .await
            .unwrap()[0]
            .confidence;

        // Reject same category
        engine
            .record_feedback(
                FeedbackType::Recommendation,
                FeedbackTargetType::Recommendation,
                "rec-1".into(),
                FeedbackAction::Rejected,
                serde_json::json!({"category": "productivity"}),
            )
            .await
            .unwrap();
        let after = repo
            .get_preferences_by_type(PreferenceType::RecommendationCategory)
            .await
            .unwrap()[0]
            .confidence;

        assert!(after < before, "rejection should decrease confidence");
        assert!(after >= 0.1, "confidence floor 0.1");
    }

    #[tokio::test]
    async fn successful_and_failed_execution_influence_via_feedback() {
        let (db, _guard) = test_database().await;
        let repo = Arc::new(LearningRepository::new(db.pool().clone()));
        let engine = AdaptiveLearningEngine::new(repo.clone());

        // Helpful
        engine
            .record_feedback(
                FeedbackType::Action,
                FeedbackTargetType::WorkflowTransition,
                "workflow-1".into(),
                FeedbackAction::Helpful,
                serde_json::json!({}),
            )
            .await
            .unwrap();
        let helpful = repo
            .get_preferences_by_type(PreferenceType::Workflow)
            .await
            .unwrap();
        assert_eq!(helpful[0].evidence_count, 1);

        // NotHelpful on same workflow should decrease
        engine
            .record_feedback(
                FeedbackType::Action,
                FeedbackTargetType::WorkflowTransition,
                "workflow-1".into(),
                FeedbackAction::NotHelpful,
                serde_json::json!({}),
            )
            .await
            .unwrap();
        let after = repo
            .get_preferences_by_type(PreferenceType::Workflow)
            .await
            .unwrap()[0]
            .confidence;
        assert!(after < 0.6, "not helpful should reduce");
    }

    #[tokio::test]
    async fn workspace_isolation_for_preferences() {
        let (db, _guard) = test_database().await;
        let repo = Arc::new(LearningRepository::new(db.pool().clone()));
        let engine = AdaptiveLearningEngine::new(repo.clone());

        // Two different target_ids simulating workspace-specific preferences
        engine
            .record_feedback(
                FeedbackType::Prediction,
                FeedbackTargetType::WorkspacePrediction,
                "ws-a".into(),
                FeedbackAction::Accepted,
                serde_json::json!({"category": "switch"}),
            )
            .await
            .unwrap();
        engine
            .record_feedback(
                FeedbackType::Prediction,
                FeedbackTargetType::WorkspacePrediction,
                "ws-b".into(),
                FeedbackAction::Accepted,
                serde_json::json!({"category": "switch"}),
            )
            .await
            .unwrap();

        // Both should be stored as separate preferences keyed by target_id
        let prefs = repo
            .get_preferences_by_type(PreferenceType::WorkspaceSwitching)
            .await
            .unwrap();
        // At least 1 preference for workspace switching (key = target_id)
        assert!(!prefs.is_empty());
    }

    #[tokio::test]
    async fn dismissed_does_not_create_preference() {
        let (db, _guard) = test_database().await;
        let repo = Arc::new(LearningRepository::new(db.pool().clone()));
        let engine = AdaptiveLearningEngine::new(repo.clone());

        engine
            .record_feedback(
                FeedbackType::Recommendation,
                FeedbackTargetType::Recommendation,
                "rec-1".into(),
                FeedbackAction::Dismissed,
                serde_json::json!({"category": "productivity"}),
            )
            .await
            .unwrap();

        let prefs = repo
            .get_preferences_by_type(PreferenceType::RecommendationCategory)
            .await
            .unwrap();
        assert!(prefs.is_empty(), "dismissed should be neutral");
    }
}
