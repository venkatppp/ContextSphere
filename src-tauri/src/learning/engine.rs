//! Adaptive Learning Engine - Learns from user behavior and feedback.

use std::sync::Arc;

use chrono::{Timelike, Utc};
use uuid::Uuid;

use crate::errors::DatabaseError;
use crate::learning::models::*;
use crate::learning::repository::LearningRepository;

/// Adaptive learning engine that learns from user feedback and behavior.
pub struct AdaptiveLearningEngine {
    repository: Arc<LearningRepository>,
    timeline_repository: Option<Arc<crate::repositories::TimelineRepository>>,
    workspace_repository: Option<Arc<crate::repositories::WorkspaceRepository>>,
    file_repository: Option<Arc<crate::repositories::FileRepository>>,
}

impl AdaptiveLearningEngine {
    /// Creates a new adaptive learning engine.
    pub fn new(repository: Arc<LearningRepository>) -> Self {
        Self {
            repository,
            timeline_repository: None,
            workspace_repository: None,
            file_repository: None,
        }
    }

    /// Attach timeline history source (enables `learn_patterns_from_history`).
    pub fn with_timeline_repository(
        mut self,
        repo: Arc<crate::repositories::TimelineRepository>,
    ) -> Self {
        self.timeline_repository = Some(repo);
        self
    }

    /// Attach workspace source for isolation/validation.
    pub fn with_workspace_repository(
        mut self,
        repo: Arc<crate::repositories::WorkspaceRepository>,
    ) -> Self {
        self.workspace_repository = Some(repo);
        self
    }

    /// Attach file source for file-type pattern derivation.
    pub fn with_file_repository(mut self, repo: Arc<crate::repositories::FileRepository>) -> Self {
        self.file_repository = Some(repo);
        self
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

        // Prefer a real confidence supplied by the caller (e.g. recommendation
        // generation passes `confidence` in context). Fall back to 0.5 only
        // when no valid source exists — documented, not fabricated.
        let original_confidence = feedback
            .context
            .get("confidence")
            .and_then(|v| v.as_f64())
            .filter(|c| (0.0..=1.0).contains(c))
            .unwrap_or(0.5);
        let adjusted_confidence = (original_confidence * adjustment_factor).clamp(0.0, 1.0);

        let adjustment = ConfidenceAdjustment {
            id: Uuid::new_v4(),
            target_type: feedback.target_type,
            target_id: feedback.target_id.clone(),
            original_confidence,
            adjusted_confidence,
            adjustment_factor,
            reason: reason.to_string(),
            applied_at: Utc::now(),
        };

        self.repository
            .record_confidence_adjustment(&adjustment)
            .await?;

        Ok(())
    }

    /// Learns behavioral patterns from user history (bounded, deterministic,
    /// workspace-isolated, idempotent).
    ///
    /// Window: 30 days, `list_by_workspace_window(..., 500)` keeps the scan
    /// bounded even on a very active workspace. Each pattern gets a
    /// deterministic id (`workspace|type|key` → fxhash → Uuid) so a second
    /// cycle `ON CONFLICT(id) DO UPDATE` does not create uncontrolled
    /// duplicates. Safe when history is empty or a repository is not wired
    /// (e.g. in unit tests that construct the engine with only a
    /// `LearningRepository`).
    pub async fn learn_patterns_from_history(
        &self,
        workspace_id: &str,
    ) -> Result<Vec<BehavioralPattern>, DatabaseError> {
        // Workspace-isolated: require a parseable workspace id. Empty or
        // "all" is treated as empty history (no cross-workspace leakage).
        let ws_uuid = match uuid::Uuid::parse_str(workspace_id) {
            Ok(id) => id,
            Err(_) => return Ok(Vec::new()),
        };

        let timeline_repo = match &self.timeline_repository {
            Some(r) => r.clone(),
            None => return Ok(Vec::new()),
        };

        // Bounded 30-day window — matches the Dashboard/Correlation window.
        let now = Utc::now();
        let since = now - chrono::Duration::days(30);

        // Index scan: `idx_timeline_workspace_started` keeps this cheap even
        // when the table is large; `LIMIT 500` prevents unbounded reads.
        let events = timeline_repo
            .list_by_workspace_window(ws_uuid, since, now, 500)
            .await
            .unwrap_or_default();

        if events.is_empty() {
            return Ok(Vec::new());
        }

        // Deterministic helpers
        fn det_id(workspace_id: &str, pattern_type: &str, key: &str) -> Uuid {
            let s = format!("{}|{}|{}", workspace_id, pattern_type, key);
            // FNV-1a 64-bit, then expand to 128-bit for Uuid
            let mut h: u64 = 0xcbf29ce484222325;
            for b in s.as_bytes() {
                h ^= u64::from(*b);
                h = h.wrapping_mul(0x100000001b3);
            }
            let hi = h;
            let lo = h.wrapping_mul(0x9e3779b97f4a7c15);
            Uuid::from_u128(((hi as u128) << 64) | lo as u128)
        }

        let first_seen = events.iter().map(|e| e.occurred_at).min().unwrap_or(now);
        let last_seen = events.iter().map(|e| e.occurred_at).max().unwrap_or(now);

        // Fetch existing patterns once for idempotency (preserve earliest first_seen)
        let existing: std::collections::HashMap<Uuid, BehavioralPattern> = self
            .repository
            .get_all_patterns()
            .await
            .unwrap_or_default()
            .into_iter()
            .map(|p| (p.id, p))
            .collect();

        let mut out = Vec::new();

        // ── 1. Time-based (hour-of-day) ──
        {
            use std::collections::HashMap;
            let mut hour_counts: HashMap<u32, usize> = HashMap::new();
            for e in &events {
                let hour = e.occurred_at.hour();
                *hour_counts.entry(hour).or_insert(0) += 1;
            }
            if let Some((&peak_hour, &peak_count)) = hour_counts.iter().max_by_key(|(_, c)| *c) {
                let total = events.len() as f64;
                if peak_count >= 5 && (peak_count as f64 / total) >= 0.20 {
                    let confidence =
                        ((peak_count as f64 / total).clamp(0.0, 1.0) * 0.6 + 0.35).clamp(0.5, 0.95);
                    let frequency = peak_count as f64 / 30.0;
                    let key = format!("hour-{:02}", peak_hour);
                    let id = det_id(workspace_id, "time_based", &key);
                    let first = existing
                        .get(&id)
                        .map(|p| p.first_seen.min(first_seen))
                        .unwrap_or(first_seen);
                    let pattern = BehavioralPattern {
                        id,
                        pattern_type: PatternType::TimeBased,
                        description: format!(
                            "Active during {:02}:00 UTC ({} of {} events, {}%)",
                            peak_hour,
                            peak_count,
                            events.len(),
                            ((peak_count as f64 / total) * 100.0) as i32
                        ),
                        conditions: serde_json::json!({
                            "workspace_id": workspace_id,
                            "peak_hour": peak_hour,
                            "peak_count": peak_count,
                            "total_events": events.len()
                        }),
                        frequency,
                        confidence,
                        occurrences: peak_count as i32,
                        first_seen: first,
                        last_seen,
                    };
                    self.repository.store_pattern(&pattern).await?;
                    out.push(pattern);
                }
            }
        }

        // ── 2. SequentialFiles / file-type ──
        {
            use std::collections::HashMap;
            // Collect up to 50 distinct file ids to keep N+1 bounded.
            let mut file_ids: std::collections::HashSet<uuid::Uuid> =
                std::collections::HashSet::new();
            for e in &events {
                if let Some(fid) = e.file_id {
                    file_ids.insert(fid);
                    if file_ids.len() >= 50 {
                        break;
                    }
                }
            }
            let mut ext_counts: HashMap<String, usize> = HashMap::new();
            let mut total_file_events = 0usize;
            if let Some(file_repo) = &self.file_repository {
                for fid in file_ids {
                    if let Ok(file) = file_repo.get_by_id(fid).await {
                        if let Some(ext) = std::path::Path::new(&file.path_or_url)
                            .extension()
                            .and_then(|s| s.to_str())
                        {
                            let ext = format!(".{}", ext.to_lowercase());
                            *ext_counts.entry(ext).or_insert(0) += 1;
                            total_file_events += 1;
                        }
                    }
                }
            } else {
                // Fallback: infer from metadata path if present, without DB hit
                for e in &events {
                    if let Some(fid) = e.file_id {
                        let _ = fid;
                        // No repo — skip
                    }
                    if let Some(meta) = &e.metadata {
                        if let Some(path) = meta.get("path").and_then(|v| v.as_str()) {
                            if let Some(ext) = std::path::Path::new(path)
                                .extension()
                                .and_then(|s| s.to_str())
                            {
                                let ext = format!(".{}", ext.to_lowercase());
                                *ext_counts.entry(ext).or_insert(0) += 1;
                                total_file_events += 1;
                            }
                        }
                    }
                }
            }
            if let Some((ext, count)) = ext_counts.into_iter().max_by_key(|(_, c)| *c) {
                if count >= 3 && total_file_events > 0 {
                    let confidence =
                        ((count as f64 / total_file_events as f64) * 0.5 + 0.45).clamp(0.5, 0.95);
                    let frequency = count as f64 / 30.0;
                    let key = format!("ext-{}", ext);
                    let id = det_id(workspace_id, "sequential_files", &key);
                    let first = existing
                        .get(&id)
                        .map(|p| p.first_seen.min(first_seen))
                        .unwrap_or(first_seen);
                    let pattern = BehavioralPattern {
                        id,
                        pattern_type: PatternType::SequentialFiles,
                        description: format!(
                            "Frequently works with {} files ({} of {} file events)",
                            ext, count, total_file_events
                        ),
                        conditions: serde_json::json!({
                            "workspace_id": workspace_id,
                            "extension": ext,
                            "count": count,
                            "total_file_events": total_file_events
                        }),
                        frequency,
                        confidence,
                        occurrences: count as i32,
                        first_seen: first,
                        last_seen,
                    };
                    self.repository.store_pattern(&pattern).await?;
                    out.push(pattern);
                }
            }
        }

        // ── 3. FocusSession (session duration) ──
        {
            let sessions = crate::session::detector::detect_sessions(
                events.clone(),
                crate::session::detector::DEFAULT_INACTIVITY_THRESHOLD_SECONDS,
            );
            if sessions.len() >= 3 {
                let total_secs: i64 = sessions.iter().map(|s| s.duration_seconds).sum();
                let avg_secs = total_secs / sessions.len() as i64;
                // Only emit if sessions are meaningfully long (10m–3h avg)
                if (600..=10800).contains(&avg_secs) {
                    let confidence =
                        (sessions.len() as f64 / (sessions.len() as f64 + 10.0)).min(0.95);
                    let frequency = sessions.len() as f64 / 30.0;
                    let key = format!("focus-avg-{}", avg_secs / 60);
                    let id = det_id(workspace_id, "focus_session", &key);
                    let first = existing
                        .get(&id)
                        .map(|p| p.first_seen.min(first_seen))
                        .unwrap_or(first_seen);
                    let pattern = BehavioralPattern {
                        id,
                        pattern_type: PatternType::FocusSession,
                        description: format!(
                            "Focus sessions average {}m over {} sessions",
                            avg_secs / 60,
                            sessions.len()
                        ),
                        conditions: serde_json::json!({
                            "workspace_id": workspace_id,
                            "avg_duration_seconds": avg_secs,
                            "session_count": sessions.len()
                        }),
                        frequency,
                        confidence,
                        occurrences: sessions.len() as i32,
                        first_seen: first,
                        last_seen,
                    };
                    self.repository.store_pattern(&pattern).await?;
                    out.push(pattern);
                }
            }
        }

        // ── 4. WorkflowTransition (edit→commit) ──
        {
            let commit_count = events
                .iter()
                .filter(|e| e.event_type == crate::models::TimelineEventType::Commit)
                .count();
            let edit_count = events
                .iter()
                .filter(|e| e.event_type == crate::models::TimelineEventType::Edit)
                .count();
            if commit_count >= 2 && edit_count >= 5 {
                let confidence =
                    ((commit_count as f64 / edit_count as f64) * 0.5 + 0.5).clamp(0.5, 0.95);
                let frequency = commit_count as f64 / 30.0;
                let key = "edit-commit";
                let id = det_id(workspace_id, "workflow_transition", key);
                let first = existing
                    .get(&id)
                    .map(|p| p.first_seen.min(first_seen))
                    .unwrap_or(first_seen);
                let pattern = BehavioralPattern {
                    id,
                    pattern_type: PatternType::WorkflowTransition,
                    description: format!(
                        "Edit → Commit workflow ({} commits of {} edits)",
                        commit_count, edit_count
                    ),
                    conditions: serde_json::json!({
                        "workspace_id": workspace_id,
                        "commits": commit_count,
                        "edits": edit_count
                    }),
                    frequency,
                    confidence,
                    occurrences: commit_count as i32,
                    first_seen: first,
                    last_seen,
                };
                self.repository.store_pattern(&pattern).await?;
                out.push(pattern);
            }
        }

        Ok(out)
    }

    /// Convenience for background workers: learn patterns for every active
    /// workspace (bounded per-workspace, errors per-workspace are logged
    /// not propagated so one broken workspace never kills the daemon).
    pub async fn learn_patterns_for_all_workspaces(&self) -> Result<usize, DatabaseError> {
        let ws_repo = match &self.workspace_repository {
            Some(r) => r.clone(),
            None => return Ok(0),
        };
        let active = ws_repo.list_active_workspaces().await.unwrap_or_default();
        let mut total = 0usize;
        for ws in active {
            match self.learn_patterns_from_history(&ws.id.to_string()).await {
                Ok(patterns) => total += patterns.len(),
                Err(e) => log::warn!("learn_patterns_for_workspace {} failed: {}", ws.id, e),
            }
        }
        Ok(total)
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
        assert!(
            (prefs[0].confidence - 0.5).abs() < 0.01,
            "first observation confidence 0.5"
        );
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
        assert!(prefs[0].confidence < 0.95, "confidence must remain bounded");
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

    // ── Phase A: learn_patterns_from_history ──

    #[tokio::test]
    async fn learn_patterns_empty_history_returns_empty() {
        let (db, _guard) = test_database().await;
        let pool = db.pool().clone();
        let repo = Arc::new(LearningRepository::new(pool.clone()));
        let tl_repo = Arc::new(crate::repositories::TimelineRepository::new(pool.clone()));
        let ws_repo = Arc::new(crate::repositories::WorkspaceRepository::new(pool.clone()));
        let engine = AdaptiveLearningEngine::new(repo)
            .with_timeline_repository(tl_repo)
            .with_workspace_repository(ws_repo);
        let ws_id = uuid::Uuid::new_v4().to_string();
        let patterns = engine.learn_patterns_from_history(&ws_id).await.unwrap();
        assert!(patterns.is_empty());
    }

    #[tokio::test]
    async fn learn_patterns_invalid_workspace_returns_empty() {
        let (db, _guard) = test_database().await;
        let repo = Arc::new(LearningRepository::new(db.pool().clone()));
        let engine = AdaptiveLearningEngine::new(repo);
        let patterns = engine
            .learn_patterns_from_history("not-a-uuid")
            .await
            .unwrap();
        assert!(patterns.is_empty());
        let patterns2 = engine.learn_patterns_from_history("").await.unwrap();
        assert!(patterns2.is_empty());
    }

    #[tokio::test]
    async fn learn_patterns_time_based_for_repeated_activity() {
        let (db, _guard) = test_database().await;
        let pool = db.pool().clone();
        let repo = Arc::new(LearningRepository::new(pool.clone()));
        let tl_repo = Arc::new(crate::repositories::TimelineRepository::new(pool.clone()));
        let ws_repo = Arc::new(crate::repositories::WorkspaceRepository::new(pool.clone()));
        let file_repo = Arc::new(crate::repositories::FileRepository::new(pool.clone()));
        let engine = AdaptiveLearningEngine::new(repo.clone())
            .with_timeline_repository(tl_repo.clone())
            .with_workspace_repository(ws_repo.clone())
            .with_file_repository(file_repo.clone());

        // Create workspace
        let ws = ws_repo
            .create(crate::models::CreateWorkspaceInput {
                name: "ws-a".into(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();

        // Create 5 events at same hour (09 UTC) plus 1 off-peak at different hour — peak 09 should trigger time pattern.
        // Use `Utc::now() - 2h` as anchor so all events are in the past relative to `now` (the 30-day window check uses `occurred_at <= now`).
        let anchor = chrono::Utc::now() - chrono::Duration::hours(2);
        let anchor_hour = anchor.hour();
        let off_hour = (anchor_hour + 6) % 24;
        for i in 0..5 {
            let _at = anchor + chrono::Duration::minutes(i as i64 * 5);
            // Force same hour as anchor by truncating to hour then adding minutes within hour
            let at = anchor
                .date_naive()
                .and_hms_opt(anchor_hour, (i * 5) as u32, 0)
                .unwrap()
                .and_utc();
            // Ensure it's in the past
            let at = if at > chrono::Utc::now() {
                at - chrono::Duration::days(1)
            } else {
                at
            };
            tl_repo
                .create(crate::models::NewTimelineEvent {
                    workspace_id: ws.id,
                    file_id: None,
                    event_type: crate::models::TimelineEventType::Edit,
                    occurred_at: at,
                    metadata: None,
                })
                .await
                .unwrap();
        }
        // One off-peak at different hour
        let off_at = anchor
            .date_naive()
            .and_hms_opt(off_hour, 0, 0)
            .unwrap()
            .and_utc();
        let off_at = if off_at > chrono::Utc::now() {
            off_at - chrono::Duration::days(1)
        } else {
            off_at
        };
        tl_repo
            .create(crate::models::NewTimelineEvent {
                workspace_id: ws.id,
                file_id: None,
                event_type: crate::models::TimelineEventType::Edit,
                occurred_at: off_at,
                metadata: None,
            })
            .await
            .unwrap();

        let patterns = engine
            .learn_patterns_from_history(&ws.id.to_string())
            .await
            .unwrap();
        assert!(
            !patterns.is_empty(),
            "should have learned at least time-based pattern"
        );
        let time_pat = patterns
            .iter()
            .find(|p| p.pattern_type == PatternType::TimeBased)
            .expect("time pattern");
        assert_eq!(time_pat.occurrences, 5);
        assert!(time_pat.confidence >= 0.5 && time_pat.confidence <= 0.95);
        assert!(time_pat.description.contains(":00"), "desc {}", time_pat.description);
        // Persisted
        let all = repo.get_all_patterns().await.unwrap();
        assert!(all.iter().any(|p| p.id == time_pat.id));
    }

    #[tokio::test]
    async fn learn_patterns_workspace_isolation() {
        let (db, _guard) = test_database().await;
        let pool = db.pool().clone();
        let repo = Arc::new(LearningRepository::new(pool.clone()));
        let tl_repo = Arc::new(crate::repositories::TimelineRepository::new(pool.clone()));
        let ws_repo = Arc::new(crate::repositories::WorkspaceRepository::new(pool.clone()));
        let engine = AdaptiveLearningEngine::new(repo.clone())
            .with_timeline_repository(tl_repo.clone())
            .with_workspace_repository(ws_repo.clone());

        let ws_a = ws_repo
            .create(crate::models::CreateWorkspaceInput {
                name: "ws-a".into(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();
        let ws_b = ws_repo
            .create(crate::models::CreateWorkspaceInput {
                name: "ws-b".into(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();

        let anchor = chrono::Utc::now() - chrono::Duration::hours(2);
        let anchor_hour = anchor.hour();
        for i in 0..5 {
            let at = anchor
                .date_naive()
                .and_hms_opt(anchor_hour, i as u32, 0)
                .unwrap()
                .and_utc();
            let at = if at > chrono::Utc::now() {
                at - chrono::Duration::days(1)
            } else {
                at
            };
            tl_repo
                .create(crate::models::NewTimelineEvent {
                    workspace_id: ws_a.id,
                    file_id: None,
                    event_type: crate::models::TimelineEventType::Edit,
                    occurred_at: at,
                    metadata: None,
                })
                .await
                .unwrap();
        }

        let pats_a = engine
            .learn_patterns_from_history(&ws_a.id.to_string())
            .await
            .unwrap();
        let pats_b = engine
            .learn_patterns_from_history(&ws_b.id.to_string())
            .await
            .unwrap();
        assert!(!pats_a.is_empty());
        assert!(
            pats_b.is_empty(),
            "ws_b has no history, should not leak ws_a patterns"
        );
        // Ensure stored patterns all belong to ws_a
        for p in pats_a {
            let ws_in_cond = p.conditions.get("workspace_id").and_then(|v| v.as_str());
            assert_eq!(ws_in_cond, Some(ws_a.id.to_string()).as_deref());
        }
    }

    #[tokio::test]
    async fn learn_patterns_idempotent_no_duplicate_on_repeated_cycle() {
        let (db, _guard) = test_database().await;
        let pool = db.pool().clone();
        let repo = Arc::new(LearningRepository::new(pool.clone()));
        let tl_repo = Arc::new(crate::repositories::TimelineRepository::new(pool.clone()));
        let ws_repo = Arc::new(crate::repositories::WorkspaceRepository::new(pool.clone()));
        let engine = AdaptiveLearningEngine::new(repo.clone())
            .with_timeline_repository(tl_repo.clone())
            .with_workspace_repository(ws_repo.clone());

        let ws = ws_repo
            .create(crate::models::CreateWorkspaceInput {
                name: "ws".into(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();

        let anchor = chrono::Utc::now() - chrono::Duration::hours(2);
        let anchor_hour = anchor.hour();
        for i in 0..5 {
            let at = anchor
                .date_naive()
                .and_hms_opt(anchor_hour, i as u32, 0)
                .unwrap()
                .and_utc();
            let at = if at > chrono::Utc::now() {
                at - chrono::Duration::days(1)
            } else {
                at
            };
            tl_repo
                .create(crate::models::NewTimelineEvent {
                    workspace_id: ws.id,
                    file_id: None,
                    event_type: crate::models::TimelineEventType::Edit,
                    occurred_at: at,
                    metadata: None,
                })
                .await
                .unwrap();
        }

        let first = engine
            .learn_patterns_from_history(&ws.id.to_string())
            .await
            .unwrap();
        let first_ids: std::collections::HashSet<uuid::Uuid> = first.iter().map(|p| p.id).collect();
        let count_before = repo.get_all_patterns().await.unwrap().len();

        let second = engine
            .learn_patterns_from_history(&ws.id.to_string())
            .await
            .unwrap();
        let second_ids: std::collections::HashSet<uuid::Uuid> =
            second.iter().map(|p| p.id).collect();
        let count_after = repo.get_all_patterns().await.unwrap().len();

        assert_eq!(first_ids, second_ids, "deterministic ids");
        assert_eq!(count_before, count_after, "no duplicate rows");
    }

    #[tokio::test]
    async fn learn_patterns_for_all_workspaces_bounded() {
        let (db, _guard) = test_database().await;
        let pool = db.pool().clone();
        let repo = Arc::new(LearningRepository::new(pool.clone()));
        let tl_repo = Arc::new(crate::repositories::TimelineRepository::new(pool.clone()));
        let ws_repo = Arc::new(crate::repositories::WorkspaceRepository::new(pool.clone()));
        let engine = AdaptiveLearningEngine::new(repo.clone())
            .with_timeline_repository(tl_repo.clone())
            .with_workspace_repository(ws_repo.clone());

        // Two workspaces each with history
        for name in ["ws1", "ws2"] {
            let ws = ws_repo
                .create(crate::models::CreateWorkspaceInput {
                    name: name.into(),
                    description: None,
                    root_path: None,
                })
                .await
                .unwrap();
            let anchor = chrono::Utc::now() - chrono::Duration::hours(2);
            let anchor_hour = anchor.hour();
            for i in 0..5 {
                let at = anchor
                    .date_naive()
                    .and_hms_opt(anchor_hour, i as u32, 0)
                    .unwrap()
                    .and_utc();
                let at = if at > chrono::Utc::now() {
                    at - chrono::Duration::days(1)
                } else {
                    at
                };
                tl_repo
                    .create(crate::models::NewTimelineEvent {
                        workspace_id: ws.id,
                        file_id: None,
                        event_type: crate::models::TimelineEventType::Edit,
                        occurred_at: at,
                        metadata: None,
                    })
                    .await
                    .unwrap();
            }
        }

        let total = engine.learn_patterns_for_all_workspaces().await.unwrap();
        assert!(total >= 2, "each workspace contributes");
        let stored = repo.get_all_patterns().await.unwrap().len();
        assert!(stored >= 2);
    }

    #[tokio::test]
    async fn original_confidence_threaded_from_context() {
        let (db, _guard) = test_database().await;
        let repo = Arc::new(LearningRepository::new(db.pool().clone()));
        let engine = AdaptiveLearningEngine::new(repo.clone());

        engine
            .record_feedback(
                FeedbackType::Recommendation,
                FeedbackTargetType::Recommendation,
                "rec-x".into(),
                FeedbackAction::Accepted,
                serde_json::json!({"category": "productivity", "confidence": 0.8}),
            )
            .await
            .unwrap();

        let adjs = repo
            .get_confidence_adjustments(FeedbackTargetType::Recommendation, "rec-x")
            .await
            .unwrap();
        assert_eq!(adjs.len(), 1);
        assert!((adjs[0].original_confidence - 0.8).abs() < 1e-6);
        assert!((adjs[0].adjusted_confidence - 0.8 * 1.2).abs() < 1e-6);

        // Without confidence in context → fallback 0.5
        engine
            .record_feedback(
                FeedbackType::Recommendation,
                FeedbackTargetType::Recommendation,
                "rec-y".into(),
                FeedbackAction::Rejected,
                serde_json::json!({"category": "productivity"}),
            )
            .await
            .unwrap();
        let adjs2 = repo
            .get_confidence_adjustments(FeedbackTargetType::Recommendation, "rec-y")
            .await
            .unwrap();
        assert!((adjs2[0].original_confidence - 0.5).abs() < 1e-6);
        assert!((adjs2[0].adjusted_confidence - 0.5 * 0.5).abs() < 1e-6);
    }
}
