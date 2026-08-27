//! System-level commands (RC headless `contextsphere_core` JSON-RPC).
//!
//! Thin IPC handlers that delegate to engine modules — they never contain
//! business logic themselves. The native macOS frontend reaches these
//! through `CoreBridge` over stdin/stdout JSON-RPC, not a WebView.

use std::process::Command as ProcessCommand;

use serde::Serialize;

/// Returns the backend crate's semantic version, as declared in `Cargo.toml`.
#[tauri::command]
pub fn get_app_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Opens a file or directory in the default OS application (Finder on
/// macOS, File Manager on Linux/Windows).
#[tauri::command]
pub fn open_file(path: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    let status = ProcessCommand::new("open").arg(&path).status();
    #[cfg(target_os = "linux")]
    let status = ProcessCommand::new("xdg-open").arg(&path).status();
    #[cfg(target_os = "windows")]
    let status = ProcessCommand::new("cmd")
        .args(["/c", "start", "", &path])
        .status();

    match status {
        Ok(s) if s.success() => Ok(()),
        Ok(s) => Err(format!("open_file exited with code {:?}", s.code())),
        Err(e) => Err(format!("failed to spawn open: {e}")),
    }
}

#[derive(Debug, Serialize)]
pub struct HealthStatus {
    pub ok: bool,
    pub backend_version: String,
}

/// Lightweight readiness probe the frontend can call on startup to confirm
/// the Tauri backend is alive before it starts issuing real IPC calls.
#[tauri::command]
pub fn health_check() -> HealthStatus {
    HealthStatus {
        ok: true,
        backend_version: env!("CARGO_PKG_VERSION").to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn get_app_version_matches_cargo_manifest() {
        assert_eq!(get_app_version(), env!("CARGO_PKG_VERSION"));
    }

    #[test]
    fn health_check_reports_ok() {
        let status = health_check();
        assert!(status.ok);
        assert_eq!(status.backend_version, env!("CARGO_PKG_VERSION"));
    }
}
