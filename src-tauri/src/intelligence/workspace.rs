//! Workspace Intelligence Engine
//!
//! Composition layer that aggregates signals from WorkspaceRepository,
//! TimelineRepository, ActivityRepository, ContextService, and
//! WorkspaceHealthEngine to produce deterministic, explainable workspace
//! confidence scoring and active workspace inference.

use std::collections::HashMap;
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::errors::DatabaseError;
use crate::intelligence::health::WorkspaceHealthEngine;
use crate::intelligence::recommendation::RecommendationEngine;
use crate::models::Workspace;
use crate::repositories::{ActivityRepository, TimelineRepository, WorkspaceRepository};
use crate::services::ContextService;

pub const WEIGHT_TEMPORAL: f64 = 0.30;
pub const WEIGHT_ACTIVITY: f64 = 0.25;
pub const WEIGHT_HEALTH: f64 = 0.25;
pub const WEIGHT_SESSION: f64 = 0.20;

pub const CONFIDENCE_THRESHOLD_ACTIVE: f64 = 0.55;
pub const CONFIDENCE_THRESHOLD_SUGGESTION: f64 = 0.35;

/// An individual explainable signal contributing to overall workspace confidence.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfidenceSignal {
    pub signal: String,
    pub score: f64,
    pub weight: f64,
    pub contribution: f64,
    pub explanation: String,
}

/// A reconstructed work episode representing continuous user work.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkEpisode {
    pub started_at: DateTime<Utc>,
    pub ended_at: DateTime<Utc>,
    pub duration_seconds: i64,
    pub event_count: usize,
    pub summary: String,
    pub is_resumable: bool,
}

/// A contextual suggestion surfaced based on confidence and activity signals.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSuggestion {
    pub id: String,
    pub title: String,
    pub description: String,
    pub action_type: String,
    pub confidence: f64,
    pub target: Option<String>,
}

/// Comprehensive intelligence view of a single workspace.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceIntelligence {
    pub workspace_id: Uuid,
    pub workspace_name: String,
    pub confidence: f64,
    pub signals: Vec<ConfidenceSignal>,
    pub is_active_inference: bool,
    pub latest_episode: Option<WorkEpisode>,
    pub suggestions: Vec<WorkspaceSuggestion>,
    pub activity_24h: i64,
    pub activity_7d: i64,
    pub primary_app: Option<String>,
    pub computed_at: DateTime<Utc>,
}

/// Global active workspace inference across all active workspaces.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActiveWorkspaceInference {
    pub active: Option<WorkspaceIntelligence>,
    pub ranked: Vec<WorkspaceIntelligence>,
    pub has_active_inference: bool,
    pub computed_at: DateTime<Utc>,
}

#[derive(Clone)]
pub struct WorkspaceIntelligenceEngine {
    workspace_repo: WorkspaceRepository,
    timeline_repo: TimelineRepository,
    activity_repo: ActivityRepository,
    context_service: ContextService,
    health_engine: WorkspaceHealthEngine,
    recommendation_engine: Option<RecommendationEngine>,
}

impl WorkspaceIntelligenceEngine {
    pub fn new(
        workspace_repo: WorkspaceRepository,
        timeline_repo: TimelineRepository,
        activity_repo: ActivityRepository,
        context_service: ContextService,
        health_engine: WorkspaceHealthEngine,
    ) -> Self {
        Self {
            workspace_repo,
            timeline_repo,
            activity_repo,
            context_service,
            health_engine,
            recommendation_engine: None,
        }
    }

    pub fn with_recommendation_engine(mut self, engine: RecommendationEngine) -> Self {
        self.recommendation_engine = Some(engine);
        self
    }

    /// Computes intelligence assessment for a single workspace by id.
    pub async fn infer_workspace_intelligence(
        &self,
        workspace_id: Uuid,
    ) -> Result<WorkspaceIntelligence, DatabaseError> {
        let workspace = self.workspace_repo.get_by_id(workspace_id).await?;
        self.compute_intelligence(&workspace).await
    }

    /// Ranks all active workspaces and detects the most confident active workspace.
    pub async fn infer_active_workspace(&self) -> Result<ActiveWorkspaceInference, DatabaseError> {
        let workspaces = self.workspace_repo.list_active_workspaces().await?;
        let now = Utc::now();

        let mut ranked = Vec::with_capacity(workspaces.len());
        for ws in &workspaces {
            if let Ok(intel) = self.compute_intelligence(ws).await {
                ranked.push(intel);
            }
        }

        // Sort descending by confidence
        ranked.sort_by(|a, b| {
            b.confidence
                .partial_cmp(&a.confidence)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        let active = ranked
            .first()
            .filter(|top| top.confidence >= CONFIDENCE_THRESHOLD_ACTIVE)
            .cloned();

        let has_active_inference = active.is_some();

        Ok(ActiveWorkspaceInference {
            active,
            ranked,
            has_active_inference,
            computed_at: now,
        })
    }

    /// Lists intelligence metrics across all active workspaces.
    pub async fn list_workspaces_intelligence(
        &self,
    ) -> Result<Vec<WorkspaceIntelligence>, DatabaseError> {
        let workspaces = self.workspace_repo.list_active_workspaces().await?;
        let mut list = Vec::with_capacity(workspaces.len());

        for ws in &workspaces {
            if let Ok(intel) = self.compute_intelligence(ws).await {
                list.push(intel);
            }
        }

        list.sort_by(|a, b| {
            b.confidence
                .partial_cmp(&a.confidence)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        Ok(list)
    }

    /// Internal calculation composing real data sources into normalized confidence signals.
    async fn compute_intelligence(
        &self,
        workspace: &Workspace,
    ) -> Result<WorkspaceIntelligence, DatabaseError> {
        let now = Utc::now();
        let ws_id = workspace.id;

        // 1. Signal: Temporal Recency
        let diff = now.signed_duration_since(workspace.last_active_at);
        let mins = diff.num_minutes();
        let (temporal_score, temporal_expl) = if mins <= 15 {
            (1.0, format!("Active {mins}m ago"))
        } else if mins <= 60 {
            (0.85, format!("Active {mins}m ago"))
        } else if mins <= 240 {
            let hrs = mins / 60;
            (0.70, format!("Active {hrs}h ago"))
        } else if mins <= 1440 {
            let hrs = mins / 60;
            (0.50, format!("Active {hrs}h ago"))
        } else if mins <= 2880 {
            (0.30, "Active yesterday".to_string())
        } else if mins <= 10080 {
            let days = mins / 1440;
            (0.15, format!("Active {days}d ago"))
        } else {
            (0.05, "No recent activity".to_string())
        };

        // 2. Signal: Activity Velocity (24h and 7d from timeline)
        let since_24h = now - Duration::hours(24);
        let since_7d = now - Duration::days(7);
        let activity_24h = self.timeline_repo.count_since(ws_id, since_24h).await.unwrap_or(0);
        let activity_7d = self.timeline_repo.count_since(ws_id, since_7d).await.unwrap_or(0);

        let (activity_score, activity_expl) = if activity_24h > 0 {
            let score = (activity_24h as f64 / 40.0).clamp(0.1, 1.0);
            (score, format!("{activity_24h} events in past 24h"))
        } else if activity_7d > 0 {
            let score = (activity_7d as f64 / 150.0).clamp(0.05, 0.4);
            (score, format!("{activity_7d} events in past 7d"))
        } else {
            (0.0, "Zero events recorded".to_string())
        };

        // 3. Signal: Health Score
        let health_assessment = self.health_engine.get_latest_health(ws_id).await.ok().flatten();
        let (health_score, health_expl) = match health_assessment {
            Some(h) => {
                let pct = (h.overall_score * 100.0).round() as i64;
                (h.overall_score.clamp(0.0, 1.0), format!("Health assessment: {pct}%"))
            }
            None => {
                let ws_health = (workspace.health_score / 100.0).clamp(0.0, 1.0);
                let pct = workspace.health_score.round() as i64;
                (ws_health, format!("Stored health: {pct}%"))
            }
        };

        // 4. Signal: Session Continuity & Work Episode
        let latest_session = self.context_service.get_latest_workspace_session(ws_id).await.ok().flatten();
        let (session_score, session_expl, episode) = match latest_session {
            Some(session) => {
                let diff = now.signed_duration_since(session.ended_at);
                let mins = diff.num_minutes();
                let prod_factor = (session.productivity_score / 100.0).clamp(0.2, 1.0);

                let base_recency = if mins <= 30 {
                    1.0
                } else if mins <= 120 {
                    0.80
                } else if mins <= 720 {
                    0.50
                } else if mins <= 1440 {
                    0.30
                } else {
                    0.10
                };

                let score = (base_recency * (0.6 + 0.4 * prod_factor)).clamp(0.0, 1.0);
                let dur_mins = session.duration_seconds / 60;
                let expl = format!(
                    "Last session ended {mins}m ago ({dur_mins}m duration, {} files)",
                    session.file_count
                );

                let is_resumable = mins <= 2880; // Resumable within 48h
                let ep = WorkEpisode {
                    started_at: session.started_at,
                    ended_at: session.ended_at,
                    duration_seconds: session.duration_seconds,
                    event_count: session.recent_events.len(),
                    summary: format!(
                        "Session across {} files in {}",
                        session.file_count,
                        if session.languages.is_empty() {
                            "project".to_string()
                        } else {
                            session.languages.join(", ")
                        }
                    ),
                    is_resumable,
                };

                (score, expl, Some(ep))
            }
            None => (0.0, "No prior session detected".to_string(), None),
        };

        // Synthesize signals
        let signals = vec![
            ConfidenceSignal {
                signal: "temporal_recency".to_string(),
                score: temporal_score,
                weight: WEIGHT_TEMPORAL,
                contribution: (temporal_score * WEIGHT_TEMPORAL * 100.0).round() / 100.0,
                explanation: temporal_expl,
            },
            ConfidenceSignal {
                signal: "activity_velocity".to_string(),
                score: activity_score,
                weight: WEIGHT_ACTIVITY,
                contribution: (activity_score * WEIGHT_ACTIVITY * 100.0).round() / 100.0,
                explanation: activity_expl,
            },
            ConfidenceSignal {
                signal: "workspace_health".to_string(),
                score: health_score,
                weight: WEIGHT_HEALTH,
                contribution: (health_score * WEIGHT_HEALTH * 100.0).round() / 100.0,
                explanation: health_expl,
            },
            ConfidenceSignal {
                signal: "session_continuity".to_string(),
                score: session_score,
                weight: WEIGHT_SESSION,
                contribution: (session_score * WEIGHT_SESSION * 100.0).round() / 100.0,
                explanation: session_expl,
            },
        ];

        let total_confidence: f64 = signals.iter().map(|s| s.score * s.weight).sum();
        let total_confidence = (total_confidence.clamp(0.0, 1.0) * 100.0).round() / 100.0;
        let is_active_inference = total_confidence >= CONFIDENCE_THRESHOLD_ACTIVE;

        // Primary application derivation from recent activity events
        let primary_app = self.infer_primary_app(ws_id, since_24h, now).await;

        // Contextual suggestions
        let suggestions = self.generate_suggestions(
            ws_id,
            &workspace.name,
            total_confidence,
            &episode,
            health_score,
            activity_24h,
        ).await;

        Ok(WorkspaceIntelligence {
            workspace_id: ws_id,
            workspace_name: workspace.name.clone(),
            confidence: total_confidence,
            signals,
            is_active_inference,
            latest_episode: episode,
            suggestions,
            activity_24h,
            activity_7d,
            primary_app,
            computed_at: now,
        })
    }

    /// Identifies the predominant app active in the given window.
    async fn infer_primary_app(
        &self,
        workspace_id: Uuid,
        since: DateTime<Utc>,
        until: DateTime<Utc>,
    ) -> Option<String> {
        let events = self
            .activity_repo
            .list_by_workspace_window(Some(workspace_id), since, until, Some(100))
            .await
            .ok()?;

        let mut app_counts = HashMap::new();
        for event in events {
            if !event.app_name.is_empty() {
                *app_counts.entry(event.app_name).or_insert(0) += 1;
            }
        }

        app_counts
            .into_iter()
            .max_by_key(|&(_, count)| count)
            .map(|(app, _)| app)
    }

    /// Derives deterministic suggestions based on confidence and metrics.
    async fn generate_suggestions(
        &self,
        workspace_id: Uuid,
        workspace_name: &str,
        confidence: f64,
        episode: &Option<WorkEpisode>,
        health_score: f64,
        activity_24h: i64,
    ) -> Vec<WorkspaceSuggestion> {
        let mut suggestions = Vec::new();

        // 1. Resumable episode suggestion
        if let Some(ep) = episode {
            if ep.is_resumable {
                suggestions.push(WorkspaceSuggestion {
                    id: format!("resume_{}", workspace_id),
                    title: format!("Resume {}", workspace_name),
                    description: format!(
                        "Pick up where you left off ({}m duration, {} events).",
                        ep.duration_seconds / 60,
                        ep.event_count
                    ),
                    action_type: "resume_workspace".to_string(),
                    confidence: (confidence * 0.9).clamp(0.3, 0.95),
                    target: Some(workspace_id.to_string()),
                });
            }
        }

        // 2. Health maintenance suggestion if low
        if health_score < 0.6 {
            suggestions.push(WorkspaceSuggestion {
                id: format!("health_{}", workspace_id),
                title: "Improve Workspace Organization".to_string(),
                description: "Health is below 60%. Review untracked files or clean up stale contexts.".to_string(),
                action_type: "review_health".to_string(),
                confidence: 0.75,
                target: Some(workspace_id.to_string()),
            });
        }

        // 3. Snapshot recommendation on high velocity
        if activity_24h >= 25 {
            suggestions.push(WorkspaceSuggestion {
                id: format!("snapshot_{}", workspace_id),
                title: "Save Context Milestone".to_string(),
                description: format!("High velocity ({activity_24h} events in 24h). Create a snapshot to preserve this state."),
                action_type: "create_snapshot".to_string(),
                confidence: 0.80,
                target: Some(workspace_id.to_string()),
            });
        }

        suggestions
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn weights_sum_to_one() {
        let sum = WEIGHT_TEMPORAL + WEIGHT_ACTIVITY + WEIGHT_HEALTH + WEIGHT_SESSION;
        assert!((sum - 1.0).abs() < f64::EPSILON);
    }

    #[test]
    fn threshold_order_valid() {
        assert!(CONFIDENCE_THRESHOLD_ACTIVE > CONFIDENCE_THRESHOLD_SUGGESTION);
    }
}
