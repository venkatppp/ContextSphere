//! Headless core server: the service boundary for the native macOS
//! SwiftUI frontend.
//!
//! The `chronodesk-core` binary builds a Tauri app from
//! `tauri.core.conf.json` (no windows), initializes every ChronoDesk
//! subsystem through [`crate::initialize_core`], then serves line-delimited
//! JSON-RPC over stdin/stdout:
//!
//! ```text
//! request:      {"id": 1, "method": "list_active_workspaces", "params": {}}
//! response:     {"id": 1, "result": { ... }}
//! error:        {"id": 1, "error": {"message": "..."}}
//! event (push): {"event": "workspace:created", "payload": { ... }}
//! ```
//!
//! Every request is dispatched to the *existing* Tauri command function —
//! the one registered in `lib.rs`'s `generate_handler!` — by calling it
//! directly with `AppHandle::state::<T>()`. No business logic is
//! duplicated, and command behavior (including event emission) is
//! byte-for-byte the same as the web frontend path.

pub mod dispatch_admin;
pub mod dispatch_copilot;
pub mod dispatch_graph;
pub mod dispatch_memory;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tauri::{AppHandle, Manager};

/// One request line from the Swift frontend.
#[derive(Debug, Deserialize)]
pub struct RpcRequest {
    pub id: u64,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

/// A JSON-RPC error, serialized into the `error` field of a response.
#[derive(Debug, Serialize)]
pub struct RpcError {
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

impl RpcError {
    pub fn message(message: impl Into<String>) -> Self {
        RpcError {
            message: message.into(),
            data: None,
        }
    }
}

/// Serves the request loop on the tauri async runtime. Stops when stdin
/// reaches EOF (the Swift frontend terminated the daemon).
///
/// Requests are dispatched concurrently (each on its own task, bounded by
/// `MAX_INFLIGHT_REQUESTS`) so one slow command cannot starve the others.
/// Responses may therefore arrive out of order — the Swift bridge matches
/// them by id, which is the JSON-RPC contract this server implements.
/// Event notifications interleave safely because [`write_response`] writes
/// each message under a single locked `write_all`.
pub async fn serve(app: AppHandle) {
    use std::sync::atomic::{AtomicBool, Ordering};

    /// Upper bound on concurrently executing requests before the reader
    /// waits. Generous for a single-user local daemon; prevents unbounded
    /// task spawn if a client floods the pipe.
    const MAX_INFLIGHT_REQUESTS: usize = 32;

    let mut stdin = tokio::io::BufReader::new(tokio::io::stdin());
    let semaphore = std::sync::Arc::new(tokio::sync::Semaphore::new(MAX_INFLIGHT_REQUESTS));
    let stdout_broken = std::sync::Arc::new(AtomicBool::new(false));
    let mut line = String::new();
    loop {
        if stdout_broken.load(Ordering::Relaxed) {
            break;
        }
        line.clear();
        match tokio::io::AsyncBufReadExt::read_line(&mut stdin, &mut line).await {
            Ok(0) | Err(_) => break, // EOF / pipe closed
            Ok(_) => {}
        }
        if line.trim().is_empty() {
            continue;
        }
        let request: RpcRequest = match serde_json::from_str(&line) {
            Ok(request) => request,
            Err(error) => {
                let _ = write_response(
                    &app,
                    &serde_json::json!({
                        "error": { "message": format!("malformed request: {error}") }
                    }),
                );
                continue;
            }
        };
        // Permit acquisition happens on the reader loop (backpressure);
        // the permit moves into the task and is released when it finishes.
        let permit = match std::sync::Arc::clone(&semaphore).acquire_owned().await {
            Ok(permit) => permit,
            Err(_) => break, // semaphore closed: shutting down
        };
        let task_app = app.clone();
        let broken_flag = std::sync::Arc::clone(&stdout_broken);
        tauri::async_runtime::spawn(async move {
            let response = dispatch(&task_app, &request).await;
            if write_response(&task_app, &response).is_err() {
                tracing::warn!("core-server: failed to write response (stdout closed)");
                broken_flag.store(true, Ordering::Relaxed);
            }
            drop(permit);
        });
    }
    // The frontend closed the pipe; take the whole daemon down.
    app.exit(0);
}

/// Dispatches one request to the matching Tauri command and shapes the
/// outcome into a JSON-RPC response object.
pub async fn dispatch(app: &AppHandle, request: &RpcRequest) -> Value {
    let outcome = match dispatch_impl(app, &request.method, &request.params).await {
        Ok(result) => Ok(result),
        Err(error) => Err(error),
    };
    let mut response = match outcome {
        Ok(result) => serde_json::json!({ "result": result }),
        Err(error) => serde_json::json!({ "error": error }),
    };
    response["id"] = Value::from(request.id);
    response
}

/// Serializes one response line to stdout. Single `write_all` so a
/// message never interleaves with another concurrent write.
pub fn write_response(app: &AppHandle, response: &Value) -> std::io::Result<()> {
    use std::io::Write;
    let mut out = std::io::stdout().lock();
    out.write_all(response.to_string().as_bytes())?;
    out.write_all(b"\n")?;
    out.flush()?;
    let _ = app;
    Ok(())
}

/// Forwards one emitted core event to the frontend as a notification.
pub fn forward_event(app: &AppHandle, event: &str, payload: &Value) {
    let notification = serde_json::json!({ "event": event, "payload": payload });
    if let Err(error) = write_response(app, &notification) {
        tracing::warn!(event = %event, error = %error, "core-server: failed to forward event");
    }
}

/// Extracts one named parameter, defaulting absent/`null` to the type's
/// `Default` (which makes `Option<T>` and `#[serde(default)]` structs
/// behave exactly as they do under Tauri IPC).
pub fn pget<T: serde::de::DeserializeOwned>(params: &Value, name: &str) -> Result<T, RpcError> {
    let raw = params.get(name).cloned().unwrap_or(Value::Null);
    serde_json::from_value(raw)
        .map_err(|error| RpcError::message(format!("invalid parameter `{name}`: {error}")))
}

/// Calls an async command whose first parameter is `State<'_, $st>` and
/// whose remaining parameters are named JSON params. The command result
/// (including its serialized error) becomes the JSON-RPC value.
macro_rules! rpc_state {
    ($app:expr, $params:expr, $st:ty, $cmd:path, ($($name:literal: $ty:ty),*)) => {{
        let r = $cmd($app.state::<$st>() $(, pget::<$ty>($params, $name)?)*)
            .await
            .map_err(|e| RpcError::message(format!("{e}")))?;
        serde_json::to_value(r).map_err(|e| RpcError::message(format!("serialize: {e}")))?
    }};
}

/// Like [`rpc_state!`], for commands whose first parameter is an
/// `AppHandle` followed by `State<'_, $st>`.
macro_rules! rpc_state_app {
    ($app:expr, $params:expr, $st:ty, $cmd:path, ($($name:literal: $ty:ty),*)) => {{
        let r = $cmd($app.clone(), $app.state::<$st>() $(, pget::<$ty>($params, $name)?)*)
            .await
            .map_err(|e| RpcError::message(format!("{e}")))?;
        serde_json::to_value(r).map_err(|e| RpcError::message(format!("serialize: {e}")))?
    }};
}

/// Like [`rpc_state!`], for commands whose last parameter is `State<'_, $st>`
/// (the common "state in the tail" shape: `fn cmd(arg1, arg2, state)`).
macro_rules! rpc_state_tail {
    ($app:expr, $params:expr, $st:ty, $cmd:path, ($($name:literal: $ty:ty),*)) => {{
        let r = $cmd($(pget::<$ty>($params, $name)?,)* $app.state::<$st>())
            .await
            .map_err(|e| RpcError::message(format!("{e}")))?;
        serde_json::to_value(r).map_err(|e| RpcError::message(format!("serialize: {e}")))?
    }};
}

pub(crate) use rpc_state;
pub(crate) use rpc_state_tail;

async fn dispatch_impl(app: &AppHandle, method: &str, params: &Value) -> Result<Value, RpcError> {
    let result: Value = match method {
        // ------------------------------------------------------------- system
        "get_app_version" => serde_json::json!(crate::commands::system::get_app_version()),
        "health_check" => serde_json::json!(crate::commands::system::health_check()),
        "open_file" => {
            let path: String = pget(params, "path")?;
            serde_json::to_value(crate::commands::system::open_file(path))
                .map_err(|e| RpcError::message(e.to_string()))?
        }

        // ---------------------------------------------------------- workspace
        "list_active_workspaces" => rpc_state!(app, params, crate::services::WorkspaceService, crate::commands::workspace::list_active_workspaces, ()),
        "list_archived_workspaces" => rpc_state!(app, params, crate::services::WorkspaceService, crate::commands::workspace::list_archived_workspaces, ()),
        "get_workspace" => rpc_state!(app, params, crate::services::WorkspaceService, crate::commands::workspace::get_workspace, ("id": uuid::Uuid)),
        "get_workspace_statistics" => {
            let workspace_id: uuid::Uuid = pget(params, "workspace_id")?;
            let r = crate::commands::workspace::get_workspace_statistics(
                app.state::<crate::services::WorkspaceService>(),
                app.state::<crate::intelligence::health::WorkspaceHealthEngine>(),
                workspace_id,
            )
            .await;
            serde_json::to_value(r).map_err(|e| RpcError::message(e.to_string()))?
        }
        "create_workspace" => rpc_state_app!(app, params, crate::services::WorkspaceService, crate::commands::workspace::create_workspace, ("input": crate::models::CreateWorkspaceInput)),
        "update_workspace" => rpc_state_app!(app, params, crate::services::WorkspaceService, crate::commands::workspace::update_workspace, ("id": uuid::Uuid, "input": crate::models::UpdateWorkspaceInput)),
        "delete_workspace" => rpc_state_app!(app, params, crate::services::WorkspaceService, crate::commands::workspace::delete_workspace, ("id": uuid::Uuid)),
        "switch_workspace" => {
            let id: uuid::Uuid = pget(params, "id")?;
            let r = crate::commands::workspace::switch_workspace(
                app.clone(),
                app.state::<crate::services::WorkspaceService>(),
                app.state::<crate::context_memory::ContextMemoryEngine>(),
                app.state::<crate::repositories::FileRepository>(),
                app.state::<std::sync::Arc<crate::runtime::RuntimeWorkers>>(),
                app.state::<std::sync::Arc<crate::copilot::ProactiveEngine>>(),
                id,
            )
            .await;
            serde_json::to_value(r).map_err(|e| RpcError::message(e.to_string()))?
        }

        // ----------------------------------------------------------- timeline
        "list_workspace_timeline" => rpc_state!(app, params, crate::timeline::TimelineEngine, crate::commands::timeline::list_workspace_timeline, ("workspace_id": uuid::Uuid, "limit": Option<i64>, "offset": Option<i64>)),
        "get_recent_activity" => rpc_state!(app, params, crate::timeline::TimelineEngine, crate::commands::timeline::get_recent_activity, ("workspace_id": uuid::Uuid)),

        // ------------------------------------------------------------ watcher
        "add_watch_path" => {
            let path: std::path::PathBuf = pget(params, "path")?;
            let r = crate::commands::watcher::add_watch_path(
                app.state::<crate::watcher::FileWatcher>(),
                app.state::<crate::repositories::SettingsRepository>(),
                path,
            )
            .await;
            serde_json::to_value(r).map_err(|e| RpcError::message(e.to_string()))?
        }
        "remove_watch_path" => {
            let path: std::path::PathBuf = pget(params, "path")?;
            let r = crate::commands::watcher::remove_watch_path(
                app.state::<crate::watcher::FileWatcher>(),
                app.state::<crate::repositories::SettingsRepository>(),
                path,
            )
            .await;
            serde_json::to_value(r).map_err(|e| RpcError::message(e.to_string()))?
        }
        "list_watch_paths" => rpc_state!(app, params, crate::watcher::FileWatcher, crate::commands::watcher::list_watch_paths, ()),

        // -------------------------------------------------------------- search
        "search" => rpc_state_app!(app, params, crate::services::SearchService, crate::commands::search::search, ("query": String, "entity_types": Option<Vec<crate::models::search::SearchEntityType>>, "workspace_id": Option<uuid::Uuid>, "limit": Option<i64>)),
        "get_search_history" => rpc_state!(app, params, crate::services::SearchService, crate::commands::search::get_search_history, ("limit": Option<i64>)),
        "save_search_query" => rpc_state!(app, params, crate::services::SearchService, crate::commands::search::save_search_query, ("query": String)),
        "clear_search_history" => rpc_state!(app, params, crate::services::SearchService, crate::commands::search::clear_search_history, ()),
        "save_search" => rpc_state!(app, params, crate::services::SearchService, crate::commands::search::save_search, ("query": String)),
        "list_saved_searches" => rpc_state!(app, params, crate::services::SearchService, crate::commands::search::list_saved_searches, ()),
        "delete_saved_search" => rpc_state!(app, params, crate::services::SearchService, crate::commands::search::delete_saved_search, ("id": uuid::Uuid)),
        "get_recent_files" => rpc_state!(app, params, crate::services::SearchService, crate::commands::search::get_recent_files, ("workspace_id": uuid::Uuid, "limit": Option<i64>)),
        "get_workspace_stats" => rpc_state!(app, params, crate::services::SearchService, crate::commands::search::get_workspace_stats, ("workspace_id": uuid::Uuid)),
        "graph_ai_vector_search" => {
            let query: String = pget(params, "query")?;
            let limit: Option<u32> = pget(params, "limit")?;
            let r = crate::commands::ai::graph_ai_vector_search(
                query,
                limit,
                app.state::<crate::graph::GraphEngine>(),
                app.state::<crate::commands::ai::AIState>(),
            )
            .await
            .map_err(|e| RpcError::message(e))?;
            serde_json::to_value(r).map_err(|e| RpcError::message(e.to_string()))?
        },

        // --------------------------------------------------------------- graph + copilot
        _ => {
            match dispatch_admin::dispatch_admin(app, method, params).await {
                Ok(result) => result,
                Err(admin_error) if admin_error.message == unknown_method(method) => {
                    match dispatch_memory::dispatch_memory(app, method, params).await {
                        Ok(result) => result,
                        Err(memory_error) if memory_error.message == unknown_method(method) => {
                            match dispatch_copilot::dispatch_copilot(app, method, params).await {
                                Ok(result) => result,
                                Err(copilot_error)
                                    if copilot_error.message == unknown_method(method) =>
                                {
                                    dispatch_graph::dispatch_graph(app, method, params).await?
                                }
                                Err(copilot_error) => return Err(copilot_error),
                            }
                        }
                        Err(memory_error) => return Err(memory_error),
                    }
                }
                Err(admin_error) => return Err(admin_error),
            }
        }
    };
    Ok(result)
}

/// The exact "unknown method" error message a domain dispatcher reports
/// when it does not own `method` — used to fall through to the next
/// dispatcher while still propagating genuine errors (invalid params,
/// save failures, …) from the dispatcher that owns the method.
fn unknown_method(method: &str) -> String {
    format!("unknown method `{method}`")
}
