//! Proactive Intelligence Detector - Context-aware trigger system.

use chrono::{Duration, Utc};
use std::sync::Arc;
use uuid::Uuid;

use crate::context_memory::ContextMemoryEngine;
use crate::copilot::proactive_models::*;
use crate::errors::DatabaseError;
use crate::intelligence::recommendation::RecommendationEngine;
use crate::learning::AdaptiveLearningEngine;
use crate::models::TimelineEventType;
use crate::predictive::PredictiveEngine;
use crate::session::SessionEngine;
use crate::timeline::TimelineEngine;

/// Detects proactive opportunities based on workspace context.
pub struct ProactiveDetector {
    timeline_engine: Arc<TimelineEngine>,
    session_engine: Arc<SessionEngine>,
    predictive_engine: Arc<PredictiveEngine>,
    #[allow(dead_code)]
    learning_engine: Arc<AdaptiveLearningEngine>,
    #[allow(dead_code)]
    recommendation_engine: Arc<RecommendationEngine>,
    #[allow(dead_code)]
    context_memory: Arc<ContextMemoryEngine>,
}

impl ProactiveDetector {
    pub fn new(
        timeline_engine: Arc<TimelineEngine>,
        session_engine: Arc<SessionEngine>,
        predictive_engine: Arc<PredictiveEngine>,
        learning_engine: Arc<AdaptiveLearningEngine>,
        recommendation_engine: Arc<RecommendationEngine>,
        context_memory: Arc<ContextMemoryEngine>,
    ) -> Self {
        Self {
            timeline_engine,
            session_engine,
            predictive_engine,
            learning_engine,
            recommendation_engine,
            context_memory,
        }
    }

    /// Detects long focus sessions (> 90 minutes without break).
    pub async fn detect_long_focus_session(
        &self,
        workspace_id: Uuid,
    ) -> Result<Option<ProactiveNotification>, DatabaseError> {
        let sessions = self
            .session_engine
            .detect_sessions(workspace_id, None, Some(10))
            .await?;

        for session in sessions {
            let duration = Utc::now() - session.started_at;
            let duration_minutes = duration.num_minutes();
            if duration_minutes > 90 {
                let evidence = vec![Evidence {
                    source: EvidenceSource::Session,
                    description: format!("Focus session active for {} minutes", duration_minutes),
                    confidence: 0.95,
                    timestamp: Utc::now(),
                    metadata: serde_json::json!({
                        "workspace_id": session.workspace_id,
                        "duration_minutes": duration_minutes,
                    }),
                }];

                return Ok(Some(ProactiveNotification {
                    id: Uuid::new_v4(),
                    workspace_id: Some(workspace_id),
                    notification_type: NotificationType::LongFocusSession,
                    title: "Take a Break".to_string(),
                    message: format!(
                        "You've been focused for {} minutes. Consider taking a short break.",
                        duration_minutes
                    ),
                    priority: NotificationPriority::Medium,
                    evidence,
                    suggested_actions: vec![
                        "Take a 5-minute break".to_string(),
                        "Save current progress".to_string(),
                    ],
                    dismissible: true,
                    dismissed: false,
                    created_at: Utc::now(),
                    expires_at: Some(Utc::now() + Duration::minutes(15)),
                }));
            }
        }

        Ok(None)
    }

    /// Detects repeated file edits (same file edited 5+ times in 10 minutes).
    pub async fn detect_repeated_edits(
        &self,
        workspace_id: Uuid,
    ) -> Result<Option<ProactiveNotification>, DatabaseError> {
        let timeline = self
            .timeline_engine
            .recent_events(workspace_id, Some(100), None)
            .await?;

        let since = Utc::now() - Duration::minutes(10);
        let recent_edits: Vec<_> = timeline
            .into_iter()
            .filter(|e| e.event_type == TimelineEventType::Edit && e.occurred_at >= since)
            .collect();

        // Count edits per file
        let mut file_counts = std::collections::HashMap::new();
        for event in &recent_edits {
            if let Some(file_id) = &event.file_id {
                *file_counts.entry(*file_id).or_insert(0) += 1;
            }
        }

        if let Some((file_id, count)) = file_counts.iter().max_by_key(|(_, c)| *c) {
            if *count >= 5 {
                let evidence = vec![Evidence {
                    source: EvidenceSource::Timeline,
                    description: format!("File edited {} times in 10 minutes", count),
                    confidence: 0.90,
                    timestamp: Utc::now(),
                    metadata: serde_json::json!({
                        "file_id": file_id,
                        "edit_count": count,
                    }),
                }];

                return Ok(Some(ProactiveNotification {
                    id: Uuid::new_v4(),
                    workspace_id: Some(workspace_id),
                    notification_type: NotificationType::RepeatedEdits,
                    title: "Frequent Edits Detected".to_string(),
                    message: format!("You've edited a file {} times. Need help debugging?", count),
                    priority: NotificationPriority::Low,
                    evidence,
                    suggested_actions: vec![
                        "Review recent changes".to_string(),
                        "Check for syntax errors".to_string(),
                    ],
                    dismissible: true,
                    dismissed: false,
                    created_at: Utc::now(),
                    expires_at: Some(Utc::now() + Duration::minutes(30)),
                }));
            }
        }

        Ok(None)
    }

    /// Detects idle periods (no activity for 30+ minutes).
    pub async fn detect_idle_period(
        &self,
        workspace_id: Uuid,
    ) -> Result<Option<ProactiveNotification>, DatabaseError> {
        let timeline = self
            .timeline_engine
            .recent_events(workspace_id, Some(10), None)
            .await?;

        if let Some(last_event) = timeline.first() {
            let idle_duration = Utc::now() - last_event.occurred_at;
            let idle_minutes = idle_duration.num_minutes();
            if idle_minutes > 30 {
                let evidence = vec![Evidence {
                    source: EvidenceSource::Timeline,
                    description: format!("No activity for {} minutes", idle_minutes),
                    confidence: 1.0,
                    timestamp: Utc::now(),
                    metadata: serde_json::json!({
                        "idle_minutes": idle_minutes,
                        "last_event": last_event.event_type,
                    }),
                }];

                return Ok(Some(ProactiveNotification {
                    id: Uuid::new_v4(),
                    workspace_id: Some(workspace_id),
                    notification_type: NotificationType::IdlePeriod,
                    title: "Workspace Idle".to_string(),
                    message: "You've been away for a while. Ready to resume?".to_string(),
                    priority: NotificationPriority::Low,
                    evidence,
                    suggested_actions: vec![
                        "Resume previous work".to_string(),
                        "See what changed".to_string(),
                    ],
                    dismissible: true,
                    dismissed: false,
                    created_at: Utc::now(),
                    expires_at: Some(Utc::now() + Duration::hours(1)),
                }));
            }
        }

        Ok(None)
    }

    /// Detects workspace switches.
    pub async fn detect_workspace_switch(
        &self,
        from_workspace_id: Uuid,
        to_workspace_id: Uuid,
    ) -> Result<ProactiveNotification, DatabaseError> {
        let evidence = vec![Evidence {
            source: EvidenceSource::Session,
            description: "Workspace switched".to_string(),
            confidence: 1.0,
            timestamp: Utc::now(),
            metadata: serde_json::json!({
                "from_workspace_id": from_workspace_id,
                "to_workspace_id": to_workspace_id,
            }),
        }];

        Ok(ProactiveNotification {
            id: Uuid::new_v4(),
            workspace_id: Some(to_workspace_id),
            notification_type: NotificationType::WorkspaceSwitch,
            title: "Workspace Switched".to_string(),
            message: "Switched to a new workspace. Would you like context?".to_string(),
            priority: NotificationPriority::Medium,
            evidence,
            suggested_actions: vec![
                "Show recent files".to_string(),
                "Resume previous session".to_string(),
            ],
            dismissible: true,
            dismissed: false,
            created_at: Utc::now(),
            expires_at: Some(Utc::now() + Duration::minutes(5)),
        })
    }

    /// Detects unfinished work from previous sessions.
    pub async fn detect_unfinished_work(
        &self,
        workspace_id: Uuid,
    ) -> Result<Vec<UnfinishedWork>, DatabaseError> {
        let mut unfinished = Vec::new();

        // Check timeline for incomplete patterns
        let timeline = self
            .timeline_engine
            .recent_events(workspace_id, Some(50), None)
            .await?;

        // Look for files that were opened but not saved
        let mut open_files = std::collections::HashMap::new();
        for event in timeline {
            if event.event_type == TimelineEventType::Open {
                if let Some(file_id) = &event.file_id {
                    open_files.insert(*file_id, event.occurred_at);
                }
            } else if event.event_type == TimelineEventType::Edit
                || event.event_type == TimelineEventType::Close
            {
                if let Some(file_id) = &event.file_id {
                    open_files.remove(file_id);
                }
            }
        }

        for (file_id, opened_at) in open_files {
            let evidence = vec![Evidence {
                source: EvidenceSource::Timeline,
                description: "File opened but not edited".to_string(),
                confidence: 0.70,
                timestamp: Utc::now(),
                metadata: serde_json::json!({
                    "file_id": file_id,
                    "opened_at": opened_at,
                }),
            }];

            unfinished.push(UnfinishedWork {
                description: format!("Continue working on file {}", file_id),
                file_path: Some(file_id.to_string()),
                detected_at: Utc::now(),
                confidence: 0.70,
                evidence,
            });
        }

        Ok(unfinished)
    }

    /// Checks if a recurring workflow is detected.
    pub async fn detect_recurring_workflow(
        &self,
        _workspace_id: Uuid,
    ) -> Result<Option<ProactiveNotification>, DatabaseError> {
        let workflow_prediction = self.predictive_engine.predict_next_workspace().await?;

        if let Some(prediction) = workflow_prediction {
            if prediction.confidence > 0.80 {
                let evidence = vec![Evidence {
                    source: EvidenceSource::Predictive,
                    description: format!(
                        "Detected recurring workspace pattern: {}",
                        prediction.workspace_name
                    ),
                    confidence: prediction.confidence,
                    timestamp: Utc::now(),
                    metadata: serde_json::json!({
                        "workspace_name": prediction.workspace_name,
                        "confidence": prediction.confidence,
                    }),
                }];

                return Ok(Some(ProactiveNotification {
                    id: Uuid::new_v4(),
                    workspace_id: Some(_workspace_id),
                    notification_type: NotificationType::RecurringWorkflow,
                    title: "Recurring Pattern Detected".to_string(),
                    message: format!(
                        "You often work on {} at this time. Need assistance?",
                        prediction.workspace_name
                    ),
                    priority: NotificationPriority::Low,
                    evidence,
                    suggested_actions: vec![
                        "Show related files".to_string(),
                        "Start workflow".to_string(),
                    ],
                    dismissible: true,
                    dismissed: false,
                    created_at: Utc::now(),
                    expires_at: Some(Utc::now() + Duration::hours(1)),
                }));
            }
        }

        Ok(None)
    }
}
