//! Remaining domain dispatch: actions, analytics, intelligence,
//! predictive, semantic, session, context memory, duplicates, runtime,
//! performance, recovery, maintenance, security.


use serde_json::Value;
use tauri::{AppHandle, Manager};

use crate::core_server::{pget, RpcError, rpc_state, rpc_state_tail};

use crate::actions::models::ExecuteActionRequest;
use crate::actions::service::ActionService;
use crate::analytics::engine::AnalyticsEngine;
use crate::context_memory::models::CreateSnapshotRequest;
use crate::context_memory::ContextMemoryEngine;
use crate::duplicates::DuplicateDetectionEngine;
use crate::intelligence::health::WorkspaceHealthEngine;
use crate::intelligence::recommendation::{
    RecommendationCategory, RecommendationEngine, RecommendationPriority,
};
use crate::maintenance::MaintenanceEngine;
use crate::performance::PerformanceEngine;
use crate::predictive::models::CreateAutomationRuleRequest;
use crate::predictive::{AdaptiveLearning, AutomationEngine, PredictiveEngine, WorkflowEngine};
use crate::performance::recovery::RecoveryManager;
use crate::runtime::{DiagnosticsService, IntelligenceEmitter, RuntimeHealthService};
use crate::security::SecurityEngine;
use crate::semantic::models::SemanticSearchRequest;
use crate::semantic::reasoning::ContextReasoningEngine;
use crate::semantic::search::SemanticSearchEngine;
use crate::services::ContextService;

pub async fn dispatch_admin(
    app: &AppHandle,
    method: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    let result: Value = match method {
        // ------------------------------------------------------------ actions
        "execute_action" => {
            let request: ExecuteActionRequest = pget(params, "request")?;
            let r = crate::commands::actions::execute_action(
                request,
                app.state::<ActionService>(),
                app.state::<IntelligenceEmitter>(),
            )
            .await;
            serde_json::to_value(r).map_err(|e| RpcError::message(e.to_string()))?
        }
        "undo_action" => rpc_state_tail!(app, params, ActionService, crate::commands::actions::undo_action, ("action_id": i64)),
        "get_action_history" => rpc_state_tail!(app, params, ActionService, crate::commands::actions::get_action_history, ("workspace_id": String, "limit": Option<i64>)),
        "get_all_action_history" => rpc_state_tail!(app, params, ActionService, crate::commands::actions::get_all_action_history, ("limit": Option<i64>)),
        "clear_action_history" => rpc_state!(app, params, ActionService, crate::commands::actions::clear_action_history, ()),
        "clear_workspace_action_history" => rpc_state_tail!(app, params, ActionService, crate::commands::actions::clear_workspace_action_history, ("workspace_id": String)),

        // ---------------------------------------------------------- analytics
        "get_daily_briefing" => rpc_state_tail!(app, params, AnalyticsEngine, crate::commands::analytics::get_daily_briefing, ()),
        "get_today_summary" => rpc_state_tail!(app, params, AnalyticsEngine, crate::commands::analytics::get_today_summary, ()),
        "get_yesterday_summary" => rpc_state_tail!(app, params, AnalyticsEngine, crate::commands::analytics::get_yesterday_summary, ()),
        "get_this_week_summary" => rpc_state_tail!(app, params, AnalyticsEngine, crate::commands::analytics::get_this_week_summary, ()),
        "get_last_week_summary" => rpc_state_tail!(app, params, AnalyticsEngine, crate::commands::analytics::get_last_week_summary, ()),
        "get_this_month_summary" => rpc_state_tail!(app, params, AnalyticsEngine, crate::commands::analytics::get_this_month_summary, ()),
        "get_workspace_insight" => rpc_state_tail!(app, params, AnalyticsEngine, crate::commands::analytics::get_workspace_insight, ("workspace_id": String)),

        // -------------------------------------------------------- intelligence
        "get_workspace_health" => {
            let workspace_id: String = pget(params, "workspace_id")?;
            let r = crate::commands::intelligence::get_workspace_health(
                workspace_id,
                app.state::<WorkspaceHealthEngine>(),
                app.state::<IntelligenceEmitter>(),
            )
            .await
            .map_err(|e| RpcError::message(e))?;
            serde_json::to_value(r).map_err(|e| RpcError::message(e.to_string()))?
        }
        "get_latest_workspace_health" => rpc_state_tail!(app, params, WorkspaceHealthEngine, crate::commands::intelligence::get_latest_workspace_health, ("workspace_id": String)),
        "get_workspace_health_history" => rpc_state_tail!(app, params, WorkspaceHealthEngine, crate::commands::intelligence::get_workspace_health_history, ("workspace_id": String, "days": i64)),
        "get_workspace_recommendations" => rpc_state_tail!(app, params, RecommendationEngine, crate::commands::intelligence::get_workspace_recommendations, ("workspace_id": String)),
        "get_category_recommendations" => rpc_state_tail!(app, params, RecommendationEngine, crate::commands::intelligence::get_category_recommendations, ("workspace_id": String, "category": RecommendationCategory)),
        "get_priority_recommendations" => rpc_state_tail!(app, params, RecommendationEngine, crate::commands::intelligence::get_priority_recommendations, ("workspace_id": String, "min_priority": RecommendationPriority)),

        // ---------------------------------------------------------- predictive
        "get_predictions_summary" => rpc_state!(app, params, PredictiveEngine, crate::commands::predictive::get_predictions_summary, ()),
        "get_current_workflow" => rpc_state!(app, params, WorkflowEngine, crate::commands::predictive::get_current_workflow, ("workspace_id": uuid::Uuid)),
        "get_learning_profile" => rpc_state!(app, params, AdaptiveLearning, crate::commands::predictive::get_learning_profile, ("user_id": String)),
        "update_learning_profile" => rpc_state!(app, params, AdaptiveLearning, crate::commands::predictive::update_learning_profile, ("user_id": String)),
        "create_automation_rule" => rpc_state!(app, params, AutomationEngine, crate::commands::predictive::create_automation_rule, ("request": CreateAutomationRuleRequest)),
        "list_automation_rules" => rpc_state!(app, params, AutomationEngine, crate::commands::predictive::list_automation_rules, ()),
        "update_automation_rule_enabled" => rpc_state!(app, params, AutomationEngine, crate::commands::predictive::update_automation_rule_enabled, ("rule_id": i64, "enabled": bool)),
        "delete_automation_rule" => rpc_state!(app, params, AutomationEngine, crate::commands::predictive::delete_automation_rule, ("rule_id": i64)),

        // ----------------------------------------------------------- semantic
        "semantic_search" => rpc_state_tail!(app, params, SemanticSearchEngine, crate::commands::semantic::semantic_search, ("request": SemanticSearchRequest)),
        "find_similar_documents" => rpc_state_tail!(app, params, SemanticSearchEngine, crate::commands::semantic::find_similar_documents, ("document_id": String, "limit": usize, "min_confidence": f32)),
        "infer_related_work" => rpc_state_tail!(app, params, ContextReasoningEngine, crate::commands::semantic::infer_related_work, ("workspace_id": String)),
        "detect_recurring_workflows" => rpc_state_tail!(app, params, ContextReasoningEngine, crate::commands::semantic::detect_recurring_workflows, ("workspace_id": String)),
        "find_similar_sessions" => rpc_state_tail!(app, params, ContextReasoningEngine, crate::commands::semantic::find_similar_sessions, ("workspace_id": String, "limit": usize)),
        "explain_recommendation" => rpc_state_tail!(app, params, ContextReasoningEngine, crate::commands::semantic::explain_recommendation, ("workspace_id": String, "recommendation_id": String)),
        "infer_missing_context" => rpc_state_tail!(app, params, ContextReasoningEngine, crate::commands::semantic::infer_missing_context, ("workspace_id": String)),

        // ------------------------------------------------------------ session
        "get_smart_resume_session" => rpc_state!(app, params, ContextService, crate::commands::session::get_smart_resume_session, ()),
        "get_workspace_sessions" => rpc_state_tail!(app, params, ContextService, crate::commands::session::get_workspace_sessions, ("workspace_id": String, "limit": Option<usize>)),
        "get_latest_workspace_session" => rpc_state_tail!(app, params, ContextService, crate::commands::session::get_latest_workspace_session, ("workspace_id": String)),
        "set_session_inactivity_threshold" => rpc_state_tail!(app, params, ContextService, crate::commands::session::set_session_inactivity_threshold, ("threshold_seconds": i64)),
        "get_session_inactivity_threshold" => rpc_state_tail!(app, params, ContextService, crate::commands::session::get_session_inactivity_threshold, ()),

        // ----------------------------------------------------- context memory
        "create_context_snapshot" => {
            let request: CreateSnapshotRequest = pget(params, "request")?;
            let r = crate::commands::context_memory::create_context_snapshot(
                request,
                app.state::<ContextMemoryEngine>(),
                app.state::<IntelligenceEmitter>(),
            )
            .await;
            serde_json::to_value(r).map_err(|e| RpcError::message(e.to_string()))?
        }
        "get_workspace_snapshots" => rpc_state_tail!(app, params, ContextMemoryEngine, crate::commands::context_memory::get_workspace_snapshots, ("workspace_id": String, "limit": Option<usize>)),
        "get_latest_snapshot" => rpc_state_tail!(app, params, ContextMemoryEngine, crate::commands::context_memory::get_latest_snapshot, ("workspace_id": String)),
        "detect_workspace_relationships" => rpc_state_tail!(app, params, ContextMemoryEngine, crate::commands::context_memory::detect_workspace_relationships, ("workspace_id": String)),
        "get_related_workspaces" => rpc_state_tail!(app, params, ContextMemoryEngine, crate::commands::context_memory::get_related_workspaces, ("workspace_id": String, "min_strength": Option<f64>, "limit": Option<usize>)),
        "search_knowledge" => rpc_state_tail!(app, params, ContextMemoryEngine, crate::commands::context_memory::search_knowledge, ("query": crate::context_memory::models::KnowledgeQuery)),
        "snapshot_milestone" => rpc_state_tail!(app, params, ContextMemoryEngine, crate::commands::context_memory::snapshot_milestone, ("workspace_id": String, "active_files": Vec<String>, "metadata": serde_json::Value)),

        // --------------------------------------------------------- duplicates
        "scan_workspace_for_duplicates" => rpc_state_tail!(app, params, DuplicateDetectionEngine, crate::commands::duplicates::scan_workspace_for_duplicates, ("workspace_id": String)),
        "scan_file" => rpc_state_tail!(app, params, DuplicateDetectionEngine, crate::commands::duplicates::scan_file, ("file_id": String, "path": String)),
        "get_duplicate_groups" => rpc_state_tail!(app, params, DuplicateDetectionEngine, crate::commands::duplicates::get_duplicate_groups, ("workspace_id": Option<String>)),
        "find_duplicates" => rpc_state_tail!(app, params, DuplicateDetectionEngine, crate::commands::duplicates::find_duplicates, ("file_id": String)),
        "get_scan_progress" => rpc_state_tail!(app, params, DuplicateDetectionEngine, crate::commands::duplicates::get_scan_progress, ()),
        "cancel_scan" => rpc_state!(app, params, DuplicateDetectionEngine, crate::commands::duplicates::cancel_scan, ()),

        // ------------------------------------------------------------ runtime
        "get_runtime_health" => rpc_state!(app, params, RuntimeHealthService, crate::commands::runtime::get_runtime_health, ()),
        "get_runtime_diagnostics" => rpc_state!(app, params, DiagnosticsService, crate::commands::runtime::get_runtime_diagnostics, ()),
        "get_runtime_summary" => rpc_state!(app, params, DiagnosticsService, crate::commands::runtime::get_runtime_summary, ()),

        // --------------------------------------------------------- performance
        "performance_profile" => rpc_state!(app, params, PerformanceEngine, crate::commands::performance::performance_profile, ()),
        "performance_startup" => rpc_state!(app, params, PerformanceEngine, crate::commands::performance::performance_startup, ()),
        "performance_benchmark" => rpc_state!(app, params, PerformanceEngine, crate::commands::performance::performance_benchmark, ("category": Option<crate::models::performance::BenchmarkCategory>)),
        "performance_diagnostics" => rpc_state!(app, params, PerformanceEngine, crate::commands::performance::performance_diagnostics, ()),
        "performance_optimize" => rpc_state!(app, params, PerformanceEngine, crate::commands::performance::performance_optimize, ("apply": Option<bool>)),
        "performance_history" => rpc_state!(app, params, PerformanceEngine, crate::commands::performance::performance_history, ("limit": Option<u32>)),

        // ----------------------------------------------------------- recovery
        "recovery_status" => rpc_state!(app, params, RecoveryManager, crate::commands::recovery::recovery_status, ()),
        "recovery_history" => rpc_state!(app, params, RecoveryManager, crate::commands::recovery::recovery_history, ("limit": Option<u32>)),
        "recovery_crash_reports" => rpc_state!(app, params, RecoveryManager, crate::commands::recovery::recovery_crash_reports, ("limit": Option<u32>)),
        "recovery_latest_checkpoint" => rpc_state!(app, params, RecoveryManager, crate::commands::recovery::recovery_latest_checkpoint, ()),
        "recovery_self_heal" => rpc_state!(app, params, RecoveryManager, crate::commands::recovery::recovery_self_heal, ()),
        "recovery_rollback" => rpc_state!(app, params, RecoveryManager, crate::commands::recovery::recovery_rollback, ()),
        "recovery_tick" => rpc_state!(app, params, RecoveryManager, crate::commands::recovery::recovery_tick, ()),

        // --------------------------------------------------------- maintenance
        "maintenance_integrity" => rpc_state!(app, params, MaintenanceEngine, crate::commands::maintenance::maintenance_integrity, ()),
        "maintenance_backup" => rpc_state!(app, params, MaintenanceEngine, crate::commands::maintenance::maintenance_backup, ()),
        "maintenance_backups" => rpc_state!(app, params, MaintenanceEngine, crate::commands::maintenance::maintenance_backups, ("limit": Option<u32>)),
        "maintenance_restore" => rpc_state!(app, params, MaintenanceEngine, crate::commands::maintenance::maintenance_restore, ("backup_id": i64)),
        "maintenance_pending_restore" => rpc_state!(app, params, MaintenanceEngine, crate::commands::maintenance::maintenance_pending_restore, ()),
        "maintenance_cancel_restore" => rpc_state!(app, params, MaintenanceEngine, crate::commands::maintenance::maintenance_cancel_restore, ()),
        "maintenance_optimize" => rpc_state!(app, params, MaintenanceEngine, crate::commands::maintenance::maintenance_optimize, ()),

        // ----------------------------------------------------------- security
        "security_status" => rpc_state!(app, params, SecurityEngine, crate::commands::security::security_status, ()),
        "security_diagnostics" => rpc_state!(app, params, SecurityEngine, crate::commands::security::security_diagnostics, ()),
        "security_secrets" => rpc_state!(app, params, SecurityEngine, crate::commands::security::security_secrets, ()),
        "security_permissions" => rpc_state!(app, params, SecurityEngine, crate::commands::security::security_permissions, ()),
        "security_history" => rpc_state!(app, params, SecurityEngine, crate::commands::security::security_history, ("limit": Option<u32>)),
        "security_audit_log" => rpc_state!(app, params, SecurityEngine, crate::commands::security::security_audit_log, ("limit": Option<u32>)),
        "security_config" => rpc_state!(app, params, SecurityEngine, crate::commands::security::security_config, ()),
        "security_set_config" => rpc_state!(app, params, SecurityEngine, crate::commands::security::security_set_config, ("key": String, "value": String)),
        "security_recommendations" => rpc_state!(app, params, SecurityEngine, crate::commands::security::security_recommendations, ()),
        "security_apply_recommendation" => rpc_state!(app, params, SecurityEngine, crate::commands::security::security_apply_recommendation, ("id": i64)),
        "security_dismiss_recommendation" => rpc_state!(app, params, SecurityEngine, crate::commands::security::security_dismiss_recommendation, ("id": i64)),

        _ => return Err(RpcError::message(format!("unknown method `{method}`"))),
    };
    Ok(result)
}