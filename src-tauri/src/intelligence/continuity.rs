//! Context Reconstruction & Continuity Engine
//!
//! Composes WorkspaceIntelligenceEngine, ContextMemoryEngine, ContextService,
//! TimelineRepository, and ActivityRepository to reconstruct the exact shape of past
//! work when a user returns to a workspace, providing explainable continuity scoring,
//! verified file integrity, and non-destructive context resumption.

use std::collections::HashMap;
use std::path::Path;
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::context_memory::models::{ContextSnapshot, CreateSnapshotRequest, SnapshotType};
use crate::context_memory::ContextMemoryEngine;
use crate::errors::DatabaseError;
use crate::intelligence::workspace::{WorkEpisode, WorkspaceIntelligenceEngine};
use crate::models::Workspace;
use crate::repositories::{ActivityRepository, TimelineRepository, WorkspaceRepository};
use crate::services::ContextService;
use crate::session::types::SessionEventSummary;

pub const WEIGHT_RECENCY: f64 = 0.30;
pub const WEIGHT_CONFIDENCE: f64 = 0.25;
pub const WEIGHT_ACTIVITY: f64 = 0.20;
pub const WEIGHT_FILE_INTEGRITY: f64 = 0.15;
pub const WEIGHT_RELATIONSHIPS: f64 = 0.10;

/// An individual explainable signal contributing to context continuity.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContinuitySignal {
    pub signal: String,
    pub score: f64,
    pub weight: f64,
    pub contribution: f64,
    pub explanation: String,
}

/// Reconstructed file representation with ground-truth verification.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReconstructedFile {
    pub path: String,
    pub file_name: String,
    pub exists_on_disk: bool,
    pub language: Option<String>,
    pub is_inferred: bool,
}

/// Explicit, non-destructive user action to resume or explore context.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResumeAction {
    pub action_type: String,
    pub label: String,
    pub description: String,
    pub target: Option<String>,
}

/// Full reconstructed context of a workspace when returning or resuming.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReconstructedContext {
    pub workspace_id: Uuid,
    pub workspace_name: String,
    pub continuity_score: f64,
    pub signals: Vec<ContinuitySignal>,
    pub selection_reason: String,
    pub latest_episode: Option<WorkEpisode>,
    pub primary_app: Option<String>,
    pub active_applications: Vec<String>,
    pub relevant_files: Vec<ReconstructedFile>,
    pub recent_activities: Vec<SessionEventSummary>,
    pub related_workspaces: Vec<String>,
    pub snapshot_id: Option<i64>,
    pub is_resumable: bool,
    pub recommended_actions: Vec<ResumeAction>,
    pub reconstructed_at: DateTime<Utc>,
}

/// Coordinates context reconstruction and continuity across intelligence systems.
#[derive(Clone)]
pub struct ContextContinuityEngine {
    workspace_intel: WorkspaceIntelligenceEngine,
    context_memory: ContextMemoryEngine,
    context_service: ContextService,
    workspace_repo: WorkspaceRepository,
    timeline_repo: TimelineRepository,
    activity_repo: ActivityRepository,
}

impl ContextContinuityEngine {
    pub fn new(
        workspace_intel: WorkspaceIntelligenceEngine,
        context_memory: ContextMemoryEngine,
        context_service: ContextService,
        workspace_repo: WorkspaceRepository,
        timeline_repo: TimelineRepository,
        activity_repo: ActivityRepository,
    ) -> Self {
        Self {
            workspace_intel,
            context_memory,
            context_service,
            workspace_repo,
            timeline_repo,
            activity_repo,
        }
    }

    /// Reconstructs the comprehensive work context for a specific workspace.
    pub async fn reconstruct_workspace_context(
        &self,
        workspace_id: Uuid,
    ) -> Result<ReconstructedContext, DatabaseError> {
        let workspace = self.workspace_repo.get_by_id(workspace_id).await?;
        self.build_reconstructed_context(&workspace).await
    }

    /// Extends Smart Resume by identifying the most confident previous work context.
    pub async fn get_smart_resume_context(
        &self,
    ) -> Result<Option<ReconstructedContext>, DatabaseError> {
        // First try active workspace inference
        if let Ok(inference) = self.workspace_intel.infer_active_workspace().await {
            if let Some(top) = inference.active {
                if let Ok(workspace) = self.workspace_repo.get_by_id(top.workspace_id).await {
                    return Ok(Some(self.build_reconstructed_context(&workspace).await?));
                }
            } else if let Some(first_ranked) = inference.ranked.first() {
                if first_ranked.confidence >= 0.30 {
                    if let Ok(workspace) = self.workspace_repo.get_by_id(first_ranked.workspace_id).await {
                        return Ok(Some(self.build_reconstructed_context(&workspace).await?));
                    }
                }
            }
        }

        // Fallback to most recent session from ContextService
        if let Ok(Some(session)) = self.context_service.get_smart_resume_session().await {
            if let Ok(workspace) = self.workspace_repo.get_by_id(session.workspace_id).await {
                return Ok(Some(self.build_reconstructed_context(&workspace).await?));
            }
        }

        Ok(None)
    }

    /// Creates and persists a ContextSnapshot of the current work episode in ContextMemory.
    pub async fn snapshot_work_episode(
        &self,
        workspace_id: Uuid,
        snapshot_type: SnapshotType,
    ) -> Result<ContextSnapshot, DatabaseError> {
        let context = self.reconstruct_workspace_context(workspace_id).await?;
        let active_files: Vec<String> = context
            .relevant_files
            .iter()
            .map(|f| f.path.clone())
            .collect();

        let timeline_ids: Vec<String> = self
            .timeline_repo
            .list_by_workspace(workspace_id, Some(20))
            .await
            .unwrap_or_default()
            .iter()
            .map(|e| e.id.to_string())
            .collect();

        let session_summary = serde_json::json!({
            "episode": context.latest_episode,
            "primaryApp": context.primary_app,
            "activeApps": context.active_applications,
            "continuityScore": context.continuity_score,
            "fileCount": active_files.len()
        });

        let metadata = serde_json::json!({
            "reconstructedAt": context.reconstructed_at.to_rfc3339(),
            "selectionReason": context.selection_reason,
            "signals": context.signals,
            "relatedWorkspaces": context.related_workspaces,
            "timelineEventIds": timeline_ids
        });

        let request = CreateSnapshotRequest {
            workspace_id: workspace_id.to_string(),
            snapshot_type,
            active_files,
            session_summary: Some(session_summary),
            timeline_references: None,
            analytics_summary: None,
            health_score: None,
            recommendations_summary: None,
            metadata: Some(metadata),
        };

        self.context_memory.create_snapshot(request).await
    }

    /// Internal builder synthesizing all live and persisted signals into ReconstructedContext.
    async fn build_reconstructed_context(
        &self,
        workspace: &Workspace,
    ) -> Result<ReconstructedContext, DatabaseError> {
        let now = Utc::now();
        let ws_id = workspace.id;
        let ws_str = ws_id.to_string();

        // 1. Live Intelligence Assessment
        let intel = self.workspace_intel.infer_workspace_intelligence(ws_id).await.ok();
        let workspace_confidence = intel.as_ref().map(|i| i.confidence).unwrap_or(0.2);

        // 2. Work Session & Timeline Events
        let latest_session = self.context_service.get_latest_workspace_session(ws_id).await.ok().flatten();
        let (latest_episode, recent_activities) = match latest_session {
            Some(session) => {
                let dur = session.duration_seconds;
                let is_resumable = now.signed_duration_since(session.ended_at).num_minutes() <= 2880;
                let ep = WorkEpisode {
                    started_at: session.started_at,
                    ended_at: session.ended_at,
                    duration_seconds: dur,
                    event_count: session.recent_events.len(),
                    summary: format!(
                        "Session across {} files in {}",
                        session.file_count,
                        if session.languages.is_empty() {
                            "workspace".to_string()
                        } else {
                            session.languages.join(", ")
                        }
                    ),
                    is_resumable,
                };
                (Some(ep), session.recent_events)
            }
            None => (intel.as_ref().and_then(|i| i.latest_episode.clone()), Vec::new()),
        };

        // 3. Persisted Snapshot (from ContextMemoryEngine)
        let latest_snapshot = self.context_memory.get_latest_snapshot(&ws_str).await.ok().flatten();
        let snapshot_id = latest_snapshot.as_ref().map(|s| s.id);

        // 4. Active Applications Window (from ActivityRepository)
        let since_24h = now - Duration::hours(24);
        let activity_events = self
            .activity_repo
            .list_by_workspace_window(Some(ws_id), since_24h, now, Some(100))
            .await
            .unwrap_or_default();

        let mut app_counts: HashMap<String, usize> = HashMap::new();
        for ev in &activity_events {
            if !ev.app_name.trim().is_empty() {
                *app_counts.entry(ev.app_name.clone()).or_insert(0) += 1;
            }
        }
        let mut active_applications: Vec<String> = app_counts.keys().cloned().collect();
        active_applications.sort();
        let primary_app = app_counts
            .into_iter()
            .max_by_key(|&(_, count)| count)
            .map(|(app, _)| app)
            .or_else(|| intel.as_ref().and_then(|i| i.primary_app.clone()));

        // 5. Relevant Files & Ground-Truth Disk Verification
        let timeline_events = self.timeline_repo.list_by_workspace(ws_id, Some(50)).await.unwrap_or_default();
        let touched_file_ids: std::collections::HashSet<Uuid> = timeline_events.iter().filter_map(|e| e.file_id).collect();

        let mut deduped_files: HashMap<String, bool> = HashMap::new();
        if let Some(ref snap) = latest_snapshot {
            for path in &snap.active_files {
                deduped_files.insert(path.clone(), false);
            }
        }
        if let Ok(ws_files) = self.context_service.get_workspace_files(ws_id).await {
            for wf in ws_files.into_iter().take(15) {
                let inferred = !touched_file_ids.contains(&wf.id);
                deduped_files
                    .entry(wf.path_or_url)
                    .and_modify(|e| { if !inferred { *e = false; } })
                    .or_insert(inferred);
            }
        }

        let mut relevant_files = Vec::new();
        let mut accessible_files_count = 0;
        for (path, is_inferred) in deduped_files {
            let path_obj = Path::new(&path);
            let exists_on_disk = path_obj.exists();
            if exists_on_disk {
                accessible_files_count += 1;
            }
            let file_name = path_obj.file_name().and_then(|n| n.to_str()).unwrap_or(&path).to_string();
            let language = path_obj.extension().and_then(|e| e.to_str()).map(ToString::to_string);
            relevant_files.push(ReconstructedFile { path, file_name, exists_on_disk, language, is_inferred });
        }
        relevant_files.sort_by(|a, b| a.file_name.cmp(&b.file_name));

        // 6. Related Workspaces from ContextMemory
        let related_objs = self
            .context_memory
            .get_related_workspaces(&ws_str, 0.1, 5)
            .await
            .unwrap_or_default();
        let related_workspaces: Vec<String> = related_objs.into_iter().map(|r| r.workspace_name).collect();

        // 7. Calculate Deterministic Continuity Signals & Score
        // (a) Recency
        let diff = now.signed_duration_since(workspace.last_active_at);
        let mins = diff.num_minutes();
        let (recency_score, recency_expl) = if mins <= 30 {
            (1.0, format!("Active {mins}m ago"))
        } else if mins <= 120 {
            (0.85, format!("Active {mins}m ago"))
        } else if mins <= 720 {
            let hrs = mins / 60;
            (0.70, format!("Active {hrs}h ago"))
        } else if mins <= 1440 {
            (0.50, "Active earlier today".to_string())
        } else if mins <= 2880 {
            (0.30, "Active yesterday".to_string())
        } else {
            (0.10, "Idle for more than 48 hours".to_string())
        };

        // (b) Intelligence Confidence
        let (conf_score, conf_expl) = (
            workspace_confidence,
            format!("Workspace intelligence confidence: {}%", (workspace_confidence * 100.0).round() as i64),
        );

        // (c) Activity Continuity
        let event_count = latest_episode.as_ref().map(|e| e.event_count).unwrap_or(0);
        let (act_score, act_expl) = if event_count >= 10 {
            (1.0, format!("Substantial work depth ({event_count} session events)"))
        } else if event_count > 0 {
            (0.65, format!("Moderate work depth ({event_count} session events)"))
        } else if !activity_events.is_empty() {
            (0.40, format!("{} window activity logs recorded", activity_events.len()))
        } else {
            (0.05, "Minimal activity recorded in episode".to_string())
        };

        // (d) File Integrity & Continuity
        let total_files = relevant_files.len();
        let (file_score, file_expl) = if total_files == 0 {
            (0.50, "No specific files pinned to context".to_string())
        } else {
            let ratio = accessible_files_count as f64 / total_files as f64;
            (
                ratio,
                format!("{accessible_files_count}/{total_files} relevant files verified on disk"),
            )
        };

        // (e) Relationship Coherence
        let rel_count = related_workspaces.len();
        let (rel_score, rel_expl) = if rel_count > 0 {
            (0.85, format!("{rel_count} connected workspaces in knowledge graph"))
        } else {
            (0.30, "Independent context with no graph edges".to_string())
        };

        let signals = vec![
            make_signal("recency", recency_score, WEIGHT_RECENCY, recency_expl),
            make_signal("workspace_confidence", conf_score, WEIGHT_CONFIDENCE, conf_expl),
            make_signal("activity_continuity", act_score, WEIGHT_ACTIVITY, act_expl),
            make_signal("file_integrity", file_score, WEIGHT_FILE_INTEGRITY, file_expl),
            make_signal("relationship_coherence", rel_score, WEIGHT_RELATIONSHIPS, rel_expl),
        ];

        let total_continuity: f64 = signals.iter().map(|s| s.score * s.weight).sum();
        let continuity_score = (total_continuity.clamp(0.0, 1.0) * 100.0).round() / 100.0;
        let is_resumable = continuity_score >= 0.25;

        let selection_reason = if mins <= 60 {
            format!("Recently active ({mins}m ago, {}% continuity)", (continuity_score * 100.0).round() as i64)
        } else if event_count > 5 {
            format!("High work density ({event_count} events) in {}", workspace.name)
        } else {
            format!("Preserved work context for {}", workspace.name)
        };

        let mut recommended_actions = vec![ResumeAction {
            action_type: "switch_workspace".to_string(),
            label: format!("Switch to {}", workspace.name),
            description: "Focus this workspace and restore its environment.".to_string(),
            target: Some(ws_str.clone()),
        }];

        if accessible_files_count > 0 {
            recommended_actions.push(ResumeAction {
                action_type: "open_files".to_string(),
                label: format!("Open {accessible_files_count} Files"),
                description: "Reopen files you were editing when you left off.".to_string(),
                target: Some(ws_str),
            });
        }

        Ok(ReconstructedContext {
            workspace_id: ws_id,
            workspace_name: workspace.name.clone(),
            continuity_score,
            signals,
            selection_reason,
            latest_episode,
            primary_app,
            active_applications,
            relevant_files,
            recent_activities,
            related_workspaces,
            snapshot_id,
            is_resumable,
            recommended_actions,
            reconstructed_at: now,
        })
    }
}

fn make_signal(signal: &str, score: f64, weight: f64, explanation: String) -> ContinuitySignal {
    ContinuitySignal {
        signal: signal.to_string(),
        score,
        weight,
        contribution: (score * weight * 100.0).round() / 100.0,
        explanation,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn continuity_weights_sum_to_one() {
        let sum = WEIGHT_RECENCY + WEIGHT_CONFIDENCE + WEIGHT_ACTIVITY + WEIGHT_FILE_INTEGRITY + WEIGHT_RELATIONSHIPS;
        assert!((sum - 1.0).abs() < f64::EPSILON);
    }

    #[test]
    fn reconstructed_file_detects_nonexistent_paths() {
        let fake_path = "/nonexistent/path/to/virtual_file.rs";
        let exists = Path::new(fake_path).exists();
        assert!(!exists);

        let file = ReconstructedFile {
            path: fake_path.to_string(),
            file_name: "virtual_file.rs".to_string(),
            exists_on_disk: exists,
            language: Some("rs".to_string()),
            is_inferred: true,
        };
        assert!(!file.exists_on_disk);
        assert!(file.is_inferred);
    }
}
