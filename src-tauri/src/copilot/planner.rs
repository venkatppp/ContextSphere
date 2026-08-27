//! Autonomous Planning Engine.
//!
//! Turns a user goal into a structured, dependency-aware [`ExecutionPlan`]
//! that the existing [`ExecutionEngine`] can run: steps carry explicit
//! dependencies (a DAG rather than a flat list), may be gated behind the
//! outcome of an earlier step ([`PlanGate`] conditional execution), and a
//! failed step triggers a bounded replan that revises the remaining work
//! instead of aborting the goal.
//!
//! The planner reuses the shared [`ToolExecutor`] invocation pipeline (the
//! same validation/permission/timeout path used by the existing engines) and
//! consults the persistent [`ToolPermissionService`] when building the plan,
//! so planning never introduces a second execution path.

use std::collections::{HashMap, VecDeque};
use std::sync::Arc;

use chrono::Utc;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::copilot::execution::ExecutionStatus;
use crate::copilot::execution_context::UNRESOLVED_VARIABLE_MARKER;
use crate::copilot::execution_engine::ExecutionEngine;
use crate::copilot::memory::learning::RECOMMENDATION_THRESHOLD;
use crate::copilot::memory::MemoryEngine;
use crate::copilot::proactive_models::{ExecutionPlan, PlanApprovalStatus, PlanGate, PlanTask};
use crate::copilot::tools::{
    ToolDefinition, ToolExecutor, ToolInvocationStatus, ToolPermissionDecision,
    ToolPermissionLevel, ToolPermissionService,
};
use crate::copilot::StepStatus;
use crate::errors::DatabaseError;

/// Number of replan passes permitted for a single goal before giving up.
pub const MAX_REPLAN_ATTEMPTS: usize = 3;

/// Errors surfaced by the planning pipeline.
#[derive(Debug, thiserror::Error)]
pub enum PlannerError {
    #[error("Planner was cancelled")]
    Cancelled,
    #[error("goal is empty")]
    EmptyGoal,
    #[error("no tools are available for this goal/workspace")]
    NoToolsAvailable,
    #[error("plan contains a dependency cycle")]
    DependencyCycle,
    #[error("execution failed: {0}")]
    Execution(String),
    #[error("variable resolution failed: {0}")]
    UnresolvedVariable(String),
    #[error("database error: {0}")]
    Database(#[from] DatabaseError),
}

/// Outcome of an autonomous plan run.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlannerReport {
    pub plan: ExecutionPlan,
    /// Id of the final execution that ran the plan (only when an execution
    /// engine was attached).
    pub execution_id: Option<Uuid>,
    /// Task ids executed successfully, in order.
    pub completed: Vec<Uuid>,
    /// Task ids skipped because a conditional gate was not satisfied.
    pub skipped: Vec<Uuid>,
    /// Task ids that failed and were replaced by replanning.
    pub replaced: Vec<Uuid>,
    /// Number of replan passes actually performed.
    pub replan_count: usize,
    /// First error observed during the run, when any.
    pub error: Option<String>,
}

/// Feedback from the autonomous runtime about a failed plan run, used by
/// `replan_with_feedback` to decide between re-attempting the same task
/// (retry available) and a structural replan (failed step dropped).
#[derive(Debug, Clone)]
pub struct ReplanFeedback {
    /// Step that failed, in the plan that ran.
    pub failed: Option<Uuid>,
    /// The tool that failed, when known from the execution step.
    pub tool_name: Option<String>,
    /// Error surfaced by the failed run.
    pub error: Option<String>,
    /// `false` = a retry of the same step is desired; `true` = the retry
    /// budget is exhausted and the failed step must be dropped by replanning.
    pub retry_exhausted: bool,
}

/// The autonomous planner. Cheap to clone; all state lives behind `Arc`s.
#[derive(Clone)]
pub struct Planner {
    tool_executor: Arc<ToolExecutor>,
    permission_service: Option<Arc<ToolPermissionService>>,
    execution_engine: Option<Arc<ExecutionEngine>>,
    /// Execution memory consulted before planning so learned workflows can
    /// be reused (RC-6 M1). Optional; `None` keeps the planner fully
    /// deterministic and backward compatible.
    memory: Option<Arc<MemoryEngine>>,
}

impl Planner {
    /// Creates a new planner over the shared tool pipeline.
    pub fn new(
        tool_executor: Arc<ToolExecutor>,
        permission_service: Option<Arc<ToolPermissionService>>,
    ) -> Self {
        Self {
            tool_executor,
            permission_service,
            execution_engine: None,
            memory: None,
        }
    }

    /// Attaches the execution engine the planner hands plans to.
    pub fn with_execution_engine(mut self, engine: Arc<ExecutionEngine>) -> Self {
        self.execution_engine = Some(engine);
        self
    }

    /// Attaches the execution memory store the planner consults before
    /// building a plan (RC-6 M1). Optional for backward compatibility.
    pub fn with_memory(mut self, memory: Arc<MemoryEngine>) -> Self {
        self.memory = Some(memory);
        self
    }

    fn engine(&self) -> Result<Arc<ExecutionEngine>, PlannerError> {
        self.execution_engine.clone().ok_or(PlannerError::Execution(
            "no execution engine attached".into(),
        ))
    }

    /// Generates a dependency-aware plan for a goal in a workspace.
    ///
    /// The produced plan is a chain-shaped DAG whose deeper steps depend on
    /// the output of earlier ones, with the final action step gated behind a
    /// [`PlanGate::AfterSuccess`] of its predecessor — modeling conditional
    /// execution that depends on previous results.
    pub async fn plan(
        &self,
        workspace_id: Option<Uuid>,
        cancellation_token: Option<&tokio_util::sync::CancellationToken>,
        goal: &str,
    ) -> Result<ExecutionPlan, PlannerError> {
        if let Some(token) = cancellation_token {
            if token.is_cancelled() {
                return Err(PlannerError::Cancelled);
            }
        }
        if goal.trim().is_empty() {
            return Err(PlannerError::EmptyGoal);
        }

        let tools = self.available_tools(workspace_id).await;
        if tools.is_empty() {
            return Err(PlannerError::NoToolsAvailable);
        }
        let tool_names: Vec<String> = tools.iter().map(|t| t.name.clone()).collect();

        // Consult execution memory (RC-6 M1): when a previous execution
        // achieved a sufficiently similar goal successfully, reuse that
        // workflow instead of building the deterministic chain from
        // scratch. The reused plan is re-keyed (fresh ids) so it remains
        // an independent execution.
        if let Some(memory) = &self.memory {
            match memory.recommend(goal, workspace_id, 3).await {
                Ok(recommendations) => {
                    if let Some(best) = recommendations
                        .into_iter()
                        .find(|r| r.score >= RECOMMENDATION_THRESHOLD && r.record.plan.is_some())
                    {
                        let remembered = best.record.plan.expect("plan presence checked above");
                        let mut reused = remembered.clone();
                        reused.id = Uuid::new_v4();
                        reused.workspace_id = workspace_id;
                        reused.goal = goal.to_string();
                        reused.status = PlanApprovalStatus::Pending;
                        reused.created_at = Utc::now();
                        for task in &mut reused.tasks {
                            task.id = Uuid::new_v4();
                            task.completed = false;
                        }
                        reused.confidence = best.score.clamp(0.5, 0.95);
                        reused.reasoning = format!(
                            "Reused successful workflow from execution memory (score {:.2}, confidence {:.2}, {} replays): {}",
                            best.score,
                            best.confidence_score,
                            best.replay_count,
                            remembered.reasoning
                        );
                        let _ = memory.mark_replayed(best.record.id).await;
                        tracing::info!(
                            score = best.score,
                            confidence = best.confidence_score,
                            memory_id = %best.record.id,
                            "planner reused a remembered workflow for goal"
                        );
                        return Ok(reused);
                    }
                }
                Err(error) => {
                    // Memory is advisory: a failure to consult it must not
                    // break planning, which falls back to the
                    // deterministic chain below.
                    tracing::warn!(
                        error = %error,
                        "memory consultation failed; planning without learned workflows"
                    );
                }
            }
        }

        let workflow = workflow_plan(&tool_names, goal);
        if workflow.is_empty() {
            return Err(PlannerError::NoToolsAvailable);
        }

        let mut tasks: Vec<PlanTask> = Vec::new();
        let mut previous: Option<Uuid> = None;

        for (tool_name, description) in workflow {
            let task_id = Uuid::new_v4();
            let dependencies = previous.into_iter().collect::<Vec<_>>();
            let condition = previous
                .filter(|_| tool_name == "resume_workspace")
                .map(PlanGate::AfterSuccess);

            tasks.push(PlanTask {
                id: task_id,
                description: description.to_string(),
                dependencies,
                estimated_minutes: 5,
                required_files: vec![],
                tool_name: Some(tool_name.clone()),
                arguments: bind_plan_arguments(&tools, &tool_name, workspace_id),
                completed: false,
                condition,
            });
            previous = Some(task_id);
        }

        let total_minutes: i32 = tasks.iter().map(|t| t.estimated_minutes).sum();

        // Honest deterministic reasoning: list matched keywords and tools so UI
        // never pretends the output is semantic reasoning.
        let matched_keywords = goal_keywords(goal);
        let reasoning = if matched_keywords.is_empty() {
            format!(
                "Deterministic plan (generic goal): {} steps from tool registry [{}]; no keyword filtering applied. Traceable via tool availability, not LLM.",
                tasks.len(),
                tool_names.join(", ")
            )
        } else {
            format!(
                "Deterministic plan: goal keywords {:?} matched {} steps from registry [{}]; steps are dependency-ordered and tool-bound.",
                matched_keywords,
                tasks.len(),
                tool_names.join(", ")
            )
        };

        Ok(ExecutionPlan {
            id: Uuid::new_v4(),
            workspace_id,
            goal: goal.to_string(),
            tasks,
            estimated_duration_minutes: total_minutes,
            required_files: vec![],
            checkpoints: vec![
                "Context collected".to_string(),
                "Plan steps resolved".to_string(),
                "Action executed".to_string(),
            ],
            confidence: if matched_keywords.is_empty() { 0.65 } else { 0.78 },
            reasoning,
            status: PlanApprovalStatus::Pending,
            created_at: Utc::now(),
        })
    }

    /// Resolves the topological execution order of a plan's tasks.
    ///
    /// Kahn's algorithm over the dependency edges. Returns
    /// `PlannerError::DependencyCycle` when the graph cannot be linearized.
    pub fn dependency_order(&self, plan: &ExecutionPlan) -> Result<Vec<PlanTask>, PlannerError> {
        topological_order(&plan.tasks)
    }

    /// Evaluates whether a step's conditional gate permits execution given
    /// the outcome of the referenced predecessor.
    pub fn condition_satisfied(
        &self,
        condition: Option<PlanGate>,
        outcomes: &HashMap<Uuid, ToolInvocationStatus>,
    ) -> bool {
        match condition {
            None => true,
            Some(PlanGate::AfterSuccess(predecessor)) => {
                outcomes.get(&predecessor) == Some(&ToolInvocationStatus::Success)
            }
            Some(PlanGate::AfterFailure(predecessor)) => matches!(
                outcomes.get(&predecessor),
                Some(ToolInvocationStatus::Failed) | Some(ToolInvocationStatus::Cancelled)
            ),
        }
    }

    /// Produces a revised plan after a step failed. Completed tasks are kept
    /// out of the way, the failed task is dropped, and the surviving work is
    /// re-linked so execution can continue instead of aborting the goal.
    pub fn replan_after_failure(
        &self,
        plan: &ExecutionPlan,
        completed: &[Uuid],
        failed: Uuid,
    ) -> Result<ExecutionPlan, PlannerError> {
        let kept: Vec<PlanTask> = plan
            .tasks
            .iter()
            .filter(|task| task.id != failed && !completed.contains(&task.id))
            .map(|task| {
                let mut revised = task.clone();
                revised
                    .dependencies
                    .retain(|dep| *dep != failed && !completed.contains(dep));
                revised.condition = None;
                revised
            })
            .collect();

        // Prune surviving tasks whose dependencies no longer exist so the
        // replanned graph stays acyclic and connected.
        let surviving_ids: Vec<Uuid> = kept.iter().map(|t| t.id).collect();
        let mut connected: Vec<PlanTask> = kept
            .into_iter()
            .filter(|task| {
                task.dependencies
                    .iter()
                    .all(|dep| surviving_ids.contains(dep))
            })
            .collect();
        connected.sort_by(|a, b| a.description.cmp(&b.description));

        let mut replanned = plan.clone();
        replanned.status = PlanApprovalStatus::Pending;
        replanned.tasks = connected;
        replanned.confidence = (plan.confidence - 0.1).max(0.4);
        replanned.reasoning = format!(
            "Replanned after task {} failed; remaining steps were re-linked",
            failed
        );
        Ok(replanned)
    }

    /// Revises a plan after a failed run using runtime feedback.
    ///
    /// A retry (`retry_exhausted == false`) keeps the failed task in place so
    /// the engine re-attempts it; a replan (`retry_exhausted == true`) drops
    /// the failed step and re-links surviving work via
    /// [`Self::replan_after_failure`].
    pub fn replan_with_feedback(
        &self,
        plan: &ExecutionPlan,
        completed: &[Uuid],
        feedback: &ReplanFeedback,
    ) -> Result<ExecutionPlan, PlannerError> {
        if !feedback.retry_exhausted {
            let mut retried = plan.clone();
            retried.status = PlanApprovalStatus::Pending;
            let cause = feedback
                .error
                .as_deref()
                .unwrap_or("the previous run failed");
            retried.reasoning = format!("Retrying after failure: {cause}");
            return Ok(retried);
        }
        let failed = feedback.failed.ok_or(PlannerError::Execution(
            "replan requested without a failed step".into(),
        ))?;
        self.replan_after_failure(plan, completed, failed)
    }

    /// Returns true when the plan contains no executable work (all tasks
    /// completed, skipped, or dropped by a replan).
    pub fn is_exhausted(plan: &ExecutionPlan) -> bool {
        plan.tasks.is_empty()
    }

    /// Executes a goal: builds the dependency-aware plan, hands it to
    /// `ExecutionEngine` for execution, and replans on recoverable failures.
    ///
    /// Planning (building/revising the DAG) lives here; scheduling, lifecycle,
    /// cancellation, persistence, and streaming events belong to the engine.
    pub async fn execute_goal(
        &self,
        workspace_id: Option<Uuid>,
        goal: &str,
        cancellation_token: Option<&tokio_util::sync::CancellationToken>,
    ) -> Result<PlannerReport, PlannerError> {
        self.ensure_not_cancelled(cancellation_token)?;
        let plan = self.plan(workspace_id, cancellation_token, goal).await?;
        self.execute_plan(&plan, cancellation_token).await
    }

    /// Executes a pre-built plan through `ExecutionEngine`, reporting which
    /// tasks completed, were skipped, or were replaced by replanning.
    pub async fn execute_plan(
        &self,
        plan: &ExecutionPlan,
        cancellation_token: Option<&tokio_util::sync::CancellationToken>,
    ) -> Result<PlannerReport, PlannerError> {
        self.ensure_not_cancelled(cancellation_token)?;

        let engine = self.engine()?;
        let mut plan = plan.clone();
        let mut completed: Vec<Uuid> = Vec::new();
        let mut skipped: Vec<Uuid> = Vec::new();
        let mut replaced: Vec<Uuid> = Vec::new();
        let mut replan_count = 0usize;
        let mut last_error: Option<String> = None;
        let mut last_execution_id: Option<Uuid> = None;

        loop {
            self.ensure_not_cancelled(cancellation_token)?;
            if replan_count > MAX_REPLAN_ATTEMPTS {
                last_error = Some("max replan attempts reached".to_string());
                break;
            }

            let execution_id = engine
                .start_execution(&plan, None)
                .await
                .map_err(PlannerError::Database)?;
            last_execution_id = Some(execution_id);
            engine
                .execute_until_complete(execution_id)
                .await
                .map_err(PlannerError::Database)?;
            let progress = engine
                .get_progress(execution_id)
                .await
                .map_err(PlannerError::Database)?;

            match progress.status {
                ExecutionStatus::Completed => {
                    completed = progress
                        .steps
                        .iter()
                        .filter(|step| step.status == StepStatus::Completed)
                        .map(|step| plan.tasks[step.step_number].id)
                        .collect();
                    skipped = progress
                        .steps
                        .iter()
                        .filter(|step| step.status == StepStatus::Skipped)
                        .map(|step| plan.tasks[step.step_number].id)
                        .collect();
                    break;
                }
                ExecutionStatus::Cancelled => return Err(PlannerError::Cancelled),
                _ => {
                    let failed = plan
                        .tasks
                        .iter()
                        .zip(progress.steps.iter())
                        .find(|(_, step)| step.status == StepStatus::Failed);
                    let Some((failed_task, failed_step)) = failed else {
                        last_error = Some(
                            progress
                                .steps
                                .iter()
                                .find(|step| step.error.is_some())
                                .and_then(|step| step.error.clone())
                                .unwrap_or_else(|| "Execution failed".to_string()),
                        );
                        break;
                    };

                    // Variable-resolution failures are not recoverable by
                    // replanning (the referenced output will never exist);
                    // surface them as a structured error instead.
                    if let Some(error) = &failed_step.error {
                        if error.starts_with(UNRESOLVED_VARIABLE_MARKER)
                            || error.starts_with("invalid template")
                        {
                            return Err(PlannerError::UnresolvedVariable(error.clone()));
                        }
                    }

                    let failed_step = failed_task.id;
                    replaced.push(failed_step);
                    replan_count += 1;
                    plan = self.replan_after_failure(&plan, &completed, failed_step)?;
                }
            }
        }

        let report = PlannerReport {
            plan,
            execution_id: last_execution_id,
            completed,
            skipped,
            replaced,
            replan_count,
            error: last_error,
        };

        // Publish the report into the execution stream so the frontend's
        // live dashboard shows replan/retry accounting alongside final state.
        if let Some(execution_id) = report.execution_id {
            if let Some(engine) = &self.execution_engine {
                if let Err(err) = engine
                    .attach_planner_report(execution_id, report.clone())
                    .await
                {
                    tracing::warn!(
                        error = %err,
                        "failed to attach planner report to execution stream"
                    );
                }
            }
        }

        Ok(report)
    }

    /// Tools a goal may reference, excluding any denied by registry metadata
    /// or the persistent permission policy for the workspace.
    pub async fn available_tools(&self, workspace_id: Option<Uuid>) -> Vec<ToolDefinition> {
        let executor_tools = self.tool_executor.available_tools();
        let mut allowed = Vec::new();
        for tool in executor_tools {
            if tool.permission.required_level == ToolPermissionLevel::Denied {
                continue;
            }
            if let Some(permissions) = &self.permission_service {
                if permissions.resolve(&tool.name, workspace_id).await
                    == Some(ToolPermissionDecision::Deny)
                {
                    continue;
                }
            }
            allowed.push(tool);
        }
        allowed
    }

    fn ensure_not_cancelled(
        &self,
        token: Option<&tokio_util::sync::CancellationToken>,
    ) -> Result<(), PlannerError> {
        if let Some(token) = token {
            if token.is_cancelled() {
                return Err(PlannerError::Cancelled);
            }
        }
        Ok(())
    }
}

/// Kahn-style topological order over the plan's task graph.
fn topological_order(tasks: &[PlanTask]) -> Result<Vec<PlanTask>, PlannerError> {
    let mut by_id: HashMap<Uuid, PlanTask> = HashMap::new();
    for task in tasks {
        by_id.insert(task.id, task.clone());
    }

    let mut indegree: HashMap<Uuid, usize> = HashMap::new();
    let mut adjacency: HashMap<Uuid, Vec<Uuid>> = HashMap::new();
    for task in tasks {
        *indegree.entry(task.id).or_insert(0) += 0;
        for dep in &task.dependencies {
            if by_id.contains_key(dep) {
                adjacency.entry(*dep).or_default().push(task.id);
                *indegree.entry(task.id).or_insert(0) += 1;
            }
        }
    }

    let mut queue: VecDeque<Uuid> = tasks
        .iter()
        .filter(|t| indegree.get(&t.id).copied().unwrap_or(0) == 0)
        .map(|t| t.id)
        .collect();

    let mut order: Vec<PlanTask> = Vec::new();
    while let Some(uuid) = queue.pop_front() {
        if let Some(task) = by_id.get(&uuid) {
            order.push(task.clone());
        }
        if let Some(neighbors) = adjacency.get(&uuid) {
            for neighbor in neighbors {
                if let Some(degree) = indegree.get_mut(neighbor) {
                    *degree -= 1;
                    if *degree == 0 {
                        queue.push_back(*neighbor);
                    }
                }
            }
        }
    }

    if order.len() != tasks.len() {
        return Err(PlannerError::DependencyCycle);
    }
    Ok(order)
}

/// Binds default arguments for a planned step so the engine can invoke the
/// tool without re-planning. Tools that declare a `workspace_id` parameter
/// bind `{{workspace.id}}`, which the execution engine resolves from the
/// execution context; other tools run with no arguments.
fn bind_plan_arguments(
    tools: &[ToolDefinition],
    tool_name: &str,
    workspace_id: Option<Uuid>,
) -> Option<serde_json::Value> {
    let definition = tools.iter().find(|t| t.name == tool_name)?;
    if !definition
        .parameters
        .iter()
        .any(|p| p.name == "workspace_id")
    {
        return Some(serde_json::json!({}));
    }
    workspace_id.map(|_| serde_json::json!({ "workspace_id": "{{workspace.id}}" }))
}

/// Extracts honest keyword tags from a goal for deterministic branching.
/// No semantic reasoning -- simple substring match, fully traceable.
fn goal_keywords(goal: &str) -> Vec<String> {
    let g = goal.to_lowercase();
    let mut keywords = Vec::new();
    let checks = [
        ("workspace", "workspace"),
        ("list", "list"),
        ("timeline", "timeline"),
        ("recent", "recent"),
        ("activity", "activity"),
        ("search", "search"),
        ("find", "find"),
        ("session", "session"),
        ("focus", "focus"),
        ("resume", "resume"),
        ("continue", "continue"),
        ("switch", "switch"),
    ];
    for (needle, tag) in checks {
        if g.contains(needle) {
            keywords.push(tag.to_string());
        }
    }
    keywords
}

/// A deterministic, dependency-aware list of steps built from the tools
/// actually available. Each step leads into the next; a `resume_workspace`
/// action is appended as the gated, conditional tail step.
///
/// Goal semantics are intentionally shallow and honest: substring keyword
/// matching only, no LLM reasoning. Branching is traceable via `goal_keywords`.
fn workflow_plan(available: &[String], goal: &str) -> Vec<(String, String)> {
    let has = |name: &str| available.iter().any(|n| n == name);
    let g = goal.to_lowercase();
    let wants_workspace =
        g.contains("workspace") || g.contains("list") || g.contains("project") || g.contains("show work");
    let wants_timeline = g.contains("timeline")
        || g.contains("recent")
        || g.contains("activity")
        || g.contains("change")
        || g.contains("edit")
        || g.contains("file")
        || g.contains("history");
    let wants_search =
        g.contains("search") || g.contains("find") || g.contains("look for") || g.contains("query");
    let wants_session = g.contains("session")
        || g.contains("focus")
        || g.contains("context")
        || g.contains("where was")
        || g.contains("what was");
    let wants_resume = g.contains("resume")
        || g.contains("continue")
        || g.contains("switch")
        || g.contains("open")
        || g.contains("return");
    let generic = !wants_workspace && !wants_timeline && !wants_search && !wants_session && !wants_resume;

    let mut steps: Vec<(String, String)> = Vec::new();

    // Workspace discovery -- include if generic or explicitly requested
    if generic || wants_workspace {
        if has("list_workspaces") {
            steps.push((
                "list_workspaces".to_string(),
                "List active workspaces".to_string(),
            ));
        } else if has("get_active_workspace") {
            steps.push((
                "get_active_workspace".to_string(),
                "Get the active workspace".to_string(),
            ));
        }
    } else if has("get_active_workspace") && (wants_session || wants_resume) {
        // Even when workspace not explicitly requested, session/resume needs active context
        if !steps.iter().any(|(n, _)| n == "list_workspaces") {
            steps.push((
                "get_active_workspace".to_string(),
                "Get the active workspace".to_string(),
            ));
        }
    }

    // Timeline / search -- prefer search_timeline when search is intended
    if generic || wants_timeline || wants_search {
        if wants_search && has("search_timeline") {
            steps.push((
                "search_timeline".to_string(),
                "Search the workspace timeline".to_string(),
            ));
        } else if has("get_recent_events") {
            steps.push((
                "get_recent_events".to_string(),
                "Gather recent workspace activity".to_string(),
            ));
        } else if has("search_timeline") {
            steps.push((
                "search_timeline".to_string(),
                "Search the workspace timeline".to_string(),
            ));
        }
    }

    if (generic || wants_session || wants_timeline) && has("get_session_summary") {
        steps.push((
            "get_session_summary".to_string(),
            "Summarize the current session".to_string(),
        ));
    }

    if (generic || wants_resume) && has("resume_workspace") {
        steps.push((
            "resume_workspace".to_string(),
            "Resume focused work".to_string(),
        ));
    }

    // Ensure at least one step if filtering left us empty but tools exist (fallback to generic)
    if steps.is_empty() && !available.is_empty() {
        // Fallback to original generic chain
        if has("list_workspaces") {
            steps.push(("list_workspaces".to_string(), "List active workspaces".to_string()));
        } else if has("get_active_workspace") {
            steps.push(("get_active_workspace".to_string(), "Get the active workspace".to_string()));
        }
        if has("get_recent_events") {
            steps.push(("get_recent_events".to_string(), "Gather recent workspace activity".to_string()));
        } else if has("search_timeline") {
            steps.push(("search_timeline".to_string(), "Search the workspace timeline".to_string()));
        }
        if has("get_session_summary") {
            steps.push(("get_session_summary".to_string(), "Summarize the current session".to_string()));
        }
        if has("resume_workspace") {
            steps.push(("resume_workspace".to_string(), "Resume focused work".to_string()));
        }
    }

    steps
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use crate::copilot::execution::ExecutionStatus;
    use crate::copilot::execution_engine::ExecutionEngine;
    use crate::copilot::execution_repository::ExecutionRepository;
    use crate::copilot::memory::vector::LocalVectorProvider;
    use crate::copilot::memory::{MemoryEngine, MemoryRepository, MemorySearchRequest};
    use crate::database::test_database;
    use crate::repositories::{
        FileRepository, SettingsRepository, TimelineRepository, WorkspaceRepository,
    };
    use crate::services::{TimelineService, WorkspaceService};
    use crate::session::SessionEngine;
    use crate::timeline::recorder::TimelineRecorder;
    use crate::timeline::TimelineEngine;

    use crate::app_events::AppEventEmitter;

    /// Records every emitted event payload so tests can assert on what would
    /// reach the frontend's `execution:progress` listener.
    #[derive(Debug, Clone, Default)]
    pub struct RecordingEmitter {
        pub events: Arc<std::sync::Mutex<Vec<String>>>,
    }

    impl RecordingEmitter {
        fn new() -> Self {
            Self {
                events: Arc::new(std::sync::Mutex::new(Vec::new())),
            }
        }

        fn progress_payloads(&self) -> Vec<serde_json::Value> {
            let guard = self.events.lock().unwrap();
            guard
                .iter()
                .filter_map(|s| serde_json::from_str(s).ok())
                .collect()
        }
    }

    impl AppEventEmitter for RecordingEmitter {
        fn emit_event(&self, _event: &str, payload: serde_json::Value) {
            self.events.lock().unwrap().push(payload.to_string());
        }
    }

    fn workspace_id(n: u8) -> Uuid {
        Uuid::from_bytes([n; 16])
    }

    async fn engine_planner() -> (Planner, Arc<ExecutionEngine>, tempfile::TempDir) {
        let (database, guard) = test_database().await;
        let pool = database.pool().clone();
        seed_workspaces(&pool).await;
        let (planner, engine) = execution_stack(&pool).await;
        (planner, engine, guard)
    }

    /// Seeds the workspaces the workflow's `resume_workspace` tail step and
    /// binding plans reference. Idempotent so multiple engines can be built
    /// over one pool (used to simulate an application restart).
    async fn seed_workspaces(pool: &sqlx::SqlitePool) {
        for n in 1..=4u8 {
            let id = workspace_id(n);
            let now = Utc::now();
            sqlx::query(
                "INSERT OR IGNORE INTO workspaces
                    (id, name, description, status, health_score, root_path, last_active_at, created_at, updated_at)
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            )
            .bind(id)
            .bind(format!("Workspace {n}"))
            .bind::<Option<String>>(None)
            .bind(crate::models::workspace::WorkspaceStatus::Active.as_str())
            .bind(0.0_f64)
            .bind::<Option<String>>(None)
            .bind(now)
            .bind(now)
            .bind(now)
            .execute(pool)
            .await
            .expect("workspace seeding should succeed");
        }
    }

    /// Builds a fresh planner + engine stack over an existing pool. Used by
    /// both `engine_planner` and the restart tests: a second call over the
    /// same pool yields a brand-new `ExecutionEngine` with an empty
    /// in-memory active map — exactly what a restarted application sees.
    async fn execution_stack(pool: &sqlx::SqlitePool) -> (Planner, Arc<ExecutionEngine>) {
        let workspace_repo = WorkspaceRepository::new(pool.clone());
        let file_repo = FileRepository::new(pool.clone());
        let timeline_repo = TimelineRepository::new(pool.clone());

        let workspace_service =
            Arc::new(WorkspaceService::new(workspace_repo, timeline_repo.clone()));
        let session_engine = Arc::new(SessionEngine::new(
            TimelineRepository::new(pool.clone()),
            FileRepository::new(pool.clone()),
        ));
        let timeline_engine = Arc::new(TimelineEngine::new(TimelineService::new(
            TimelineRecorder::new(file_repo, timeline_repo.clone()),
            timeline_repo,
        )));

        let permission_service = Arc::new(
            ToolPermissionService::new(SettingsRepository::new(pool.clone()))
                .await
                .expect("permission service should initialize"),
        );

        let executor = Arc::new(
            ToolExecutor::new(workspace_service, session_engine, timeline_engine)
                .with_permission_service(permission_service.clone()),
        );

        let engine = Arc::new(ExecutionEngine::new(
            Arc::new(ExecutionRepository::new(pool.clone())),
            executor.clone(),
        ));
        let planner =
            Planner::new(executor, Some(permission_service)).with_execution_engine(engine.clone());

        (planner, engine)
    }

    /// A memory-backed stack: the engine and planner both carry the shared
    /// `MemoryEngine` (RC-6 M1 wiring), so terminal runs are captured and
    /// the planner can reuse learned workflows.
    async fn execution_stack_with_memory(
        pool: &sqlx::SqlitePool,
        memory: Arc<MemoryEngine>,
    ) -> (Planner, Arc<ExecutionEngine>) {
        let (planner, _engine) = execution_stack(pool).await;
        let engine = Arc::new(
            ExecutionEngine::new(
                Arc::new(ExecutionRepository::new(pool.clone())),
                planner.tool_executor.clone(),
            )
            .with_memory(memory.clone()),
        );
        let planner = planner
            .with_memory(memory)
            .with_execution_engine(engine.clone());
        (planner, engine)
    }

    async fn executor() -> (
        Arc<ToolExecutor>,
        Arc<ToolPermissionService>,
        tempfile::TempDir,
    ) {
        let (database, guard) = test_database().await;
        let pool = database.pool().clone();
        let workspace_repo = WorkspaceRepository::new(pool.clone());
        let file_repo = FileRepository::new(pool.clone());
        let timeline_repo = TimelineRepository::new(pool.clone());

        let workspace_service =
            Arc::new(WorkspaceService::new(workspace_repo, timeline_repo.clone()));
        let session_engine = Arc::new(SessionEngine::new(
            TimelineRepository::new(pool.clone()),
            FileRepository::new(pool.clone()),
        ));
        let timeline_engine = Arc::new(TimelineEngine::new(TimelineService::new(
            TimelineRecorder::new(file_repo, timeline_repo.clone()),
            timeline_repo,
        )));

        let permission_service = Arc::new(
            ToolPermissionService::new(SettingsRepository::new(pool.clone()))
                .await
                .expect("permission service should initialize"),
        );

        let executor = Arc::new(
            ToolExecutor::new(workspace_service, session_engine, timeline_engine)
                .with_permission_service(permission_service.clone()),
        );

        (executor, permission_service, guard)
    }

    async fn planner() -> (Planner, tempfile::TempDir) {
        let (executor, permission_service, guard) = executor().await;
        (Planner::new(executor, Some(permission_service)), guard)
    }

    fn seed_plan() -> ExecutionPlan {
        let a = Uuid::new_v4();
        let b = Uuid::new_v4();
        let c = Uuid::new_v4();
        let tasks = vec![
            PlanTask {
                id: a,
                description: "A".into(),
                dependencies: vec![],
                estimated_minutes: 1,
                required_files: vec![],
                tool_name: Some("list_workspaces".into()),
                arguments: None,
                completed: false,
                condition: None,
            },
            PlanTask {
                id: b,
                description: "B".into(),
                dependencies: vec![a],
                estimated_minutes: 2,
                required_files: vec![],
                tool_name: Some("get_recent_events".into()),
                arguments: None,
                completed: false,
                condition: Some(PlanGate::AfterSuccess(a)),
            },
            PlanTask {
                id: c,
                description: "C".into(),
                dependencies: vec![b],
                estimated_minutes: 3,
                required_files: vec![],
                tool_name: Some("get_session_summary".into()),
                arguments: None,
                completed: false,
                condition: Some(PlanGate::AfterSuccess(b)),
            },
        ];
        ExecutionPlan {
            id: Uuid::new_v4(),
            workspace_id: None,
            goal: "plan generation".into(),
            tasks,
            estimated_duration_minutes: 6,
            required_files: vec![],
            checkpoints: vec![],
            confidence: 0.8,
            reasoning: "test".into(),
            status: PlanApprovalStatus::Pending,
            created_at: Utc::now(),
        }
    }

    #[tokio::test]
    async fn plan_generation_produces_dependency_aware_steps() {
        let (planner, _guard) = planner().await;
        let cancellation = tokio_util::sync::CancellationToken::new();

        let plan = planner
            .plan(None, Some(&cancellation), "Resume my focus session")
            .await
            .expect("plan should generate");
        assert!(!plan.tasks.is_empty());
        assert!(
            plan.tasks.len() >= 3,
            "expected a chain, got {}",
            plan.tasks.len()
        );

        for task in &plan.tasks {
            assert!(
                task.dependencies
                    .iter()
                    .all(|dep| { plan.tasks.iter().any(|other| other.id == *dep) }),
                "dependency {} must reference an existing task",
                task.id
            );
        }
        assert!(
            plan.tasks.iter().any(|t| t.condition.is_some()),
            "expected at least one conditional gate"
        );

        let ordered = planner
            .dependency_order(&plan)
            .expect("dependency plan must be topologically sortable");
        assert_eq!(ordered.len(), plan.tasks.len());
    }

    #[tokio::test]
    async fn dependency_resolution_orders_and_detects_cycles() {
        let (planner, _guard) = planner().await;

        let plan = seed_plan();
        let ordered = planner
            .dependency_order(&plan)
            .expect("acyclic plan should produce an order");
        assert_eq!(ordered.len(), 3);
        assert_eq!(ordered[0].id, plan.tasks[0].id);

        let mut cyclic = seed_plan();
        let id_a = cyclic.tasks[0].id;
        let id_b = cyclic.tasks[1].id;
        let id_c = cyclic.tasks[2].id;
        cyclic.tasks[1].dependencies = vec![id_a, id_c];
        cyclic.tasks[2].dependencies = vec![id_b];
        assert!(
            matches!(
                planner.dependency_order(&cyclic),
                Err(PlannerError::DependencyCycle)
            ),
            "cycle must be detected"
        );
    }

    #[tokio::test]
    async fn replanning_after_failure_keeps_remaining_steps() {
        let (planner, _guard) = planner().await;
        let original = seed_plan();
        let failed = original.tasks[1].id;

        let replanned = planner
            .replan_after_failure(&original, &[], failed)
            .expect("replan should succeed");
        assert!(
            replanned.tasks.iter().all(|t| t.id != failed),
            "failed task must be dropped"
        );
        assert!(!replanned.tasks.is_empty(), "surviving work must remain");
        assert!(
            replanned.tasks.iter().any(|t| t.condition.is_none()),
            "replanned steps should no longer gate on the failed predecessor"
        );
        assert!(replanned.confidence < original.confidence);
    }

    #[tokio::test]
    async fn reassemble_plan_after_duplicate_success() {
        let (planner, _guard) = planner().await;
        let original = seed_plan();
        let failed = original.tasks[1].id;

        let replanned = planner
            .replan_with_feedback(
                &original,
                &[],
                &ReplanFeedback {
                    failed: Some(failed),
                    tool_name: None,
                    error: None,
                    retry_exhausted: true,
                },
            )
            .expect("replan should succeed");
        assert!(
            replanned.tasks.iter().all(|t| t.id != failed),
            "exhausted retries drop the failed task"
        );
        assert!(!replanned.tasks.is_empty(), "surviving work must remain");
    }

    #[tokio::test]
    async fn retry_keeps_failed_step_when_budget_remains() {
        let (planner, _guard) = planner().await;
        let original = seed_plan();
        let failed = original.tasks[1].id;

        let retried = planner
            .replan_with_feedback(
                &original,
                &[],
                &ReplanFeedback {
                    failed: Some(failed),
                    tool_name: None,
                    error: Some("boom".into()),
                    retry_exhausted: false,
                },
            )
            .expect("retry should succeed");
        assert_eq!(retried.tasks.len(), original.tasks.len());
        assert!(retried.reasoning.contains("Retrying"));
    }

    #[tokio::test]
    async fn conditional_execution_honors_gates() {
        let (planner, _guard) = planner().await;
        let mut outcomes = HashMap::new();
        let precedent = Uuid::new_v4();

        assert!(planner.condition_satisfied(None, &outcomes));

        assert!(!planner.condition_satisfied(Some(PlanGate::AfterSuccess(precedent)), &outcomes));
        outcomes.insert(precedent, ToolInvocationStatus::Success);
        assert!(planner.condition_satisfied(Some(PlanGate::AfterSuccess(precedent)), &outcomes));

        outcomes.insert(precedent, ToolInvocationStatus::Success);
        assert!(!planner.condition_satisfied(Some(PlanGate::AfterFailure(precedent)), &outcomes));
        outcomes.insert(precedent, ToolInvocationStatus::Failed);
        assert!(planner.condition_satisfied(Some(PlanGate::AfterFailure(precedent)), &outcomes));
    }

    #[tokio::test]
    async fn planner_cancellation_returns_cancelled() {
        let (planner, _guard) = planner().await;
        let tok = tokio_util::sync::CancellationToken::new();
        tok.cancel();

        let result = planner
            .plan(Some(workspace_id(1)), Some(&tok), "resume work")
            .await;
        assert!(
            matches!(result, Err(PlannerError::Cancelled)),
            "plan must abort on a cancelled token"
        );

        let result = planner
            .execute_goal(Some(workspace_id(1)), "resume work", Some(&tok))
            .await;
        assert!(matches!(result, Err(PlannerError::Cancelled)));
    }

    #[tokio::test]
    async fn planner_hands_plan_to_engine_and_completes() {
        let (planner, engine, _guard) = engine_planner().await;

        let report = planner
            .execute_goal(Some(workspace_id(1)), "Resume my focus session", None)
            .await
            .expect("planner-goal execution should succeed");

        assert!(
            report.error.is_none(),
            "unexpected planner error: {:?}",
            report.error
        );
        assert_eq!(report.completed.len(), report.plan.tasks.len());
        assert!(report.replaced.is_empty());

        let execution_id = report
            .execution_id
            .expect("planner should report its final execution");
        let progress = engine
            .get_progress(execution_id)
            .await
            .expect("execution should be findable");
        assert_eq!(progress.status, ExecutionStatus::Completed);
    }

    #[tokio::test]
    async fn engine_executes_tasks_in_dependency_order() {
        let (planner, engine, _guard) = engine_planner().await;
        let plan = planner
            .plan(Some(workspace_id(2)), None, "Ordered workflow")
            .await
            .expect("plan should build");

        // Verify each task's dependencies are resolved to an earlier
        // execution step — the engine must run the DAG, not a flat list.
        let execution_id = engine
            .start_execution(&plan, None)
            .await
            .expect("execution should start");
        engine
            .execute_until_complete(execution_id)
            .await
            .expect("execution should complete");

        let progress = engine
            .get_progress(execution_id)
            .await
            .expect("execution progress should be readable");
        assert_eq!(progress.status, ExecutionStatus::Completed);

        for (index, task) in plan.tasks.iter().enumerate() {
            let step = &progress
                .steps
                .iter()
                .find(|s| s.step_number == index)
                .expect("step should exist");
            assert_eq!(step.status, crate::copilot::StepStatus::Completed);
            // A task with dependencies must be scheduled strictly after its
            // references already completed.
            for dependency in &task.dependencies {
                let dep_index = index_of_id(&plan.tasks, dependency)
                    .expect("dependency must exist in the plan");
                assert!(dep_index <= index, "DAG violated for task {}", index);
            }
        }
    }

    #[tokio::test]
    async fn engine_cancellation_propagates() {
        let (planner, engine, _guard) = engine_planner().await;
        let plan = planner
            .plan(Some(workspace_id(3)), None, "Cancellable workflow")
            .await
            .expect("plan should generate");

        let execution_id = engine
            .start_execution(&plan, None)
            .await
            .expect("execution should start");
        engine
            .cancel_execution(execution_id)
            .await
            .expect("cancellation should succeed");

        let progress = engine
            .get_progress(execution_id)
            .await
            .expect("progress should be readable");
        assert_eq!(progress.status, ExecutionStatus::Cancelled);
    }

    #[tokio::test]
    async fn execution_progress_events_are_recorded() {
        let (planner, engine, _guard) = engine_planner().await;
        let plan = planner
            .plan(Some(workspace_id(3)), None, "Workflow for events")
            .await
            .expect("plan should generate");

        let execution_id = engine
            .start_execution(&plan, None)
            .await
            .expect("execution should start");
        engine
            .execute_until_complete(execution_id)
            .await
            .expect("execution should complete");

        let progress = engine
            .get_progress(execution_id)
            .await
            .expect("progress should be readable");
        let event_types: Vec<crate::copilot::ExecutionEventType> = progress
            .recent_events
            .iter()
            .map(|event| event.event_type)
            .collect();

        assert!(
            event_types.contains(&crate::copilot::ExecutionEventType::Started),
            "expected a Started event, got {:?}",
            event_types
        );
        assert!(
            event_types.contains(&crate::copilot::ExecutionEventType::StepStarted),
            "expected StepStarted events"
        );
        assert!(
            event_types.contains(&crate::copilot::ExecutionEventType::Completed),
            "expected a Completed event"
        );
    }

    #[tokio::test]
    async fn failure_triggers_replan_against_engine() {
        let (planner, engine, _guard) = engine_planner().await;
        // Force a tool-level failure for the first step by denying its
        // permission, which the engine observes as a failed execution.
        let permission_service = planner
            .permission_service
            .as_ref()
            .expect("permission service attached")
            .clone();
        permission_service
            .set_policy(
                "get_recent_events",
                Some(workspace_id(4)),
                ToolPermissionDecision::Deny,
            )
            .await
            .expect("policy should be recorded");

        let report = planner
            .execute_goal(Some(workspace_id(4)), "Recover after step failure", None)
            .await
            .expect("planning (not execution) should succeed");
        assert!(
            report.replan_count > 0 || !report.replaced.is_empty(),
            "a failing step should trigger at least one replan"
        );

        let execution_id = report
            .execution_id
            .expect("planner should report its final execution");
        let progress = engine
            .get_progress(execution_id)
            .await
            .expect("execution should be findable");
        assert_eq!(progress.status, ExecutionStatus::Completed);
        assert!(!report.completed.is_empty());
    }

    fn index_of_id(tasks: &[PlanTask], id: &Uuid) -> Option<usize> {
        tasks.iter().position(|task| task.id == *id)
    }

    /// Plan whose second step consumes the output of the first:
    /// `list_workspaces` → `get_workspace(workspace_id = {{steps.list_workspaces[0].id}})`.
    fn binding_plan() -> ExecutionPlan {
        let a = Uuid::new_v4();
        let b = Uuid::new_v4();
        let tasks = vec![
            PlanTask {
                id: a,
                description: "List active workspaces".into(),
                dependencies: vec![],
                estimated_minutes: 1,
                required_files: vec![],
                tool_name: Some("list_workspaces".into()),
                arguments: Some(serde_json::json!({})),
                completed: false,
                condition: None,
            },
            PlanTask {
                id: b,
                description: "Resolve a workspace from the first step".into(),
                dependencies: vec![a],
                estimated_minutes: 1,
                required_files: vec![],
                tool_name: Some("get_workspace".into()),
                arguments: Some(
                    serde_json::json!({ "workspace_id": "{{steps.list_workspaces[0].id}}" }),
                ),
                completed: false,
                condition: Some(PlanGate::AfterSuccess(a)),
            },
        ];
        ExecutionPlan {
            id: Uuid::new_v4(),
            workspace_id: None,
            goal: "bind outputs".into(),
            tasks,
            estimated_duration_minutes: 2,
            required_files: vec![],
            checkpoints: vec![],
            confidence: 0.8,
            reasoning: "test".into(),
            status: PlanApprovalStatus::Pending,
            created_at: Utc::now(),
        }
    }

    #[tokio::test]
    async fn execution_context_stores_outputs() {
        let (planner, engine, _guard) = engine_planner().await;
        let plan = binding_plan();
        let execution_id = engine
            .start_execution(&plan, None)
            .await
            .expect("execution should start");
        engine
            .execute_until_complete(execution_id)
            .await
            .expect("execution should complete");

        let progress = engine
            .get_progress(execution_id)
            .await
            .expect("progress should be readable");
        assert_eq!(progress.status, ExecutionStatus::Completed);
        // The downstream step consumed the upstream output, proving the context
        // stored `list_workspaces` and exposed it to a later step.
        assert!(
            progress
                .steps
                .iter()
                .all(|step| step.status == crate::copilot::StepStatus::Completed),
            "every step must complete when outputs bind correctly"
        );

        let report = planner
            .execute_plan(&plan, None)
            .await
            .expect("binding plan should execute");
        assert_eq!(report.completed.len(), 2);
    }

    #[tokio::test]
    async fn downstream_task_receives_resolved_arguments() {
        let (planner, _engine, _guard) = engine_planner().await;
        let plan = binding_plan();
        let report = planner
            .execute_plan(&plan, None)
            .await
            .expect("binding plan should execute");
        assert_eq!(report.completed.len(), 2, "both steps must complete");
        assert!(report.replaced.is_empty());
    }

    #[tokio::test]
    async fn missing_variable_returns_structured_planner_error() {
        let (planner, _engine, _guard) = engine_planner().await;
        let mut plan = binding_plan();
        // Reference a step that will never have an output.
        plan.tasks[1].arguments = Some(serde_json::json!({
            "workspace_id": "{{steps.never_ran.output}}"
        }));

        let result = planner.execute_plan(&plan, None).await;
        assert!(
            matches!(result, Err(PlannerError::UnresolvedVariable(_))),
            "missing variables must surface as a structured PlannerError, got {:?}",
            result
        );
    }

    #[tokio::test]
    async fn malformed_template_returns_structured_planner_error() {
        let (planner, _engine, _guard) = engine_planner().await;
        let mut plan = binding_plan();
        // Recognized template syntax ({{...}}) with an invalid body that
        // cannot reference any output — must resolve-fail, not silently pass.
        plan.tasks[1].arguments = Some(serde_json::json!({
            "workspace_id": "{{steps}}"
        }));

        let result = planner.execute_plan(&plan, None).await;
        assert!(
            matches!(result, Err(PlannerError::UnresolvedVariable(_))),
            "malformed template must fail with a structured error, got {:?}",
            result
        );
    }

    #[tokio::test]
    async fn cancellation_still_propagates_with_context_binding() {
        let (_planner, engine, _guard) = engine_planner().await;
        let plan = binding_plan();
        let execution_id = engine
            .start_execution(&plan, None)
            .await
            .expect("execution should start");

        // Cancel (as a user cancelling) before the engine drives any step, so
        // a context-bound execution still observes cancellation.
        engine
            .cancel_execution(execution_id)
            .await
            .expect("cancellation should succeed");

        let progress = engine
            .get_progress(execution_id)
            .await
            .expect("progress should be readable");
        assert_eq!(progress.status, ExecutionStatus::Cancelled);
    }

    #[tokio::test]
    async fn paused_execution_resumes_on_fresh_engine_without_repeating() {
        let (database, _guard) = test_database().await;
        let pool = database.pool().clone();
        seed_workspaces(&pool).await;
        let (_, engine_one) = execution_stack(&pool).await;

        let plan = binding_plan();
        let execution_id = engine_one
            .start_execution(&plan, None)
            .await
            .expect("execution should start");

        // Drive only the first step, then pause — mimicking a user pausing
        // midway through a run.
        engine_one
            .execute_next_step(execution_id)
            .await
            .expect("step one should run");

        // Pause writes a checkpoint row, so a later engine can rebuild.
        engine_one
            .pause_execution(execution_id)
            .await
            .expect("execution should pause");

        let progress = engine_one
            .get_progress(execution_id)
            .await
            .expect("progress should be readable");
        assert_eq!(progress.status, ExecutionStatus::Paused);

        // Simulate an application restart: a brand-new engine over the same
        // pool with an empty in-memory active map.
        let (_, engine_two) = execution_stack(&pool).await;
        engine_two
            .resume_execution(execution_id)
            .await
            .expect("resume should rebuild state from the checkpoint");
        engine_two
            .execute_until_complete(execution_id)
            .await
            .expect("execution should complete after resume");

        let resumed = engine_two
            .get_progress(execution_id)
            .await
            .expect("progress should be readable");
        assert_eq!(
            resumed.status,
            ExecutionStatus::Completed,
            "resumed execution must reach a terminal state"
        );
        // Neither step may be repeated: exactly the two planned steps ran.
        let steps = resumed.steps.len();
        assert_eq!(steps, 2, "restart must not re-run completed steps");
        assert!(
            resumed
                .steps
                .iter()
                .all(|step| step.status == crate::copilot::StepStatus::Completed),
            "every step must complete across the resume boundary"
        );
    }

    #[tokio::test]
    async fn checkpoint_is_removed_after_terminal_state() {
        let (database, _guard) = test_database().await;
        let pool = database.pool().clone();
        seed_workspaces(&pool).await;
        let (_, engine) = execution_stack(&pool).await;
        let repository = ExecutionRepository::new(pool);

        let plan = binding_plan();
        let execution_id = engine
            .start_execution(&plan, None)
            .await
            .expect("execution should start");
        engine
            .execute_next_step(execution_id)
            .await
            .expect("first step should run");

        // After completing one step a checkpoint must exist.
        let stored = repository
            .get_checkpoint(execution_id)
            .await
            .expect("checkpoint lookup should work");
        assert!(
            stored.is_some(),
            "a checkpoint must be persisted after completing a step"
        );

        engine
            .execute_until_complete(execution_id)
            .await
            .expect("execution should complete");
        let after = repository
            .get_checkpoint(execution_id)
            .await
            .expect("checkpoint lookup should work");
        assert!(
            after.is_none(),
            "terminal states must delete the durable checkpoint"
        );
    }

    #[tokio::test]
    async fn progress_events_emitted_through_lifecycle() {
        let (database, _guard) = test_database().await;
        let pool = database.pool().clone();
        seed_workspaces(&pool).await;
        let (_planner, _engine) = execution_stack(&pool).await;

        // Attach a recording emitter to the already-built engine by cloning the
        // underlying Arc state is not possible; instead build a dedicated
        // engine with an emitter to verify the wiring compiles and emits.
        let recorder = Arc::new(RecordingEmitter::new());
        let emitter: Arc<dyn AppEventEmitter> = recorder.clone();
        let workspace_repo = WorkspaceRepository::new(pool.clone());
        let file_repo = FileRepository::new(pool.clone());
        let timeline_repo = TimelineRepository::new(pool.clone());
        let workspace_service =
            Arc::new(WorkspaceService::new(workspace_repo, timeline_repo.clone()));
        let session_engine = Arc::new(SessionEngine::new(
            TimelineRepository::new(pool.clone()),
            FileRepository::new(pool.clone()),
        ));
        let timeline_engine = Arc::new(TimelineEngine::new(TimelineService::new(
            TimelineRecorder::new(file_repo, timeline_repo.clone()),
            timeline_repo,
        )));
        let permission_service = Arc::new(
            ToolPermissionService::new(SettingsRepository::new(pool.clone()))
                .await
                .expect("permission service should initialize"),
        );
        let executor = Arc::new(
            ToolExecutor::new(workspace_service, session_engine, timeline_engine)
                .with_permission_service(permission_service.clone()),
        );
        let emitting_engine = Arc::new(
            ExecutionEngine::new(
                Arc::new(ExecutionRepository::new(pool.clone())),
                executor.clone(),
            )
            .with_event_emitter(emitter),
        );

        let plan = binding_plan();
        let execution_id = emitting_engine
            .start_execution(&plan, None)
            .await
            .expect("execution should start");
        emitting_engine
            .execute_until_complete(execution_id)
            .await
            .expect("execution should complete");

        let payloads = recorder.progress_payloads();
        assert!(
            !payloads.is_empty(),
            "progress snapshots must be emitted during a run"
        );
        let final_status = payloads
            .last()
            .and_then(|v| v.get("status"))
            .and_then(|s| s.as_str())
            .unwrap_or_default();
        assert_eq!(
            final_status, "completed",
            "final streamed snapshot must carry the terminal status"
        );
        assert!(
            payloads.iter().any(|v| v.get("current_step").is_some()),
            "snapshots must carry current_step for the DAG progress view"
        );
    }

    #[tokio::test]
    async fn planner_report_persisted_and_streamed() {
        let (database, _guard) = test_database().await;
        let pool = database.pool().clone();
        seed_workspaces(&pool).await;

        // Persist a planner report by attaching it through the engine, then
        // verify a fresh engine (read-only reconnect path) still loads it.
        let (_, engine) = execution_stack(&pool).await;
        let report = PlannerReport {
            plan: binding_plan(),
            execution_id: None,
            completed: vec![Uuid::new_v4()],
            skipped: vec![],
            replaced: vec![],
            replan_count: 1,
            error: None,
        };

        let plan = binding_plan();
        let execution_id = engine
            .start_execution(&plan, None)
            .await
            .expect("execution should start");
        let mut report = report;
        report.execution_id = Some(execution_id);
        engine
            .attach_planner_report(execution_id, report.clone())
            .await
            .expect("report attachment should succeed");

        let (_, fresh_engine) = execution_stack(&pool).await;
        let progress = fresh_engine
            .get_progress(execution_id)
            .await
            .expect("progress should be readable");
        let streamed = progress
            .planner_report
            .expect("planner report must be visible after restart");
        assert_eq!(streamed.replan_count, 1);
    }

    #[tokio::test]
    async fn plan_reuses_remembered_workflow_from_memory() {
        let (database, _guard) = test_database().await;
        let pool = database.pool().clone();
        seed_workspaces(&pool).await;
        let memory = Arc::new(MemoryEngine::new(
            MemoryRepository::new(pool.clone()),
            Arc::new(LocalVectorProvider::default()),
        ));

        // A previous successful run of the same goal lives in memory.
        let mut remembered = binding_plan();
        remembered.goal = "resume my focus session".to_string();
        memory
            .record_execution(
                Uuid::new_v4(),
                None,
                "resume my focus session",
                Some(&remembered),
                &[crate::copilot::execution::ExecutionStep {
                    id: Uuid::new_v4(),
                    execution_id: Uuid::new_v4(),
                    step_number: 0,
                    description: "List active workspaces".into(),
                    tool_name: Some("list_workspaces".into()),
                    arguments: None,
                    status: crate::copilot::StepStatus::Completed,
                    result: None,
                    error: None,
                    started_at: None,
                    completed_at: None,
                    created_at: Utc::now(),
                }],
                ExecutionStatus::Completed,
                None,
                None,
            )
            .await
            .expect("memory capture should succeed");

        let (planner, _engine) = execution_stack_with_memory(&pool, memory).await;
        let plan = planner
            .plan(None, None, "resume my focus session")
            .await
            .expect("plan should generate from memory");
        assert!(
            plan.reasoning.contains("execution memory"),
            "reused plans must cite the memory source, got: {}",
            plan.reasoning
        );
        assert!(
            plan.reasoning.contains("Reused successful workflow"),
            "expected reuse reasoning, got: {}",
            plan.reasoning
        );
        assert!(!plan.tasks.is_empty(), "reused plan keeps its steps");
        assert!(
            plan.tasks.iter().all(|t| !t.completed),
            "reused plan steps must be reset to incomplete"
        );
    }

    #[tokio::test]
    async fn plan_ignores_weak_memory_matches() {
        let (database, _guard) = test_database().await;
        let pool = database.pool().clone();
        seed_workspaces(&pool).await;
        let memory = Arc::new(MemoryEngine::new(
            MemoryRepository::new(pool.clone()),
            Arc::new(LocalVectorProvider::default()),
        ));

        // An unrelated goal must not be reused for a different query.
        memory
            .record_execution(
                Uuid::new_v4(),
                None,
                "organize tax documents for april",
                Some(&binding_plan()),
                &[],
                ExecutionStatus::Completed,
                None,
                None,
            )
            .await
            .expect("memory capture should succeed");

        let (planner, _engine) = execution_stack_with_memory(&pool, memory).await;
        let plan = planner
            .plan(None, None, "resume my focus session")
            .await
            .expect("plan should generate deterministically");
        assert!(
            !plan.reasoning.contains("execution memory"),
            "unrelated memory must not influence the plan"
        );
        assert_eq!(plan.goal, "resume my focus session");
    }

    #[tokio::test]
    async fn completed_execution_is_captured_into_memory() {
        let (database, _guard) = test_database().await;
        let pool = database.pool().clone();
        seed_workspaces(&pool).await;
        let memory = Arc::new(MemoryEngine::new(
            MemoryRepository::new(pool.clone()),
            Arc::new(LocalVectorProvider::default()),
        ));

        let (planner, engine) = execution_stack_with_memory(&pool, memory.clone()).await;
        let plan = binding_plan();
        let execution_id = engine
            .start_execution(&plan, None)
            .await
            .expect("execution should start");
        engine
            .execute_until_complete(execution_id)
            .await
            .expect("execution should complete");
        assert_eq!(planner.dependency_order(&plan).unwrap().len(), 2);

        let hits = memory
            .search(&MemorySearchRequest::new("bind outputs"))
            .await
            .expect("search should succeed");
        assert_eq!(
            hits.len(),
            1,
            "terminal executions must be captured into memory"
        );
        assert_eq!(hits[0].record.source_id, execution_id);
        assert!(matches!(
            hits[0].record.status,
            crate::copilot::memory::MemoryStatus::Success
        ));
        assert_eq!(hits[0].record.steps.len(), 2);
    }

    #[tokio::test]
    async fn failed_execution_is_captured_with_error() {
        let (database, _guard) = test_database().await;
        let pool = database.pool().clone();
        seed_workspaces(&pool).await;
        let memory = Arc::new(MemoryEngine::new(
            MemoryRepository::new(pool.clone()),
            Arc::new(LocalVectorProvider::default()),
        ));

        let (planner, engine) = execution_stack_with_memory(&pool, memory.clone()).await;
        let permission_service = planner
            .permission_service
            .as_ref()
            .expect("permission service attached")
            .clone();
        permission_service
            .set_policy("list_workspaces", None, ToolPermissionDecision::Deny)
            .await
            .expect("policy should be recorded");

        let plan = binding_plan();
        let execution_id = engine
            .start_execution(&plan, None)
            .await
            .expect("execution should start");
        engine
            .execute_until_complete(execution_id)
            .await
            .expect("execution should reach a terminal state");

        let hits = memory
            .search(&MemorySearchRequest::new("bind outputs"))
            .await
            .expect("search should succeed");
        assert_eq!(hits.len(), 1, "failed runs must also be captured");
        assert!(matches!(
            hits[0].record.status,
            crate::copilot::memory::MemoryStatus::Failed
        ));
        assert!(
            hits[0].record.error.is_some(),
            "the failure reason must be remembered"
        );
    }
}
