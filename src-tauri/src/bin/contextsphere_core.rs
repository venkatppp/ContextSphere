//! `contextsphere-core` — headless core daemon for the native macOS SwiftUI
//! frontend.
//!
//! Initializes every ContextSphere subsystem (same code path as the GUI app,
//! [`chronodesk_lib::initialize_core`]) but builds a window-less Tauri app
//! from `tauri.core.conf.json` and serves JSON-RPC over stdin/stdout via
//! [`chronodesk_lib::core_server`]. Events emitted by the engines are
//! forwarded to the frontend as JSON-RPC notifications.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use chronodesk_lib::app_events;
use chronodesk_lib::core_server;
use tauri::{Listener, Manager};

/// Every core event the frontend may want to observe. Each listener is
/// registered under its own name because tauri's `Event` does not carry
/// the emitted event name.
const FORWARDED_EVENTS: &[&str] = &[
    app_events::EVENT_WORKSPACE_CREATED,
    app_events::EVENT_WORKSPACE_UPDATED,
    app_events::EVENT_WORKSPACE_DELETED,
    app_events::EVENT_WORKSPACE_SWITCHED,
    app_events::EVENT_FILE_CHANGED,
    app_events::EVENT_TIMELINE_EVENT_ADDED,
    app_events::EVENT_SEARCH_INDEXED,
    app_events::EVENT_GRAPH_EDGE_ADDED,
    app_events::EVENT_GRAPH_UPDATED,
    app_events::EVENT_SESSION_STARTED,
    app_events::EVENT_SESSION_ENDED,
    app_events::EVENT_WORKFLOW_CHANGED,
    app_events::EVENT_PREDICTION_UPDATED,
    app_events::EVENT_RECOMMENDATION_UPDATED,
    app_events::EVENT_HEALTH_UPDATED,
    app_events::EVENT_SNAPSHOT_CREATED,
    app_events::EVENT_ACTION_EXECUTED,
    app_events::EVENT_PROACTIVE_NOTIFICATION,
    app_events::EVENT_RESUME_CONTEXT_READY,
    app_events::EVENT_PLAN_GENERATED,
    app_events::EVENT_AUTOMATION_REQUEST,
    app_events::EVENT_EXECUTION_PROGRESS,
    app_events::EVENT_SECURITY_STATUS,
    "model:download_progress",
];

fn main() {
    // All logging goes to stderr — stdout is the JSON-RPC channel.
    let _ = tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .try_init();

    tauri::Builder::default()
        .setup(|app| {
            let handle = app.handle().clone();
            for event in FORWARDED_EVENTS {
                let name = event.to_string();
                let h = handle.clone();
                app.listen_any(*event, move |event| {
                    let payload: serde_json::Value =
                        serde_json::from_str(event.payload()).unwrap_or_else(|_| {
                            serde_json::Value::String(event.payload().to_string())
                        });
                    core_server::forward_event(&h, &name, &payload);
                });
            }

            chronodesk_lib::initialize_core(app)?;

            // Serve JSON-RPC on tauri's async runtime.
            tauri::async_runtime::spawn(async move {
                core_server::serve(handle).await;
            });

            tracing::info!("contextsphere-core daemon ready");
            Ok(())
        })
        .build(tauri::generate_context!("tauri.core.conf.json"))
        .expect("error while building contextsphere-core")
        .run(|app_handle, event| {
            if let tauri::RunEvent::Exit = event {
                if let Some(manager) =
                    app_handle.try_state::<chronodesk_lib::performance::recovery::RecoveryManager>()
                {
                    let _ = tauri::async_runtime::block_on(manager.record_clean_shutdown());
                }
                if let Some(watcher) = app_handle.try_state::<chronodesk_lib::watcher::FileWatcher>()
                {
                    let _ = tauri::async_runtime::block_on(watcher.stop_all());
                }
            }
        });
}