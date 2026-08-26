//! Copilot Engine - AI-powered workspace assistant with multi-step planning.

use async_trait::async_trait;
use chrono::Utc;
use futures::StreamExt;
use std::sync::Arc;
use uuid::Uuid;

use crate::context_memory::ContextMemoryEngine;
use crate::copilot::conversation::ConversationManager;
use crate::copilot::models::*;
use crate::copilot::repository::CopilotRepository;
use crate::copilot::streaming::{StreamingDiagnostics, StreamingSessionManager};
use crate::copilot::tool_calling::{
    build_tool_schemas, ToolCallLoop, ToolCallLoopError, ToolCallResponder,
};
use crate::copilot::tools::ToolExecutor;
use crate::errors::DatabaseError;
use crate::intelligence::recommendation::RecommendationEngine;
use crate::learning::AdaptiveLearningEngine;
use crate::llm::{LLMMessage, LLMRequest, LLMResponse, LLMService, StreamEvent};
use crate::predictive::PredictiveEngine;
use crate::semantic::ContextReasoningEngine;
use crate::session::SessionEngine;
use crate::timeline::TimelineEngine;

/// Copilot engine that orchestrates all intelligence layers.
pub struct CopilotEngine {
    conversation_manager: Arc<ConversationManager>,
    tool_executor: Arc<ToolExecutor>,
    repository: Arc<CopilotRepository>,
    llm_service: Arc<LLMService>,
    streaming_manager: Arc<StreamingSessionManager>,
    #[allow(dead_code)]
    reasoning_engine: Arc<ContextReasoningEngine>,
    #[allow(dead_code)]
    predictive_engine: Arc<PredictiveEngine>,
    #[allow(dead_code)]
    learning_engine: Arc<AdaptiveLearningEngine>,
    recommendation_engine: Arc<RecommendationEngine>,
    #[allow(dead_code)]
    context_memory: Arc<ContextMemoryEngine>,
    #[allow(dead_code)]
    session_engine: Arc<SessionEngine>,
    timeline_engine: Arc<TimelineEngine>,
}

impl CopilotEngine {
    /// Creates a new copilot engine.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        conversation_manager: Arc<ConversationManager>,
        tool_executor: Arc<ToolExecutor>,
        repository: Arc<CopilotRepository>,
        llm_service: Arc<LLMService>,
        streaming_manager: Arc<StreamingSessionManager>,
        reasoning_engine: Arc<ContextReasoningEngine>,
        predictive_engine: Arc<PredictiveEngine>,
        learning_engine: Arc<AdaptiveLearningEngine>,
        recommendation_engine: Arc<RecommendationEngine>,
        context_memory: Arc<ContextMemoryEngine>,
        session_engine: Arc<SessionEngine>,
        timeline_engine: Arc<TimelineEngine>,
    ) -> Self {
        Self {
            conversation_manager,
            tool_executor,
            repository,
            llm_service,
            streaming_manager,
            reasoning_engine,
            predictive_engine,
            learning_engine,
            recommendation_engine,
            context_memory,
            session_engine,
            timeline_engine,
        }
    }

    /// Processes a user message and generates a response.
    pub async fn send_message(
        &self,
        request: SendMessageRequest,
    ) -> Result<CopilotResponse, DatabaseError> {
        // Get or create conversation
        let conversation = self
            .conversation_manager
            .get_or_create_conversation(request.conversation_id, request.workspace_id)
            .await?;

        // Add user message
        let _user_message = self
            .conversation_manager
            .add_user_message(conversation.id, &request.message)
            .await?;

        // Capture context if requested
        if request.include_context {
            self.conversation_manager
                .capture_context(conversation.id, request.workspace_id)
                .await?;
        }

        // Build context string
        let context = if request.include_context {
            self.conversation_manager
                .build_context_string(request.workspace_id)
                .await?
        } else {
            String::new()
        };

        // Analyze intent and generate response
        let response = self
            .generate_response(&request.message, &context, request.workspace_id)
            .await?;

        // Add assistant message
        let assistant_message = self
            .conversation_manager
            .add_assistant_message(
                conversation.id,
                &response.content,
                Some(response.reasoning.clone()),
                Some(response.sources.clone()),
                None,
            )
            .await?;

        // Generate suggested actions
        let suggested_actions = self
            .generate_suggested_actions(&request.message, request.workspace_id)
            .await?;

        Ok(CopilotResponse {
            conversation_id: conversation.id,
            message: assistant_message,
            suggested_actions,
        })
    }

    /// Starts streaming a user message response through frontend events.
    pub async fn send_message_stream(
        self: Arc<Self>,
        request: SendMessageRequest,
    ) -> Result<CopilotStreamResponse, DatabaseError> {
        let conversation = self
            .conversation_manager
            .get_or_create_conversation(request.conversation_id, request.workspace_id)
            .await?;

        self.conversation_manager
            .add_user_message(conversation.id, &request.message)
            .await?;

        if request.include_context {
            self.conversation_manager
                .capture_context(conversation.id, request.workspace_id)
                .await?;
        }

        let context = if request.include_context {
            self.conversation_manager
                .build_context_string(request.workspace_id)
                .await?
        } else {
            String::new()
        };
        let (llm_request, reasoning, sources) = self
            .build_llm_request(&request.message, &context, request.workspace_id)
            .await?;
        let (stream_id, cancel_token) = self.streaming_manager.start_stream(conversation.id).await;
        let engine = self.clone();

        self.streaming_manager
            .register_task(stream_id, async move {
                engine
                    .run_stream(
                        stream_id,
                        cancel_token,
                        conversation.id,
                        llm_request,
                        reasoning,
                        sources,
                        request.workspace_id,
                    )
                    .await;
            })
            .await;

        Ok(CopilotStreamResponse {
            conversation_id: conversation.id,
            stream_id,
        })
    }

    /// Cancels an active streaming response. Duplicate cancels are ignored.
    pub async fn cancel_stream(&self, stream_id: Uuid) -> Result<(), DatabaseError> {
        self.streaming_manager.cancel_stream(stream_id).await;
        Ok(())
    }

    /// Returns current streaming lifecycle and throughput diagnostics.
    pub async fn streaming_diagnostics(&self) -> StreamingDiagnostics {
        self.streaming_manager.diagnostics().await
    }

    /// Generates a response using all available intelligence engines.
    async fn generate_response(
        &self,
        message: &str,
        context: &str,
        workspace_id: Option<Uuid>,
    ) -> Result<ResponseData, DatabaseError> {
        let (llm_request, reasoning, mut sources) = self
            .build_llm_request(message, context, workspace_id)
            .await?;

        let tools = llm_request.tools.clone().unwrap_or_default();
        let messages = llm_request.messages.clone();

        let responder = NonStreamingResponder {
            llm_service: self.llm_service.clone(),
        };
        let response = ToolCallLoop::new(self.tool_executor.clone(), workspace_id, None)
            .run(&responder, messages, tools)
            .await
            .map_err(|error| DatabaseError::IoError(error.to_string()))?;

        let rounds = response.iterations.to_string();

        sources.push(Source {
            source_type: SourceType::ContextMemory,
            title: "AI Assistant".to_string(),
            reference: format!("tool-calling loop ({rounds} rounds)"),
            relevance: 1.0,
        });

        Ok(ResponseData {
            content: response.content,
            reasoning,
            sources,
        })
    }

    #[allow(clippy::too_many_arguments)]
    async fn run_stream(
        &self,
        stream_id: Uuid,
        cancel_token: tokio_util::sync::CancellationToken,
        conversation_id: Uuid,
        llm_request: LLMRequest,
        reasoning: String,
        sources: Vec<Source>,
        workspace_id: Option<Uuid>,
    ) {
        let tools = llm_request.tools.clone().unwrap_or_default();
        let messages = llm_request.messages.clone();

        let responder = StreamingResponder {
            llm_service: self.llm_service.clone(),
            streaming_manager: self.streaming_manager.clone(),
            stream_id,
            conversation_id,
            cancel_token: cancel_token.clone(),
        };

        let result =
            ToolCallLoop::new(self.tool_executor.clone(), workspace_id, Some(cancel_token))
                .run(&responder, messages, tools)
                .await;

        match result {
            Ok(outcome) => {
                self.persist_completed_stream_message(
                    conversation_id,
                    &outcome.content,
                    reasoning,
                    sources,
                    stream_id,
                )
                .await;
            }
            Err(ToolCallLoopError::Cancelled) => {
                self.streaming_manager
                    .cancel_finished_stream(stream_id)
                    .await;
            }
            Err(error) => {
                self.streaming_manager
                    .error_stream(stream_id, error.to_string())
                    .await;
            }
        }
    }

    async fn persist_completed_stream_message(
        &self,
        conversation_id: Uuid,
        content: &str,
        reasoning: String,
        sources: Vec<Source>,
        stream_id: Uuid,
    ) {
        let result = self
            .conversation_manager
            .add_assistant_message(
                conversation_id,
                content,
                Some(reasoning),
                Some(sources),
                None,
            )
            .await;

        match result {
            Ok(message) => {
                self.streaming_manager
                    .finish_stream(stream_id, message.id)
                    .await;
            }
            Err(error) => {
                self.streaming_manager
                    .error_stream(stream_id, error.to_string())
                    .await
            }
        }
    }

    async fn build_llm_request(
        &self,
        message: &str,
        context: &str,
        workspace_id: Option<Uuid>,
    ) -> Result<(LLMRequest, String, Vec<Source>), DatabaseError> {
        let mut sources = Vec::new();
        let mut reasoning_parts = Vec::new();

        if !self.llm_service.is_configured() {
            return Err(DatabaseError::IoError(
                "AI provider not configured. Please configure your API settings in the settings page to enable AI-powered responses.".to_string(),
            ));
        }

        let intent = self.classify_intent(message);
        reasoning_parts.push(format!("Intent classified as: {:?}", intent));

        let tool_data = match intent {
            Intent::ListWorkspaces => {
                reasoning_parts.push("Fetching workspace list".to_string());
                Some(self.gather_workspace_list(&mut sources).await?)
            }
            Intent::GetWorkspaceInfo if workspace_id.is_some() => {
                reasoning_parts.push("Retrieving workspace information".to_string());
                Some(
                    self.gather_workspace_info(workspace_id.unwrap(), &mut sources)
                        .await?,
                )
            }
            Intent::SearchHistory => {
                reasoning_parts.push("Searching timeline history".to_string());
                Some(
                    self.gather_timeline_search(message, workspace_id, &mut sources)
                        .await?,
                )
            }
            Intent::SummarizeActivity => {
                reasoning_parts.push("Generating activity summary".to_string());
                Some(
                    self.gather_activity_summary(workspace_id, &mut sources)
                        .await?,
                )
            }
            Intent::ExplainRecommendation if workspace_id.is_some() => {
                reasoning_parts.push("Fetching recommendations".to_string());
                Some(
                    self.gather_recommendations(workspace_id.unwrap(), &mut sources)
                        .await?,
                )
            }
            Intent::ResumeWork if workspace_id.is_some() => {
                reasoning_parts.push("Fetching session context".to_string());
                Some(
                    self.gather_resume_context(workspace_id.unwrap(), &mut sources)
                        .await?,
                )
            }
            _ => None,
        };

        let system_prompt = self.build_system_prompt(workspace_id, context);
        let user_prompt = if let Some(data) = tool_data {
            format!("{}\n\nRelevant data:\n{}", message, data)
        } else {
            message.to_string()
        };

        let tool_definitions = build_tool_schemas(self.tool_executor.available_tools());

        Ok((
            LLMRequest {
                messages: vec![
                    LLMMessage::new("system", system_prompt),
                    LLMMessage::new("user", user_prompt),
                ],
                temperature: Some(0.7),
                max_tokens: Some(1000),
                top_p: Some(1.0),
                stream: Some(true),
                tools: if tool_definitions.is_empty() {
                    None
                } else {
                    Some(tool_definitions)
                },
            },
            reasoning_parts.join(" → "),
            sources,
        ))
    }

    /// Builds the system prompt for the LLM
    fn build_system_prompt(&self, workspace_id: Option<Uuid>, context: &str) -> String {
        let mut prompt = String::from(
            "You are ContextSphere AI Copilot, an intelligent workspace assistant that helps users manage their projects and work.\n\n\
            You have access to the user's workspace activity, timeline events, files, and work patterns.\n\n\
            Your role is to:\n\
            - Answer questions about workspace activity and history\n\
            - Provide insights and recommendations\n\
            - Help users navigate their work context\n\
            - Suggest relevant actions and next steps\n\n\
            Be concise, helpful, and conversational. Use the provided data to give accurate, context-aware responses.\n"
        );

        if let Some(ws_id) = workspace_id {
            prompt.push_str(&format!("\nCurrent workspace: {}\n", ws_id));
        }

        if !context.is_empty() {
            prompt.push_str(&format!("\nWorkspace context:\n{}\n", context));
        }

        prompt
    }

    /// Classifies user intent.
    fn classify_intent(&self, message: &str) -> Intent {
        let message_lower = message.to_lowercase();

        if message_lower.contains("list") && message_lower.contains("workspace") {
            Intent::ListWorkspaces
        } else if message_lower.contains("what") && message_lower.contains("workspace") {
            Intent::GetWorkspaceInfo
        } else if message_lower.contains("search") || message_lower.contains("find") {
            Intent::SearchHistory
        } else if message_lower.contains("summarize")
            || message_lower.contains("summary")
            || message_lower.contains("what did i")
        {
            Intent::SummarizeActivity
        } else if message_lower.contains("why") || message_lower.contains("explain") {
            Intent::ExplainRecommendation
        } else if message_lower.contains("resume")
            || message_lower.contains("continue")
            || message_lower.contains("back to")
        {
            Intent::ResumeWork
        } else if message_lower.starts_with("what")
            || message_lower.starts_with("how")
            || message_lower.starts_with("when")
            || message_lower.starts_with("where")
        {
            Intent::AskQuestion
        } else {
            Intent::Unknown
        }
    }

    /// Gathers workspace list data
    async fn gather_workspace_list(
        &self,
        sources: &mut Vec<Source>,
    ) -> Result<String, DatabaseError> {
        let result = self
            .tool_executor
            .execute_tool("list_workspaces", &serde_json::json!({}))
            .await?;

        let workspaces: Vec<serde_json::Value> =
            serde_json::from_value(result).map_err(|e| DatabaseError::IoError(e.to_string()))?;

        sources.push(Source {
            source_type: SourceType::WorkspaceFile,
            title: "Workspace Database".to_string(),
            reference: "workspaces table".to_string(),
            relevance: 1.0,
        });

        if workspaces.is_empty() {
            Ok("No workspaces found.".to_string())
        } else {
            let mut response = format!("Workspaces ({}):\n", workspaces.len());
            for ws in workspaces.iter().take(10) {
                let name = ws.get("name").and_then(|v| v.as_str()).unwrap_or("Unknown");
                let status = ws
                    .get("status")
                    .and_then(|v| v.as_str())
                    .unwrap_or("unknown");
                response.push_str(&format!("- {} (status: {})\n", name, status));
            }
            if workspaces.len() > 10 {
                response.push_str(&format!("...and {} more\n", workspaces.len() - 10));
            }
            Ok(response)
        }
    }

    /// Gathers workspace info data
    async fn gather_workspace_info(
        &self,
        workspace_id: Uuid,
        sources: &mut Vec<Source>,
    ) -> Result<String, DatabaseError> {
        let result = self
            .tool_executor
            .execute_tool(
                "get_workspace",
                &serde_json::json!({
                    "workspace_id": workspace_id.to_string()
                }),
            )
            .await?;

        let workspace: serde_json::Value = result;
        let name = workspace
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("Unknown");
        let status = workspace
            .get("status")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown");
        let path = workspace
            .get("root_path")
            .and_then(|v| v.as_str())
            .unwrap_or("Unknown");

        sources.push(Source {
            source_type: SourceType::WorkspaceFile,
            title: format!("Workspace: {}", name),
            reference: workspace_id.to_string(),
            relevance: 1.0,
        });

        Ok(format!(
            "Workspace: {}\nStatus: {}\nPath: {}",
            name, status, path
        ))
    }

    /// Gathers timeline search data
    async fn gather_timeline_search(
        &self,
        query: &str,
        workspace_id: Option<Uuid>,
        sources: &mut Vec<Source>,
    ) -> Result<String, DatabaseError> {
        // Extract search terms (simple implementation)
        let search_terms: Vec<&str> = query
            .split_whitespace()
            .filter(|w| w.len() > 3 && !["search", "find", "show", "what"].contains(w))
            .collect();

        let search_query = search_terms.join(" ");

        if search_query.is_empty() {
            return Ok("No search terms specified.".to_string());
        }

        let result = self
            .tool_executor
            .execute_tool(
                "search_timeline",
                &serde_json::json!({
                    "query": search_query,
                    "workspace_id": workspace_id.map(|id| id.to_string())
                }),
            )
            .await?;

        let events: Vec<serde_json::Value> =
            serde_json::from_value(result).map_err(|e| DatabaseError::IoError(e.to_string()))?;

        sources.push(Source {
            source_type: SourceType::TimelineEvent,
            title: "Timeline Events".to_string(),
            reference: format!("{} events found", events.len()),
            relevance: 0.9,
        });

        if events.is_empty() {
            Ok(format!("No events found matching '{}'", search_query))
        } else {
            let mut response = format!("Found {} events for '{}':\n", events.len(), search_query);
            for event in events.iter().take(10) {
                let event_type = event
                    .get("event_type")
                    .and_then(|v| v.as_str())
                    .unwrap_or("unknown");
                let file_path = event
                    .get("file_path")
                    .and_then(|v| v.as_str())
                    .unwrap_or("N/A");
                response.push_str(&format!("- {}: {}\n", event_type, file_path));
            }
            if events.len() > 10 {
                response.push_str(&format!("...and {} more\n", events.len() - 10));
            }
            Ok(response)
        }
    }

    /// Gathers activity summary data
    async fn gather_activity_summary(
        &self,
        workspace_id: Option<Uuid>,
        sources: &mut Vec<Source>,
    ) -> Result<String, DatabaseError> {
        let result = self
            .tool_executor
            .execute_tool(
                "get_recent_events",
                &serde_json::json!({
                    "workspace_id": workspace_id.map(|id| id.to_string()),
                    "limit": 20
                }),
            )
            .await?;

        let events: Vec<serde_json::Value> =
            serde_json::from_value(result).map_err(|e| DatabaseError::IoError(e.to_string()))?;

        if events.is_empty() {
            return Ok("No recent activity.".to_string());
        }

        sources.push(Source {
            source_type: SourceType::TimelineEvent,
            title: "Recent Timeline Events".to_string(),
            reference: format!("{} events", events.len()),
            relevance: 1.0,
        });

        // Analyze event types
        let mut event_counts: std::collections::HashMap<String, usize> =
            std::collections::HashMap::new();
        let mut files: std::collections::HashSet<String> = std::collections::HashSet::new();

        for event in &events {
            if let Some(event_type) = event.get("event_type").and_then(|v| v.as_str()) {
                *event_counts.entry(event_type.to_string()).or_insert(0) += 1;
            }
            if let Some(file_path) = event.get("file_path").and_then(|v| v.as_str()) {
                files.insert(file_path.to_string());
            }
        }

        let mut summary = format!("Recent activity ({} events):\n", events.len());
        summary.push_str(&format!("- {} unique files\n", files.len()));

        for (event_type, count) in event_counts.iter() {
            summary.push_str(&format!("- {} {} events\n", count, event_type));
        }

        Ok(summary)
    }

    /// Gathers recommendations data
    async fn gather_recommendations(
        &self,
        workspace_id: Uuid,
        sources: &mut Vec<Source>,
    ) -> Result<String, DatabaseError> {
        // Get recommendations
        let recommendations = self
            .recommendation_engine
            .generate_recommendations(workspace_id)
            .await?;

        if recommendations.is_empty() {
            return Ok("No recommendations available yet.".to_string());
        }

        sources.push(Source {
            source_type: SourceType::ContextMemory,
            title: "Recommendation Engine".to_string(),
            reference: format!("{} recommendations", recommendations.len()),
            relevance: 0.95,
        });

        let mut response = format!("Recommendations ({}):\n", recommendations.len());
        for rec in recommendations.iter().take(5) {
            response.push_str(&format!(
                "- {} (confidence: {:.0}%)\n  {}\n",
                rec.title,
                rec.confidence * 100.0,
                rec.description
            ));
        }

        Ok(response)
    }

    /// Gathers resume context data
    async fn gather_resume_context(
        &self,
        workspace_id: Uuid,
        sources: &mut Vec<Source>,
    ) -> Result<String, DatabaseError> {
        // Get session summary
        let summary_result = self
            .tool_executor
            .execute_tool(
                "get_session_summary",
                &serde_json::json!({
                    "workspace_id": workspace_id.to_string()
                }),
            )
            .await;

        sources.push(Source {
            source_type: SourceType::SessionHistory,
            title: "Session Summary".to_string(),
            reference: workspace_id.to_string(),
            relevance: 0.9,
        });

        if let Ok(summary) = summary_result {
            Ok(format!(
                "Session context:\n{}",
                serde_json::to_string_pretty(&summary).unwrap_or_default()
            ))
        } else {
            Ok("No previous session context available.".to_string())
        }
    }

    /// Generates suggested actions based on the message.
    async fn generate_suggested_actions(
        &self,
        _message: &str,
        workspace_id: Option<Uuid>,
    ) -> Result<Vec<SuggestedAction>, DatabaseError> {
        let mut actions = Vec::new();

        if workspace_id.is_some() {
            actions.push(SuggestedAction {
                title: "View Recent Activity".to_string(),
                description: "See recent timeline events in this workspace".to_string(),
                tool_name: "get_recent_events".to_string(),
                arguments: serde_json::json!({
                    "workspace_id": workspace_id.map(|id| id.to_string()),
                    "limit": 10
                }),
                requires_confirmation: false,
            });
        }

        actions.push(SuggestedAction {
            title: "List All Workspaces".to_string(),
            description: "Show all available workspaces".to_string(),
            tool_name: "list_workspaces".to_string(),
            arguments: serde_json::json!({}),
            requires_confirmation: false,
        });

        Ok(actions)
    }

    /// Generates a daily briefing.
    pub async fn get_daily_briefing(
        &self,
        workspace_id: Option<Uuid>,
    ) -> Result<DailyBriefing, DatabaseError> {
        let date = Utc::now();

        // Get today's events
        let events = if let Some(ws_id) = workspace_id {
            self.timeline_engine.recent_events(ws_id, Some(100), None).await?
        } else {
            Vec::new()
        };

        let today_events: Vec<_> = events
            .iter()
            .filter(|e| e.occurred_at.date_naive() == date.date_naive())
            .collect();

        let files_modified: std::collections::HashSet<_> = today_events
            .iter()
            .filter_map(|e| e.file_id.as_ref())
            .collect();

        let summary = if today_events.is_empty() {
            "No activity recorded today yet.".to_string()
        } else {
            format!(
                "Today you've worked on {} files with {} events recorded.",
                files_modified.len(),
                today_events.len()
            )
        };

        let highlights = vec![
            format!("{} timeline events", today_events.len()),
            format!("{} files modified", files_modified.len()),
        ];

        // Get recommendations
        let recommendations = if let Some(ws_id) = workspace_id {
            let recs = self
                .recommendation_engine
                .generate_recommendations(ws_id)
                .await?;
            recs.into_iter().take(3).map(|r| r.title).collect()
        } else {
            vec![]
        };

        Ok(DailyBriefing {
            date,
            summary,
            highlights,
            pending_tasks: vec![],
            recommendations,
            workspace_stats: WorkspaceStats {
                active_workspaces: 1,
                files_modified: files_modified.len(),
                time_tracked: 0,
                sessions_completed: 0,
            },
        })
    }

    /// Gets conversation history.
    pub async fn get_conversation_history(
        &self,
        conversation_id: Uuid,
    ) -> Result<Vec<Message>, DatabaseError> {
        self.conversation_manager
            .get_conversation_history(conversation_id, None)
            .await
    }

    /// Gets recent conversations.
    pub async fn get_recent_conversations(
        &self,
        limit: usize,
    ) -> Result<Vec<Conversation>, DatabaseError> {
        self.repository.get_recent_conversations(limit).await
    }

    /// Searches conversations using repository-backed filters.
    pub async fn search_conversations(
        &self,
        request: ConversationSearchRequest,
    ) -> Result<Vec<ConversationSearchResult>, DatabaseError> {
        self.repository.search_conversations(request).await
    }
}

/// Streaming responder that re-emits text chunks to the frontend while
/// returning the aggregated, complete response to the tool loop.
struct StreamingResponder {
    llm_service: Arc<LLMService>,
    streaming_manager: Arc<StreamingSessionManager>,
    stream_id: Uuid,
    conversation_id: Uuid,
    cancel_token: tokio_util::sync::CancellationToken,
}

#[async_trait]
impl ToolCallResponder for StreamingResponder {
    async fn respond(&self, request: LLMRequest) -> Result<LLMResponse, ToolCallLoopError> {
        let mut stream = self
            .llm_service
            .complete_stream(request)
            .await
            .map_err(ToolCallLoopError::Responder)?;

        let mut content = String::new();
        let mut first_token_recorded = false;

        loop {
            tokio::select! {
                _ = self.cancel_token.cancelled() => {
                    return Err(ToolCallLoopError::Cancelled);
                }
                next = stream.next() => {
                    match next {
                        Some(StreamEvent::Chunk(chunk)) => {
                            if !first_token_recorded {
                                self.streaming_manager.record_first_token(self.stream_id).await;
                                first_token_recorded = true;
                            }
                            content.push_str(&chunk.content);
                            self.streaming_manager
                                .emit_chunk(self.stream_id, self.conversation_id, chunk.content);
                        }
                        Some(StreamEvent::Done(response)) => {
                            return Ok(response);
                        }
                        Some(StreamEvent::Error(error)) => {
                            return Err(ToolCallLoopError::Responder(error));
                        }
                        None => {
                            return Ok(LLMResponse {
                                content,
                                usage: Default::default(),
                                model: String::new(),
                                finish_reason: None,
                                tool_calls: None,
                            });
                        }
                    }
                }
            }
        }
    }
}

/// Non-streaming responder used by the buffered (non-streamed) response.
struct NonStreamingResponder {
    llm_service: Arc<LLMService>,
}

#[async_trait]
impl ToolCallResponder for NonStreamingResponder {
    async fn respond(&self, request: LLMRequest) -> Result<LLMResponse, ToolCallLoopError> {
        self.llm_service
            .complete(request, None)
            .await
            .map_err(ToolCallLoopError::Responder)
    }
}

/// User intent classification.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Intent {
    ListWorkspaces,
    GetWorkspaceInfo,
    SearchHistory,
    SummarizeActivity,
    ExplainRecommendation,
    ResumeWork,
    AskQuestion,
    Unknown,
}

/// Internal response data structure.
struct ResponseData {
    content: String,
    reasoning: String,
    sources: Vec<Source>,
}
