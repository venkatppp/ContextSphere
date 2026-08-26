use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use tokio::sync::broadcast;
use uuid::Uuid;

use super::metrics::{ToolDiagnostics, ToolMetricsCollector};
use super::models::{
    ToolDefinition, ToolInvocationRequest, ToolInvocationResult, ToolParameter, ToolParameterType,
    ToolPermissionDecision, ToolPermissionLevel, ToolProgressEvent, EVENT_TOOL_PROGRESS,
};
use super::permissions::ToolPermissionService;
use super::registry::{build_registry, ToolHandler};
use crate::app_events::{emit, AppEventEmitter};
use crate::errors::DatabaseError;
use crate::services::WorkspaceService;
use crate::session::SessionEngine;
use crate::timeline::TimelineEngine;

const TOOL_PROGRESS_BUFFER: usize = 256;

/// Tool executor that safely invokes registered copilot tools.
pub struct ToolExecutor {
    workspace_service: Arc<WorkspaceService>,
    session_engine: Arc<SessionEngine>,
    timeline_engine: Arc<TimelineEngine>,
    registry: HashMap<String, ToolHandler>,
    progress_tx: broadcast::Sender<ToolProgressEvent>,
    event_emitter: Option<Arc<dyn AppEventEmitter>>,
    metrics: Arc<ToolMetricsCollector>,
    permission_service: Option<Arc<ToolPermissionService>>,
}

impl ToolExecutor {
    /// Creates a new tool executor.
    pub fn new(
        workspace_service: Arc<WorkspaceService>,
        session_engine: Arc<SessionEngine>,
        timeline_engine: Arc<TimelineEngine>,
    ) -> Self {
        let (progress_tx, _) = broadcast::channel(TOOL_PROGRESS_BUFFER);

        Self {
            workspace_service,
            session_engine,
            timeline_engine,
            registry: build_registry(),
            progress_tx,
            event_emitter: None,
            metrics: Arc::new(ToolMetricsCollector::default()),
            permission_service: None,
        }
    }

    /// Attaches a frontend event emitter for streamed tool progress.
    pub fn with_event_emitter(mut self, emitter: Arc<dyn AppEventEmitter>) -> Self {
        self.event_emitter = Some(emitter);
        self
    }

    /// Attaches the persistent permission policy service used to gate
    /// tool invocations.
    pub fn with_permission_service(mut self, service: Arc<ToolPermissionService>) -> Self {
        self.permission_service = Some(service);
        self
    }

    /// Executes a tool and returns only the raw tool payload.
    pub async fn execute_tool(
        &self,
        tool_name: &str,
        arguments: &serde_json::Value,
    ) -> Result<serde_json::Value, DatabaseError> {
        let result = self.invoke_tool(tool_name, arguments.clone()).await?;
        result.into_database_result()
    }

    /// Runs a complete invocation pipeline with validation, permission checks,
    /// timeout, retries, progress events, and structured results.
    pub async fn invoke_tool(
        &self,
        tool_name: &str,
        arguments: serde_json::Value,
    ) -> Result<ToolInvocationResult, DatabaseError> {
        self.invoke_tool_with_context(ToolInvocationRequest {
            tool_name: tool_name.to_string(),
            arguments,
            workspace_id: None,
            cancellation_token: None,
        })
        .await
    }

    /// Runs a tool invocation with caller-provided execution context.
    pub async fn invoke_tool_with_context(
        &self,
        request: ToolInvocationRequest,
    ) -> Result<ToolInvocationResult, DatabaseError> {
        let handler = self.handler(&request.tool_name)?;
        let invocation_id = Uuid::new_v4();
        let started_at = Utc::now();
        let started_instant = Instant::now();

        self.validate_arguments(&handler.definition, &request.arguments)?;
        self.ensure_permission(&handler.definition)?;
        if let Some(result) = self
            .apply_runtime_policy(
                &handler.definition,
                &request,
                invocation_id,
                started_at,
                started_instant,
            )
            .await
        {
            return Ok(result);
        }
        self.metrics.record_invocation();
        self.emit_progress(ToolProgressEvent::started(
            invocation_id,
            &handler.definition.name,
            started_at,
        ));

        let max_attempts = handler.definition.retry_policy.max_attempts.max(1);
        let mut attempt = 1;
        let mut last_error = None;

        while attempt <= max_attempts {
            if let Some(token) = &request.cancellation_token {
                if token.is_cancelled() {
                    let result = ToolInvocationResult::cancelled(
                        invocation_id,
                        handler.definition.name.clone(),
                        request.arguments.clone(),
                        started_at,
                        started_instant.elapsed(),
                    );
                    self.metrics.record_cancelled(started_instant.elapsed());
                    self.emit_progress(ToolProgressEvent::from_result(&result));
                    return Ok(result);
                }
            }

            self.emit_progress(ToolProgressEvent::running(
                invocation_id,
                &handler.definition.name,
                attempt,
                max_attempts,
            ));

            let execute = (handler.execute)(self, &request.arguments, request.workspace_id);
            let timeout = Duration::from_millis(handler.definition.timeout_ms);
            let attempt_result = if let Some(token) = &request.cancellation_token {
                tokio::select! {
                    _ = token.cancelled() => Err(DatabaseError::IoError("tool invocation cancelled".to_string())),
                    result = tokio::time::timeout(timeout, execute) => result.map_err(|_| timeout_error(&handler.definition))?,
                }
            } else {
                tokio::time::timeout(timeout, execute)
                    .await
                    .map_err(|_| timeout_error(&handler.definition))?
            };

            match attempt_result {
                Ok(value) => {
                    let result = ToolInvocationResult::success(
                        invocation_id,
                        handler.definition.name.clone(),
                        request.arguments,
                        value,
                        started_at,
                        started_instant.elapsed(),
                        attempt,
                    );
                    self.metrics.record_success(started_instant.elapsed());
                    self.emit_progress(ToolProgressEvent::from_result(&result));
                    return Ok(result);
                }
                Err(error)
                    if attempt < max_attempts && handler.definition.retry_policy.retryable =>
                {
                    last_error = Some(error.to_string());
                    self.metrics.record_retry();
                    tokio::time::sleep(Duration::from_millis(
                        handler.definition.retry_policy.backoff_ms * attempt as u64,
                    ))
                    .await;
                }
                Err(error) => {
                    last_error = Some(error.to_string());
                    break;
                }
            }

            attempt += 1;
        }

        let result = ToolInvocationResult::failed(
            invocation_id,
            handler.definition.name.clone(),
            request.arguments,
            last_error.unwrap_or_else(|| "tool invocation failed".to_string()),
            started_at,
            started_instant.elapsed(),
            attempt.min(max_attempts),
        );
        self.metrics.record_failure(started_instant.elapsed());
        self.emit_progress(ToolProgressEvent::from_result(&result));
        Ok(result)
    }

    /// Executes independent tools concurrently and returns structured results
    /// in the same order as the requests.
    pub async fn invoke_tools_parallel(
        &self,
        requests: Vec<ToolInvocationRequest>,
    ) -> Vec<Result<ToolInvocationResult, DatabaseError>> {
        futures::future::join_all(
            requests
                .into_iter()
                .map(|request| self.invoke_tool_with_context(request)),
        )
        .await
    }

    /// Checks if a tool requires user confirmation.
    pub fn requires_confirmation(&self, tool_name: &str) -> bool {
        self.registry
            .get(tool_name)
            .map(|handler| handler.definition.requires_confirmation)
            .unwrap_or(false)
    }

    /// Returns registry-backed tool definitions.
    pub fn available_tools(&self) -> Vec<ToolDefinition> {
        sorted_definitions(
            self.registry
                .values()
                .map(|handler| handler.definition.clone()),
        )
    }

    /// Subscribes to tool progress events.
    pub fn subscribe_progress(&self) -> broadcast::Receiver<ToolProgressEvent> {
        self.progress_tx.subscribe()
    }

    /// Returns aggregate tool diagnostics.
    pub fn diagnostics(&self) -> ToolDiagnostics {
        self.metrics.diagnostics(self.registry.len())
    }

    /// Backwards-compatible static metadata for IPC callers that do not hold state.
    pub fn get_available_tools() -> Vec<ToolDefinition> {
        sorted_definitions(
            build_registry()
                .into_values()
                .map(|handler| handler.definition),
        )
    }

    fn handler(&self, tool_name: &str) -> Result<&ToolHandler, DatabaseError> {
        self.registry
            .get(tool_name)
            .ok_or_else(|| DatabaseError::InvalidInput(format!("Unknown tool: {}", tool_name)))
    }

    fn validate_arguments(
        &self,
        definition: &ToolDefinition,
        arguments: &serde_json::Value,
    ) -> Result<(), DatabaseError> {
        let object = arguments.as_object().ok_or_else(|| {
            DatabaseError::InvalidInput(format!(
                "tool '{}' arguments must be a JSON object",
                definition.name
            ))
        })?;

        for parameter in &definition.parameters {
            let value = object.get(&parameter.name);
            if parameter.required && value.is_none() {
                return Err(DatabaseError::InvalidInput(format!(
                    "tool '{}' missing required argument '{}'",
                    definition.name, parameter.name
                )));
            }

            if let Some(value) = value {
                validate_parameter_type(&definition.name, parameter, value)?;
            }
        }

        Ok(())
    }

    fn ensure_permission(&self, definition: &ToolDefinition) -> Result<(), DatabaseError> {
        if definition.permission.required_level == ToolPermissionLevel::Denied {
            return Err(DatabaseError::InvalidInput(format!(
                "tool '{}' is not permitted",
                definition.name
            )));
        }
        Ok(())
    }

    /// Applies the persisted runtime policy for a tool, if one is
    /// attached. Returns a structured result when the invocation must
    /// stop (denied), and `None` to continue. Respects the static
    /// registry permission metadata at all times.
    async fn apply_runtime_policy(
        &self,
        definition: &ToolDefinition,
        request: &ToolInvocationRequest,
        invocation_id: Uuid,
        started_at: DateTime<Utc>,
        started_instant: Instant,
    ) -> Option<ToolInvocationResult> {
        let permission_service = self.permission_service.as_ref()?;
        let policy = permission_service
            .resolve_policy(&request.tool_name, request.workspace_id)
            .await?;

        match policy.decision {
            ToolPermissionDecision::AlwaysAllow => None,
            ToolPermissionDecision::AllowOnce => {
                if let Err(error) = permission_service.consume_policy(&policy).await {
                    let result = ToolInvocationResult::failed(
                        invocation_id,
                        definition.name.clone(),
                        request.arguments.clone(),
                        format!("failed to consume allow-once policy: {error}"),
                        started_at,
                        started_instant.elapsed(),
                        0,
                    );
                    self.metrics.record_failure(started_instant.elapsed());
                    self.emit_progress(ToolProgressEvent::from_result(&result));
                    Some(result)
                } else {
                    None
                }
            }
            ToolPermissionDecision::Deny => {
                let result = ToolInvocationResult::failed(
                    invocation_id,
                    definition.name.clone(),
                    request.arguments.clone(),
                    format!(
                        "tool '{}' is denied by a permission policy",
                        definition.name
                    ),
                    started_at,
                    started_instant.elapsed(),
                    0,
                );
                self.metrics.record_failure(started_instant.elapsed());
                self.emit_progress(ToolProgressEvent::from_result(&result));
                Some(result)
            }
        }
    }

    fn emit_progress(&self, event: ToolProgressEvent) {
        let _ = self.progress_tx.send(event.clone());
        if let Some(emitter) = &self.event_emitter {
            emit(emitter.as_ref(), EVENT_TOOL_PROGRESS, &event);
        }
    }

    pub(super) async fn list_workspaces(
        &self,
        _arguments: &serde_json::Value,
    ) -> Result<serde_json::Value, DatabaseError> {
        let workspaces = self.workspace_service.list_active_workspaces().await?;
        serde_json::to_value(workspaces).map_err(|e| DatabaseError::IoError(e.to_string()))
    }

    pub(super) async fn get_workspace(
        &self,
        arguments: &serde_json::Value,
    ) -> Result<serde_json::Value, DatabaseError> {
        let workspace_id = arguments
            .get("workspace_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| DatabaseError::InvalidInput("Missing workspace_id".to_string()))?;
        let workspace_uuid = Uuid::parse_str(workspace_id)
            .map_err(|e| DatabaseError::InvalidInput(e.to_string()))?;
        let workspace = self.workspace_service.get_workspace(workspace_uuid).await?;

        serde_json::to_value(workspace).map_err(|e| DatabaseError::IoError(e.to_string()))
    }

    pub(super) async fn get_active_workspace(
        &self,
        _arguments: &serde_json::Value,
    ) -> Result<serde_json::Value, DatabaseError> {
        let session = self
            .session_engine
            .get_most_recent_active_session(None)
            .await?;

        if let Some(sess) = session {
            let workspace = self
                .workspace_service
                .get_workspace(sess.workspace_id)
                .await?;
            Ok(serde_json::to_value(workspace)
                .map_err(|e| DatabaseError::IoError(e.to_string()))?)
        } else {
            Ok(serde_json::json!(null))
        }
    }

    pub(super) async fn get_recent_events(
        &self,
        arguments: &serde_json::Value,
        context_workspace_id: Option<Uuid>,
    ) -> Result<serde_json::Value, DatabaseError> {
        let workspace_id = optional_uuid(arguments, "workspace_id")?.or(context_workspace_id);
        let limit = arguments
            .get("limit")
            .and_then(|v| v.as_u64())
            .map(|l| l as i64);
        let events = if let Some(ws_id) = workspace_id {
            self.timeline_engine.recent_events(ws_id, limit, None).await?
        } else {
            Vec::new()
        };

        serde_json::to_value(events).map_err(|e| DatabaseError::IoError(e.to_string()))
    }

    pub(super) async fn search_timeline(
        &self,
        arguments: &serde_json::Value,
        context_workspace_id: Option<Uuid>,
    ) -> Result<serde_json::Value, DatabaseError> {
        let query = arguments
            .get("query")
            .and_then(|v| v.as_str())
            .ok_or_else(|| DatabaseError::InvalidInput("Missing query".to_string()))?;
        let workspace_id = optional_uuid(arguments, "workspace_id")?.or(context_workspace_id);
        let events = if let Some(ws_id) = workspace_id {
            self.timeline_engine.recent_events(ws_id, Some(100), None).await?
        } else {
            Vec::new()
        };

        let query_lower = query.to_lowercase();
        let filtered: Vec<_> = events
            .into_iter()
            .filter(|event| {
                format!("{:?}", event.event_type)
                    .to_lowercase()
                    .contains(&query_lower)
            })
            .take(20)
            .collect();

        serde_json::to_value(filtered).map_err(|e| DatabaseError::IoError(e.to_string()))
    }

    pub(super) async fn get_session_summary(
        &self,
        arguments: &serde_json::Value,
        context_workspace_id: Option<Uuid>,
    ) -> Result<serde_json::Value, DatabaseError> {
        let workspace_id = optional_uuid(arguments, "workspace_id")?.or(context_workspace_id);

        if let Some(ws_id) = workspace_id {
            if let Some(session) = self.session_engine.get_latest_session(ws_id, None).await? {
                let workspace = self.workspace_service.get_workspace(ws_id).await?;
                let summary = self
                    .session_engine
                    .get_session_summary(&session, workspace.name)
                    .await?;
                Ok(serde_json::to_value(summary)
                    .map_err(|e| DatabaseError::IoError(e.to_string()))?)
            } else {
                Ok(serde_json::json!({ "message": "No session found for this workspace" }))
            }
        } else {
            Ok(serde_json::json!({ "message": "No workspace specified" }))
        }
    }

    pub(super) async fn resume_workspace(
        &self,
        arguments: &serde_json::Value,
    ) -> Result<serde_json::Value, DatabaseError> {
        let workspace_id = arguments
            .get("workspace_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| DatabaseError::InvalidInput("Missing workspace_id".to_string()))?;
        let workspace_uuid = Uuid::parse_str(workspace_id)
            .map_err(|e| DatabaseError::InvalidInput(e.to_string()))?;
        self.workspace_service
            .open_workspace(workspace_uuid)
            .await?;

        Ok(serde_json::json!({
            "success": true,
            "message": "Workspace activated successfully"
        }))
    }
}

fn sorted_definitions(tools: impl Iterator<Item = ToolDefinition>) -> Vec<ToolDefinition> {
    let mut tools: Vec<_> = tools.collect();
    tools.sort_by(|a, b| a.name.cmp(&b.name));
    tools
}

fn optional_uuid(arguments: &serde_json::Value, name: &str) -> Result<Option<Uuid>, DatabaseError> {
    arguments
        .get(name)
        .and_then(|v| v.as_str())
        .map(Uuid::parse_str)
        .transpose()
        .map_err(|e| DatabaseError::InvalidInput(e.to_string()))
}

fn validate_parameter_type(
    tool_name: &str,
    parameter: &ToolParameter,
    value: &serde_json::Value,
) -> Result<(), DatabaseError> {
    let valid = match parameter.parameter_type {
        ToolParameterType::String => value.is_string() || value.is_null() && !parameter.required,
        ToolParameterType::Number => value.is_number() || value.is_null() && !parameter.required,
        ToolParameterType::Boolean => value.is_boolean() || value.is_null() && !parameter.required,
        ToolParameterType::Object => value.is_object() || value.is_null() && !parameter.required,
        ToolParameterType::Array => value.is_array() || value.is_null() && !parameter.required,
    };

    if valid {
        Ok(())
    } else {
        Err(DatabaseError::InvalidInput(format!(
            "tool '{}' argument '{}' must be {}",
            tool_name, parameter.name, parameter.param_type
        )))
    }
}

fn timeout_error(definition: &ToolDefinition) -> DatabaseError {
    DatabaseError::IoError(format!(
        "tool '{}' timed out after {}ms",
        definition.name, definition.timeout_ms
    ))
}
