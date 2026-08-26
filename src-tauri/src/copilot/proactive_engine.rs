//! Proactive AI Engine - Event-driven intelligent assistant.

use chrono::Utc;
use std::sync::Arc;
use tokio::sync::RwLock;
use uuid::Uuid;

use crate::context_memory::ContextMemoryEngine;
use crate::copilot::proactive_detector::ProactiveDetector;
use crate::copilot::proactive_models::*;
use crate::errors::DatabaseError;
use crate::intelligence::recommendation::RecommendationEngine;
use crate::learning::AdaptiveLearningEngine;
use crate::predictive::PredictiveEngine;
use crate::semantic::ContextReasoningEngine;
use crate::session::SessionEngine;
use crate::timeline::TimelineEngine;

/// Proactive AI engine that monitors context and generates intelligent suggestions.
pub struct ProactiveEngine {
    detector: Arc<ProactiveDetector>,
    timeline_engine: Arc<TimelineEngine>,
    #[allow(dead_code)]
    session_engine: Arc<SessionEngine>,

    // In-memory notification queue
    notifications: Arc<RwLock<Vec<ProactiveNotification>>>,
    permissions: Arc<RwLock<Vec<AutomationPermission>>>,

    /// Optional event sink. When set, every queued notification is also
    /// forwarded to the frontend as `proactive:notification` so native
    /// macOS notifications can be raised. Wired in `lib.rs`; `None` in
    /// tests keeps emission inert.
    emitter: Option<std::sync::Arc<dyn crate::app_events::AppEventEmitter>>,
}

impl ProactiveEngine {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        timeline_engine: Arc<TimelineEngine>,
        session_engine: Arc<SessionEngine>,
        predictive_engine: Arc<PredictiveEngine>,
        learning_engine: Arc<AdaptiveLearningEngine>,
        recommendation_engine: Arc<RecommendationEngine>,
        context_memory: Arc<ContextMemoryEngine>,
        _reasoning_engine: Arc<ContextReasoningEngine>,
    ) -> Self {
        let detector = Arc::new(ProactiveDetector::new(
            timeline_engine.clone(),
            session_engine.clone(),
            predictive_engine.clone(),
            learning_engine.clone(),
            recommendation_engine.clone(),
            context_memory.clone(),
        ));

        Self {
            detector,
            timeline_engine,
            session_engine,
            notifications: Arc::new(RwLock::new(Vec::new())),
            permissions: Arc::new(RwLock::new(Vec::new())),
            emitter: None,
        }
    }

    /// Attaches the frontend event sink after construction (the engine is
    /// wrapped in an `Arc` immediately, so this must run before sharing).
    pub fn set_event_emitter(
        &mut self,
        emitter: std::sync::Arc<dyn crate::app_events::AppEventEmitter>,
    ) {
        self.emitter = Some(emitter);
    }

    /// Forwards one notification to the frontend as a
    /// `proactive:notification` event (best-effort; never fails).
    fn notify(&self, notification: &ProactiveNotification) {
        if let Some(emitter) = self.emitter.as_ref() {
            crate::app_events::emit(
                emitter.as_ref(),
                crate::app_events::EVENT_PROACTIVE_NOTIFICATION,
                notification,
            );
        }
    }

    /// Handles a workspace switch event.
    pub async fn on_workspace_switched(
        &self,
        from_workspace_id: Uuid,
        to_workspace_id: Uuid,
    ) -> Result<(), DatabaseError> {
        let notification = self
            .detector
            .detect_workspace_switch(from_workspace_id, to_workspace_id)
            .await?;

        {
            let mut notifications = self.notifications.write().await;
            notifications.push(notification.clone());
        }
        self.notify(&notification);

        Ok(())
    }

    /// Handles a timeline event.
    pub async fn on_timeline_event(
        &self,
        workspace_id: Uuid,
        event_type: &str,
    ) -> Result<(), DatabaseError> {
        // Check for repeated edits
        if event_type == "edit" {
            if let Some(notification) = self.detector.detect_repeated_edits(workspace_id).await? {
                {
                    let mut notifications = self.notifications.write().await;
                    notifications.push(notification.clone());
                }
                self.notify(&notification);
            }
        }

        Ok(())
    }

    /// Handles a session started event.
    pub async fn on_session_started(&self, workspace_id: Uuid) -> Result<(), DatabaseError> {
        // Check for unfinished work from previous sessions
        let unfinished = self.detector.detect_unfinished_work(workspace_id).await?;

        if !unfinished.is_empty() {
            let evidence: Vec<Evidence> =
                unfinished.iter().flat_map(|w| w.evidence.clone()).collect();

            let notification = ProactiveNotification {
                id: Uuid::new_v4(),
                workspace_id: Some(workspace_id),
                notification_type: NotificationType::UnfinishedWork,
                title: "Unfinished Work Detected".to_string(),
                message: format!(
                    "You have {} unfinished items from your last session.",
                    unfinished.len()
                ),
                priority: NotificationPriority::Medium,
                evidence,
                suggested_actions: vec![
                    "Resume previous work".to_string(),
                    "Review unfinished items".to_string(),
                ],
                dismissible: true,
                dismissed: false,
                created_at: Utc::now(),
                expires_at: None,
            };

            {
                let mut notifications = self.notifications.write().await;
                notifications.push(notification.clone());
            }
            self.notify(&notification);
        }

        Ok(())
    }

    /// Periodic check for proactive opportunities.
    pub async fn check_proactive_opportunities(
        &self,
        workspace_id: Uuid,
    ) -> Result<(), DatabaseError> {
        // Check for long focus sessions
        if let Some(notification) = self
            .detector
            .detect_long_focus_session(workspace_id)
            .await?
        {
            let mut notifications = self.notifications.write().await;
            // Only add if not already present
            if !notifications.iter().any(|n| {
                n.notification_type == NotificationType::LongFocusSession
                    && n.workspace_id == Some(workspace_id)
                    && !n.dismissed
            }) {
                notifications.push(notification.clone());
                self.notify(&notification);
            }
        }

        // Check for idle periods
        if let Some(notification) = self.detector.detect_idle_period(workspace_id).await? {
            let mut notifications = self.notifications.write().await;
            if !notifications.iter().any(|n| {
                n.notification_type == NotificationType::IdlePeriod
                    && n.workspace_id == Some(workspace_id)
                    && !n.dismissed
            }) {
                notifications.push(notification.clone());
                self.notify(&notification);
            }
        }

        // Check for recurring workflows
        if let Some(notification) = self
            .detector
            .detect_recurring_workflow(workspace_id)
            .await?
        {
            let mut notifications = self.notifications.write().await;
            if !notifications.iter().any(|n| {
                n.notification_type == NotificationType::RecurringWorkflow
                    && n.workspace_id == Some(workspace_id)
                    && !n.dismissed
            }) {
                notifications.push(notification.clone());
                self.notify(&notification);
            }
        }

        Ok(())
    }

    /// Gets all active notifications.
    pub async fn get_active_notifications(
        &self,
        workspace_id: Option<Uuid>,
    ) -> Vec<ProactiveNotification> {
        let notifications = self.notifications.read().await;

        notifications
            .iter()
            .filter(|n| {
                !n.dismissed
                    && (workspace_id.is_none() || n.workspace_id == workspace_id)
                    && n.expires_at.map_or(true, |exp| exp > Utc::now())
            })
            .cloned()
            .collect()
    }

    /// Dismisses a notification.
    pub async fn dismiss_notification(&self, notification_id: Uuid) -> Result<(), DatabaseError> {
        let mut notifications = self.notifications.write().await;
        if let Some(notification) = notifications.iter_mut().find(|n| n.id == notification_id) {
            notification.dismissed = true;
        }
        Ok(())
    }

    /// Generates a resume context for a workspace.
    pub async fn generate_resume_context(
        &self,
        workspace_id: Uuid,
    ) -> Result<ResumeContext, DatabaseError> {
        // Get recent timeline
        let timeline = self
            .timeline_engine
            .recent_events(workspace_id, Some(20), None)
            .await?;

        let recent_timeline: Vec<TimelineSummary> = timeline
            .iter()
            .take(10)
            .map(|e| TimelineSummary {
                event_type: format!("{:?}", e.event_type),
                description: e.file_id.map(|id| id.to_string()).unwrap_or_default(),
                occurred_at: e.occurred_at,
            })
            .collect();

        // Detect unfinished work
        let unfinished_work = self.detector.detect_unfinished_work(workspace_id).await?;

        // Get open files from timeline
        let mut open_files = Vec::new();
        for event in timeline.iter().take(10) {
            if let Some(file_id) = &event.file_id {
                let file_str = file_id.to_string();
                if !open_files.contains(&file_str) {
                    open_files.push(file_str);
                }
            }
        }

        // Get last active timestamp
        let last_active = timeline
            .first()
            .map(|e| e.occurred_at)
            .unwrap_or_else(Utc::now);

        Ok(ResumeContext {
            workspace_id,
            last_active,
            unfinished_work,
            open_files,
            active_branch: None, // Could be enhanced with git integration
            recent_timeline,
            previous_conversation_id: None, // Could query last conversation
            context_snapshot: None,
        })
    }

    /// Generates an execution plan for a goal.
    pub async fn generate_execution_plan(
        &self,
        _workspace_id: Option<Uuid>,
        goal: &str,
    ) -> Result<ExecutionPlan, DatabaseError> {
        // Mock implementation - in production this would use LLM
        let tasks = vec![
            PlanTask {
                id: Uuid::new_v4(),
                description: format!("Analyze requirements for: {}", goal),
                dependencies: vec![],
                estimated_minutes: 15,
                required_files: vec![],
                tool_name: None,
                arguments: None,
                completed: false,
                condition: None,
            },
            PlanTask {
                id: Uuid::new_v4(),
                description: "Implement core functionality".to_string(),
                dependencies: vec![],
                estimated_minutes: 60,
                required_files: vec![],
                tool_name: None,
                arguments: None,
                completed: false,
                condition: None,
            },
            PlanTask {
                id: Uuid::new_v4(),
                description: "Write tests".to_string(),
                dependencies: vec![],
                estimated_minutes: 30,
                required_files: vec![],
                tool_name: None,
                arguments: None,
                completed: false,
                condition: None,
            },
        ];

        let total_minutes: i32 = tasks.iter().map(|t| t.estimated_minutes).sum();

        Ok(ExecutionPlan {
            id: Uuid::new_v4(),
            workspace_id: _workspace_id,
            goal: goal.to_string(),
            tasks,
            estimated_duration_minutes: total_minutes,
            required_files: vec![],
            checkpoints: vec![
                "Requirements analyzed".to_string(),
                "Core implementation complete".to_string(),
                "Tests passing".to_string(),
            ],
            confidence: 0.75,
            reasoning: "Based on similar tasks in your workflow history".to_string(),
            status: PlanApprovalStatus::Pending,
            created_at: Utc::now(),
        })
    }

    /// Sets automation permission for an action.
    pub async fn set_automation_permission(
        &self,
        workspace_id: Option<Uuid>,
        action_type: &str,
        permission: PermissionLevel,
    ) -> Result<(), DatabaseError> {
        let mut permissions = self.permissions.write().await;

        // Remove existing permission for this action
        permissions.retain(|p| !(p.workspace_id == workspace_id && p.action_type == action_type));

        // Add new permission
        permissions.push(AutomationPermission {
            id: Uuid::new_v4(),
            workspace_id,
            action_type: action_type.to_string(),
            permission,
            granted_at: Utc::now(),
            expires_at: None,
        });

        Ok(())
    }

    /// Checks automation permission for an action.
    pub async fn check_automation_permission(
        &self,
        workspace_id: Option<Uuid>,
        action_type: &str,
    ) -> PermissionLevel {
        let permissions = self.permissions.read().await;

        permissions
            .iter()
            .find(|p| p.workspace_id == workspace_id && p.action_type == action_type)
            .map(|p| p.permission)
            .unwrap_or(PermissionLevel::AskEachTime)
    }

    /// Generates enhanced daily briefing with intelligence.
    pub async fn generate_enhanced_briefing(
        &self,
        workspace_id: Option<Uuid>,
    ) -> Result<EnhancedBriefing, DatabaseError> {
        let now = Utc::now();

        // Get yesterday's summary
        let yesterday_summary = vec![
            "Worked on authentication module".to_string(),
            "Fixed 3 bugs".to_string(),
            "Added test coverage".to_string(),
        ];

        // Get today's priorities
        let today_priorities = vec![
            Priority {
                description: "Complete authentication integration".to_string(),
                confidence: 0.85,
                reasoning: "Based on recent activity patterns".to_string(),
                estimated_minutes: 120,
            },
            Priority {
                description: "Review pull requests".to_string(),
                confidence: 0.70,
                reasoning: "Recurring morning task".to_string(),
                estimated_minutes: 30,
            },
        ];

        // Get unfinished work
        let unfinished_work = if let Some(wid) = workspace_id {
            self.detector.detect_unfinished_work(wid).await?
        } else {
            vec![]
        };

        Ok(EnhancedBriefing {
            date: now,
            summary: "Good morning! Ready to continue your work on the authentication module."
                .to_string(),
            yesterday_summary,
            today_priorities,
            unfinished_work,
            health_trends: vec![],
            prediction_changes: vec![],
            learning_insights: vec![],
            semantic_discoveries: vec![],
            recommendations: vec![
                "Consider refactoring the auth service".to_string(),
                "Update documentation for new features".to_string(),
            ],
            estimated_focus_schedule: vec![
                FocusBlock {
                    time: "9:00-11:00".to_string(),
                    activity: "Deep work on authentication".to_string(),
                    confidence: 0.80,
                },
                FocusBlock {
                    time: "14:00-16:00".to_string(),
                    activity: "Code review and testing".to_string(),
                    confidence: 0.75,
                },
            ],
        })
    }

    /// Answers timeline intelligence queries.
    pub async fn query_timeline_intelligence(
        &self,
        _workspace_id: Option<Uuid>,
        query: &str,
    ) -> Result<TimelineIntelligence, DatabaseError> {
        // Mock implementation - production would use semantic reasoning
        let query_lower = query.to_lowercase();

        let (answer, confidence) = if query_lower.contains("yesterday") {
            (
                "Yesterday you worked on authentication, fixed bugs, and added tests.".to_string(),
                0.90,
            )
        } else if query_lower.contains("changed") {
            (
                "Recent changes include updates to auth service and test files.".to_string(),
                0.85,
            )
        } else if query_lower.contains("confidence") {
            (
                "Prediction confidence changed due to new workflow patterns detected.".to_string(),
                0.80,
            )
        } else {
            (
                "I can analyze your timeline to answer this question with more context."
                    .to_string(),
                0.60,
            )
        };

        let evidence = vec![Evidence {
            source: EvidenceSource::Timeline,
            description: "Analyzed recent timeline events".to_string(),
            confidence,
            timestamp: Utc::now(),
            metadata: serde_json::json!({ "query": query }),
        }];

        Ok(TimelineIntelligence {
            query: query.to_string(),
            answer,
            evidence,
            confidence,
            related_events: vec![],
        })
    }
}
