//! Tauri IPC command handlers, grouped by domain.
//!
//! Each submodule owns one cohesive set of `#[tauri::command]` functions.
//! `lib.rs` only ever imports from here — no `#[tauri::command]` function
//! is defined outside this module, so the full surface area callable from
//! the frontend is always visible in one place.

pub mod actions;
pub mod ai;
pub mod analytics;
pub mod autonomous;
pub mod context_memory;
pub mod conversation;
pub mod copilot;
pub mod duplicates;
pub mod execution;
pub mod graph;
pub mod graph_opt;
pub mod intelligence;
pub mod learning;
pub mod llm;
pub mod maintenance;
pub mod memory;
pub mod activity;
pub mod performance;
pub mod predictive;
pub mod proactive;
pub mod recovery;
pub mod runtime;
pub mod search;
pub mod security;
pub mod semantic;
pub mod session;
pub mod system;
pub mod timeline;
pub mod watcher;
pub mod workspace;
