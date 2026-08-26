//! Conversation Manager - Manages copilot conversation state and context.

use chrono::Utc;
use std::sync::Arc;
use uuid::Uuid;

use crate::context_memory::ContextMemoryEngine;
use crate::copilot::models::*;
use crate::copilot::repository::CopilotRepository;
use crate::errors::DatabaseError;
use crate::session::SessionEngine;
use crate::timeline::TimelineEngine;

/// Manages conversation state and context.
pub struct ConversationManager {
    repository: Arc<CopilotRepository>,
    #[allow(dead_code)]
    context_memory: Arc<ContextMemoryEngine>,
    #[allow(dead_code)]
    session_engine: Arc<SessionEngine>,
    timeline_engine: Arc<TimelineEngine>,
}

impl ConversationManager {
    /// Creates a new conversation manager.
    pub fn new(
        repository: Arc<CopilotRepository>,
        context_memory: Arc<ContextMemoryEngine>,
        session_engine: Arc<SessionEngine>,
        timeline_engine: Arc<TimelineEngine>,
    ) -> Self {
        Self {
            repository,
            context_memory,
            session_engine,
            timeline_engine,
        }
    }

    /// Creates or gets a conversation.
    pub async fn get_or_create_conversation(
        &self,
        conversation_id: Option<Uuid>,
        workspace_id: Option<Uuid>,
    ) -> Result<Conversation, DatabaseError> {
        if let Some(id) = conversation_id {
            if let Some(conversation) = self.repository.get_conversation(id).await? {
                return Ok(conversation);
            }
        }

        // Create new conversation
        let title = if let Some(workspace_id) = workspace_id {
            format!("Conversation in workspace {}", workspace_id)
        } else {
            format!(
                "New conversation at {}",
                Utc::now().format("%Y-%m-%d %H:%M")
            )
        };

        self.repository
            .create_conversation(workspace_id, &title)
            .await
    }

    /// Adds a user message to the conversation.
    pub async fn add_user_message(
        &self,
        conversation_id: Uuid,
        content: &str,
    ) -> Result<Message, DatabaseError> {
        let message = Message {
            id: Uuid::new_v4(),
            conversation_id,
            role: MessageRole::User,
            content: content.to_string(),
            tool_calls: None,
            reasoning: None,
            sources: None,
            created_at: Utc::now(),
        };

        self.repository.add_message(&message).await?;
        Ok(message)
    }

    /// Adds an assistant message to the conversation.
    pub async fn add_assistant_message(
        &self,
        conversation_id: Uuid,
        content: &str,
        reasoning: Option<String>,
        sources: Option<Vec<Source>>,
        tool_calls: Option<Vec<ToolCall>>,
    ) -> Result<Message, DatabaseError> {
        let message = Message {
            id: Uuid::new_v4(),
            conversation_id,
            role: MessageRole::Assistant,
            content: content.to_string(),
            tool_calls,
            reasoning,
            sources,
            created_at: Utc::now(),
        };

        self.repository.add_message(&message).await?;
        Ok(message)
    }

    /// Gets conversation history.
    pub async fn get_conversation_history(
        &self,
        conversation_id: Uuid,
        limit: Option<usize>,
    ) -> Result<Vec<Message>, DatabaseError> {
        self.repository.get_messages(conversation_id, limit).await
    }

    /// Captures a context snapshot for the conversation.
    pub async fn capture_context(
        &self,
        conversation_id: Uuid,
        workspace_id: Option<Uuid>,
    ) -> Result<ContextSnapshot, DatabaseError> {
        // Get recent timeline events
        let recent_events = if let Some(ws_id) = workspace_id {
            self.timeline_engine.recent_events(ws_id, Some(20), None).await?
        } else {
            Vec::new()
        };

        let recent_event_summaries: Vec<String> = recent_events
            .iter()
            .map(|e| format!("{:?}", e.event_type))
            .collect();

        // Get session summary - not available without actual Session object
        let session_summary = None;

        // For now, active files are derived from recent events - would need file_id lookup
        let active_files: Vec<String> = vec![];

        let snapshot = ContextSnapshot {
            id: Uuid::new_v4(),
            conversation_id,
            workspace_id,
            active_files,
            recent_events: recent_event_summaries,
            session_summary,
            captured_at: Utc::now(),
        };

        self.repository.save_context_snapshot(&snapshot).await?;
        Ok(snapshot)
    }

    /// Builds context string for LLM prompt.
    pub async fn build_context_string(
        &self,
        workspace_id: Option<Uuid>,
    ) -> Result<String, DatabaseError> {
        let mut context_parts = Vec::new();

        // Add workspace info
        if let Some(ws_id) = workspace_id {
            context_parts.push(format!("Current workspace: {}", ws_id));
        }

        // Add recent activity
        let recent_events = if let Some(ws_id) = workspace_id {
            self.timeline_engine.recent_events(ws_id, Some(10), None).await?
        } else {
            Vec::new()
        };

        if !recent_events.is_empty() {
            context_parts.push("Recent activity:".to_string());
            for event in recent_events.iter().take(5) {
                context_parts.push(format!("  - {:?}", event.event_type));
            }
        }

        // Session info not directly available without Session object
        // Would require fetching latest session first

        Ok(context_parts.join("\n"))
    }

    /// Updates conversation title based on content.
    pub async fn update_conversation_title(
        &self,
        conversation_id: Uuid,
        title: &str,
    ) -> Result<(), DatabaseError> {
        sqlx::query(
            r#"
            UPDATE copilot_conversations
            SET title = ?, updated_at = ?
            WHERE id = ?
            "#,
        )
        .bind(title)
        .bind(Utc::now().to_rfc3339())
        .bind(conversation_id.to_string())
        .execute(&self.repository.pool)
        .await?;

        Ok(())
    }
}
