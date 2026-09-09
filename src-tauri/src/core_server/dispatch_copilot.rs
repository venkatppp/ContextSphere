//! Copilot / proactive / conversation / execution / autonomous dispatch.

use std::sync::Arc;

use serde_json::Value;
use tauri::{AppHandle, Manager};

use crate::core_server::{pget, RpcError, rpc_state};

use crate::copilot::autonomous::models::ExecutionPolicy;
use crate::copilot::autonomous::runtime::AutonomousRuntime;
use crate::copilot::engine::CopilotEngine;
use crate::copilot::execution_engine::ExecutionEngine;
use crate::copilot::models::{
    ConversationSearchRequest, DailyBriefingRequest, SendMessageRequest, WorkspaceQuestionRequest,
};
use crate::copilot::proactive_engine::ProactiveEngine;
use crate::copilot::proactive_models::{ExecutionPlan, PermissionLevel};
use crate::copilot::tools::{ToolExecutor, ToolPermissionDecision, ToolPermissionService};
use crate::copilot::CopilotRepository;

pub async fn dispatch_copilot(
    app: &AppHandle,
    method: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    let result: Value = match method {
        // ------------------------------------------------------------ copilot
        "copilot_send_message" => rpc_state!(app, params, Arc<CopilotEngine>, crate::commands::copilot::copilot_send_message, ("request": SendMessageRequest)),
        "copilot_send_message_stream" => rpc_state!(app, params, Arc<CopilotEngine>, crate::commands::copilot::copilot_send_message_stream, ("request": SendMessageRequest)),
        "copilot_cancel_stream" => rpc_state!(app, params, Arc<CopilotEngine>, crate::commands::copilot::copilot_cancel_stream, ("stream_id": String)),
        "copilot_get_streaming_diagnostics" => rpc_state!(app, params, Arc<CopilotEngine>, crate::commands::copilot::copilot_get_streaming_diagnostics, ()),
        "copilot_get_conversation" => rpc_state!(app, params, Arc<CopilotEngine>, crate::commands::copilot::copilot_get_conversation, ("conversation_id": String)),
        "copilot_get_recent_conversations" => rpc_state!(app, params, Arc<CopilotEngine>, crate::commands::copilot::copilot_get_recent_conversations, ("limit": usize)),
        "copilot_search_conversations" => rpc_state!(app, params, Arc<CopilotEngine>, crate::commands::copilot::copilot_search_conversations, ("request": ConversationSearchRequest)),
        "copilot_get_daily_briefing" => rpc_state!(app, params, Arc<CopilotEngine>, crate::commands::copilot::copilot_get_daily_briefing, ("request": DailyBriefingRequest)),
        "copilot_get_tools" => {
            let r = crate::commands::copilot::copilot_get_tools().await;
            serde_json::to_value(r).map_err(|e| RpcError::message(e.to_string()))?
        }
        "copilot_discover_tools" => rpc_state!(app, params, Arc<ToolExecutor>, crate::commands::copilot::copilot_discover_tools, ()),
        "copilot_get_tool_diagnostics" => rpc_state!(app, params, Arc<ToolExecutor>, crate::commands::copilot::copilot_get_tool_diagnostics, ()),
        "copilot_ask_question" => rpc_state!(app, params, Arc<CopilotEngine>, crate::commands::copilot::copilot_ask_question, ("request": WorkspaceQuestionRequest)),
        "copilot_list_tool_permissions" => rpc_state!(app, params, Arc<ToolPermissionService>, crate::commands::copilot::copilot_list_tool_permissions, ()),
        "copilot_set_tool_permission" => rpc_state!(app, params, Arc<ToolPermissionService>, crate::commands::copilot::copilot_set_tool_permission, ("tool_name": String, "workspace_id": Option<String>, "decision": ToolPermissionDecision)),
        "copilot_clear_tool_permission" => rpc_state!(app, params, Arc<ToolPermissionService>, crate::commands::copilot::copilot_clear_tool_permission, ("tool_name": String, "workspace_id": Option<String>)),
        "copilot_check_tool_permission" => rpc_state!(app, params, Arc<ToolPermissionService>, crate::commands::copilot::copilot_check_tool_permission, ("tool_name": String, "workspace_id": Option<String>)),

        // ----------------------------------------------------------- proactive
        "copilot_get_notifications" => rpc_state!(app, params, Arc<ProactiveEngine>, crate::commands::proactive::copilot_get_notifications, ("workspace_id": Option<String>)),
        "copilot_dismiss_notification" => rpc_state!(app, params, Arc<ProactiveEngine>, crate::commands::proactive::copilot_dismiss_notification, ("notification_id": String)),
        "copilot_get_resume_context" => rpc_state!(app, params, Arc<ProactiveEngine>, crate::commands::proactive::copilot_get_resume_context, ("workspace_id": String)),
        "copilot_generate_plan" => rpc_state!(app, params, Arc<ProactiveEngine>, crate::commands::proactive::copilot_generate_plan, ("workspace_id": Option<String>, "goal": String)),
        "copilot_set_permission" => rpc_state!(app, params, Arc<ProactiveEngine>, crate::commands::proactive::copilot_set_permission, ("workspace_id": Option<String>, "action_type": String, "permission": PermissionLevel)),
        "copilot_check_permission" => rpc_state!(app, params, Arc<ProactiveEngine>, crate::commands::proactive::copilot_check_permission, ("workspace_id": Option<String>, "action_type": String)),
        "copilot_get_enhanced_briefing" => rpc_state!(app, params, Arc<ProactiveEngine>, crate::commands::proactive::copilot_get_enhanced_briefing, ("workspace_id": Option<String>)),
        "copilot_query_timeline" => rpc_state!(app, params, Arc<ProactiveEngine>, crate::commands::proactive::copilot_query_timeline, ("workspace_id": Option<String>, "query": String)),
        "copilot_check_opportunities" => rpc_state!(app, params, Arc<ProactiveEngine>, crate::commands::proactive::copilot_check_opportunities, ("workspace_id": String)),
        "copilot_execute_proactive_action" => rpc_state!(app, params, Arc<ProactiveEngine>, crate::commands::proactive::copilot_execute_proactive_action, ("action_id": String, "workspace_id": Option<String>)),

        // -------------------------------------------------------- conversation
        "copilot_rename_conversation" => rpc_state!(app, params, CopilotRepository, crate::commands::conversation::copilot_rename_conversation, ("conversation_id": String, "new_title": String)),
        "copilot_delete_conversation" => rpc_state!(app, params, CopilotRepository, crate::commands::conversation::copilot_delete_conversation, ("conversation_id": String)),
        "copilot_pin_conversation" => rpc_state!(app, params, CopilotRepository, crate::commands::conversation::copilot_pin_conversation, ("conversation_id": String, "pinned": bool)),
        "copilot_export_conversation_json" => rpc_state!(app, params, CopilotRepository, crate::commands::conversation::copilot_export_conversation_json, ("conversation_id": String)),
        "copilot_export_conversation_markdown" => rpc_state!(app, params, CopilotRepository, crate::commands::conversation::copilot_export_conversation_markdown, ("conversation_id": String)),

        // ---------------------------------------------------------- execution
        "execution_start" => rpc_state!(app, params, Arc<ExecutionEngine>, crate::commands::execution::execution_start, ("plan": ExecutionPlan, "conversation_id": Option<String>)),
        "execution_pause" => rpc_state!(app, params, Arc<ExecutionEngine>, crate::commands::execution::execution_pause, ("execution_id": String)),
        "execution_resume" => rpc_state!(app, params, Arc<ExecutionEngine>, crate::commands::execution::execution_resume, ("execution_id": String)),
        "execution_cancel" => rpc_state!(app, params, Arc<ExecutionEngine>, crate::commands::execution::execution_cancel, ("execution_id": String)),
        "execution_get_progress" => rpc_state!(app, params, Arc<ExecutionEngine>, crate::commands::execution::execution_get_progress, ("execution_id": String)),
        "execution_list_recent" => rpc_state!(app, params, Arc<ExecutionEngine>, crate::commands::execution::execution_list_recent, ("limit": Option<usize>)),

        // --------------------------------------------------------- autonomous
        "autonomous_start" => rpc_state!(app, params, Arc<AutonomousRuntime>, crate::commands::autonomous::autonomous_start, ("goal": String, "workspace_id": Option<String>, "policy": Option<ExecutionPolicy>)),
        "autonomous_get_progress" => rpc_state!(app, params, Arc<AutonomousRuntime>, crate::commands::autonomous::autonomous_get_progress, ("session_id": String)),
        "autonomous_list_recent" => rpc_state!(app, params, Arc<AutonomousRuntime>, crate::commands::autonomous::autonomous_list_recent, ("limit": Option<usize>)),
        "autonomous_pause" => rpc_state!(app, params, Arc<AutonomousRuntime>, crate::commands::autonomous::autonomous_pause, ("session_id": String)),
        "autonomous_resume" => rpc_state!(app, params, Arc<AutonomousRuntime>, crate::commands::autonomous::autonomous_resume, ("session_id": String)),
        "autonomous_cancel" => rpc_state!(app, params, Arc<AutonomousRuntime>, crate::commands::autonomous::autonomous_cancel, ("session_id": String)),
        "autonomous_approve" => rpc_state!(app, params, Arc<AutonomousRuntime>, crate::commands::autonomous::autonomous_approve, ("session_id": String, "note": Option<String>)),
        "autonomous_reject" => rpc_state!(app, params, Arc<AutonomousRuntime>, crate::commands::autonomous::autonomous_reject, ("session_id": String, "note": Option<String>)),

        _ => return Err(RpcError::message(format!("unknown method `{method}`"))),
    };
    Ok(result)
}
