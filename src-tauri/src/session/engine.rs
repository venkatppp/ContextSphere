//! Session Engine
//!
//! Reconstructs and scores work sessions from timeline events. The engine
//! is responsible for session detection, language inference, and productivity
//! scoring. It operates on timeline events (the single source of truth) and
//! does not store sessions as canonical data.

use uuid::Uuid;

use crate::errors::DatabaseError;
use crate::models::{FileArtifact, TimelineEvent};
use crate::repositories::{FileRepository, TimelineRepository};
use crate::session::detector::{detect_sessions, DEFAULT_INACTIVITY_THRESHOLD_SECONDS};
use crate::session::language_detection::detect_languages;
use crate::session::scoring::ContextScoringEngine;
use crate::session::types::{Session, SessionContext, SessionEventSummary, SessionSummary};

/// Session Engine: reconstructs sessions from timeline events.
///
/// This engine sits between the repositories and the ContextService.
/// It's responsible for the mechanics of session detection and scoring,
/// but not for high-level intelligence decisions (that's ContextService).
#[derive(Debug, Clone)]
pub struct SessionEngine {
    timeline_repository: TimelineRepository,
    pub(crate) file_repository: FileRepository,
}

impl SessionEngine {
    /// Creates a new SessionEngine.
    pub fn new(timeline_repository: TimelineRepository, file_repository: FileRepository) -> Self {
        Self {
            timeline_repository,
            file_repository,
        }
    }

    /// Detects work sessions for a workspace.
    ///
    /// Reconstructs sessions from timeline events using the specified
    /// inactivity threshold. Returns sessions ordered by start time
    /// (newest first).
    ///
    /// # Arguments
    /// * `workspace_id` - Workspace to analyze
    /// * `threshold_seconds` - Inactivity threshold (None = use default 30 min)
    /// * `limit` - Maximum number of sessions to return (None = all)
    pub async fn detect_sessions(
        &self,
        workspace_id: Uuid,
        threshold_seconds: Option<i64>,
        limit: Option<usize>,
    ) -> Result<Vec<Session>, DatabaseError> {
        // Fetch timeline events for this workspace
        let events = self
            .timeline_repository
            .list_by_workspace(workspace_id, None)
            .await?;

        if events.is_empty() {
            return Ok(Vec::new());
        }

        let threshold = threshold_seconds.unwrap_or(DEFAULT_INACTIVITY_THRESHOLD_SECONDS);

        // Detect sessions
        let mut sessions = detect_sessions(events, threshold);

        // Enrich sessions with languages and scores
        for session in &mut sessions {
            self.enrich_session(session).await?;
        }

        // Apply limit if specified
        if let Some(limit) = limit {
            sessions.truncate(limit);
        }

        Ok(sessions)
    }

    /// Gets the most recent session for a workspace.
    ///
    /// Returns None if the workspace has no timeline events or no sessions.
    pub async fn get_latest_session(
        &self,
        workspace_id: Uuid,
        threshold_seconds: Option<i64>,
    ) -> Result<Option<Session>, DatabaseError> {
        let mut sessions = self
            .detect_sessions(workspace_id, threshold_seconds, Some(1))
            .await?;

        Ok(sessions.pop())
    }

    /// Gets the most recent session across all active workspaces.
    ///
    /// This is used for Smart Resume: find the last thing the user was
    /// working on, regardless of which workspace it was in.
    pub async fn get_most_recent_active_session(
        &self,
        threshold_seconds: Option<i64>,
    ) -> Result<Option<Session>, DatabaseError> {
        // Fetch recent timeline events across all workspaces (last 100 events)
        // This is a heuristic: we assume the most recent session is within
        // the last 100 events. In practice, this should be plenty.
        let events = self
            .timeline_repository
            .list_recent(100)
            .await
            .unwrap_or_default();

        if events.is_empty() {
            return Ok(None);
        }

        // Group events by workspace
        let mut events_by_workspace: std::collections::HashMap<Uuid, Vec<TimelineEvent>> =
            std::collections::HashMap::new();
        for event in events {
            events_by_workspace
                .entry(event.workspace_id)
                .or_default()
                .push(event);
        }

        // Detect sessions for each workspace
        let threshold = threshold_seconds.unwrap_or(DEFAULT_INACTIVITY_THRESHOLD_SECONDS);
        let mut all_sessions = Vec::new();

        for (_workspace_id, events) in events_by_workspace {
            let sessions = detect_sessions(events, threshold);
            all_sessions.extend(sessions);
        }

        // Sort by start time (newest first)
        all_sessions.sort_by_key(|a| std::cmp::Reverse(a.started_at));

        // Take the most recent session and enrich it
        if let Some(mut session) = all_sessions.into_iter().next() {
            self.enrich_session(&mut session).await?;
            Ok(Some(session))
        } else {
            Ok(None)
        }
    }

    /// Creates a session summary for display in the UI.
    ///
    /// Includes workspace metadata, recent events, and scoring factors.
    pub async fn get_session_summary(
        &self,
        session: &Session,
        workspace_name: String,
    ) -> Result<SessionSummary, DatabaseError> {
        let productivity_score = session
            .productivity_score
            .as_ref()
            .map(|s| s.score)
            .unwrap_or(0.0);

        let score_factors = session
            .productivity_score
            .as_ref()
            .map(|s| s.factors.clone())
            .unwrap_or_default();

        // Create mini-timeline: show up to 10 most recent events with
        // real file names resolved from the files table.
        let file_ids: Vec<Uuid> = session.events.iter().filter_map(|e| e.file_id).collect();
        let files = self.fetch_files(&file_ids).await?;
        let name_by_id: std::collections::HashMap<Uuid, String> = files
            .into_iter()
            .map(|f| {
                let name = f
                    .path_or_url
                    .split(['/', '\\'])
                    .next_back()
                    .unwrap_or(&f.path_or_url)
                    .to_string();
                (f.id, name)
            })
            .collect();

        let recent_events = session
            .events
            .iter()
            .rev()
            .take(10)
            .map(|e| SessionEventSummary {
                occurred_at: e.occurred_at,
                event_type: e.event_type.as_str().to_string(),
                file_name: e.file_id.and_then(|id| name_by_id.get(&id).cloned()),
                description: format!("{}", e.event_type),
            })
            .collect();

        Ok(SessionSummary {
            workspace_id: session.workspace_id,
            workspace_name,
            started_at: session.started_at,
            ended_at: session.ended_at,
            duration_seconds: session.duration_seconds,
            file_count: session.file_count,
            languages: session.languages.clone(),
            productivity_score,
            score_factors,
            recent_events,
        })
    }

    /// Enriches a session with languages and productivity score.
    ///
    /// This is an internal helper that mutates the session in place.
    async fn enrich_session(&self, session: &mut Session) -> Result<(), DatabaseError> {
        // Collect file IDs from events
        let file_ids: Vec<Uuid> = session.events.iter().filter_map(|e| e.file_id).collect();

        // Fetch file artifacts
        let files = self.fetch_files(&file_ids).await?;

        // Detect languages
        session.languages = detect_languages(&files);

        // Calculate productivity score
        let context = SessionContext::from(&*session);
        let scoring_engine = ContextScoringEngine::new();
        session.productivity_score = Some(scoring_engine.calculate_score(&context));

        Ok(())
    }

    /// Fetches file artifacts for a list of file IDs.
    ///
    /// Returns files that exist; silently skips missing files.
    async fn fetch_files(&self, file_ids: &[Uuid]) -> Result<Vec<FileArtifact>, DatabaseError> {
        let mut files = Vec::new();

        for file_id in file_ids {
            if let Ok(file) = self.file_repository.get_by_id(*file_id).await {
                files.push(file);
            }
        }

        Ok(files)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::test_database;
    use crate::models::{
        ArtifactType, CreateWorkspaceInput, NewFile, NewTimelineEvent, TimelineEventType,
    };
    use crate::repositories::WorkspaceRepository;
    use chrono::Utc;

    async fn setup() -> (SessionEngine, Uuid, tempfile::TempDir) {
        let (database, temp_dir) = test_database().await;
        let pool = database.pool().clone();

        let workspace_repo = WorkspaceRepository::new(pool.clone());
        let timeline_repo = TimelineRepository::new(pool.clone());
        let file_repo = FileRepository::new(pool.clone());

        let workspace = workspace_repo
            .create(CreateWorkspaceInput {
                name: "Test Workspace".to_string(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();

        let engine = SessionEngine::new(timeline_repo, file_repo);

        (engine, workspace.id, temp_dir)
    }

    #[tokio::test]
    async fn no_events_returns_no_sessions() {
        let (engine, workspace_id, _guard) = setup().await;

        let sessions = engine
            .detect_sessions(workspace_id, None, None)
            .await
            .unwrap();

        assert!(sessions.is_empty());
    }

    #[tokio::test]
    async fn single_event_creates_single_session() {
        let (engine, workspace_id, _guard) = setup().await;

        // Create a timeline event
        engine
            .timeline_repository
            .create(NewTimelineEvent {
                workspace_id,
                file_id: None,
                event_type: TimelineEventType::Edit,
                occurred_at: Utc::now(),
                metadata: None,
            })
            .await
            .unwrap();

        let sessions = engine
            .detect_sessions(workspace_id, None, None)
            .await
            .unwrap();

        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].event_count, 1);
    }

    #[tokio::test]
    async fn session_includes_productivity_score() {
        let (engine, workspace_id, _guard) = setup().await;

        // Create a file
        let file = engine
            .file_repository
            .create(NewFile {
                workspace_id,
                artifact_type: ArtifactType::File,
                path_or_url: "/src/main.rs".to_string(),
                content_hash: None,
                file_identifier: None,
            })
            .await
            .unwrap();

        // Create timeline events
        engine
            .timeline_repository
            .create(NewTimelineEvent {
                workspace_id,
                file_id: Some(file.id),
                event_type: TimelineEventType::Edit,
                occurred_at: Utc::now(),
                metadata: None,
            })
            .await
            .unwrap();

        let sessions = engine
            .detect_sessions(workspace_id, None, None)
            .await
            .unwrap();

        assert_eq!(sessions.len(), 1);
        assert!(sessions[0].productivity_score.is_some());
        assert!(!sessions[0]
            .productivity_score
            .as_ref()
            .unwrap()
            .factors
            .is_empty());
    }

    #[tokio::test]
    async fn session_detects_languages() {
        let (engine, workspace_id, _guard) = setup().await;

        // Create Rust and TypeScript files
        let rust_file = engine
            .file_repository
            .create(NewFile {
                workspace_id,
                artifact_type: ArtifactType::File,
                path_or_url: "/src/main.rs".to_string(),
                content_hash: None,
                file_identifier: None,
            })
            .await
            .unwrap();

        let ts_file = engine
            .file_repository
            .create(NewFile {
                workspace_id,
                artifact_type: ArtifactType::File,
                path_or_url: "/src/app.tsx".to_string(),
                content_hash: None,
                file_identifier: None,
            })
            .await
            .unwrap();

        // Create timeline events
        engine
            .timeline_repository
            .create(NewTimelineEvent {
                workspace_id,
                file_id: Some(rust_file.id),
                event_type: TimelineEventType::Edit,
                occurred_at: Utc::now(),
                metadata: None,
            })
            .await
            .unwrap();

        engine
            .timeline_repository
            .create(NewTimelineEvent {
                workspace_id,
                file_id: Some(ts_file.id),
                event_type: TimelineEventType::Edit,
                occurred_at: Utc::now() + chrono::Duration::minutes(5),
                metadata: None,
            })
            .await
            .unwrap();

        let sessions = engine
            .detect_sessions(workspace_id, None, None)
            .await
            .unwrap();

        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].languages.len(), 2);
        assert!(sessions[0].languages.contains(&"Rust".to_string()));
        assert!(sessions[0].languages.contains(&"TypeScript".to_string()));
    }
}
