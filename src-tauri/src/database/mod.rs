//! Storage Layer (blueprint §4.2, §7).
//!
//! [`Database`] is the single owner of the SQLite connection pool.
//! Every other backend module — repositories, services, commands —
//! reaches storage exclusively through a [`Database`] (or the
//! `sqlx::SqlitePool` it exposes via [`Database::pool`]); no module
//! outside `database` opens its own connection.
//!
//! Two entry points are provided:
//! - [`Database::initialize`] — the real path, used from `lib.rs`'s
//!   `setup()` hook. Resolves the OS-appropriate app-data directory
//!   through Tauri's path resolver.
//! - [`Database::initialize_at`] — takes an explicit file path and has no
//!   dependency on a running Tauri app. Used directly by
//!   `Database::initialize`, and by every repository/migration test in
//!   this crate (pointed at a `tempfile` path), so tests never touch a
//!   real user's app-data directory.

pub mod connection;
pub mod migrations;
pub mod schema;

use std::path::Path;
#[cfg(test)]
use std::path::PathBuf;

use chrono::Utc;
use sqlx::SqlitePool;
use tauri::{AppHandle, Manager};

use crate::errors::DatabaseError;

/// Filename (next to `chronodesk.db`) of a validated, staged restore that
/// is swapped in on the next launch (RC-10 M3). Written by
/// [`crate::maintenance::RestoreService::stage`]; consumed by
/// [`apply_pending_restore`] before the pool opens.
pub const RESTORE_PENDING_FILE: &str = "restore-pending.db";

/// Filename prefix for the pre-restore safety backup written by
/// [`apply_pending_restore`], so a restored database can always be
/// reverted manually.
pub const PRE_RESTORE_BACKUP_PREFIX: &str = "chronodesk-pre-restore-";

/// Applies a staged restore: if a validated `restore-pending.db` marker
/// sits next to the live database file, the current file is first backed
/// up as `chronodesk-pre-restore-<timestamp>.db`, the marker is swapped
/// in, and any stale `-wal` / `-shm` sidecars of either file are
/// discarded (the old WAL must not survive its database file).
///
/// Called by [`Database::initialize_at`] **before** the pool is created,
/// so no connection can hold the files open — swapping a live WAL
/// database under an open pool is exactly the hazard this design avoids.
///
/// Returns whether a restore was applied.
async fn apply_pending_restore(db_path: &Path) -> Result<bool, DatabaseError> {
    let marker = db_path.with_file_name(RESTORE_PENDING_FILE);
    if !marker.exists() {
        return Ok(false);
    }

    // Validate staged file is a real SQLite database before swapping.
    // A truncated copy (power loss during stage) would corrupt the live DB.
    let header = tokio::fs::read(&marker)
        .await
        .map_err(|e| DatabaseError::IoError(e.to_string()))?;
    const SQLITE_HEADER: &[u8] = b"SQLite format 3\0";
    if header.len() < SQLITE_HEADER.len() || header[0..SQLITE_HEADER.len()] != SQLITE_HEADER[..] {
        tracing::error!(path = %marker.display(), "staged restore has invalid SQLite header — discarding marker");
        let _ = tokio::fs::remove_file(&marker).await;
        return Ok(false);
    }
    if header.len() < 512 {
        tracing::error!(path = %marker.display(), "staged restore too small — discarding");
        let _ = tokio::fs::remove_file(&marker).await;
        return Ok(false);
    }

    let stamp = Utc::now().format("%Y%m%dT%H%M%S%.6fZ");
    let safety = db_path.with_file_name(format!("{PRE_RESTORE_BACKUP_PREFIX}{stamp}.db"));
    tokio::fs::copy(db_path, &safety)
        .await
        .map_err(|e| DatabaseError::IoError(e.to_string()))?;

    for target in [db_path, &marker] {
        for suffix in ["-wal", "-shm"] {
            let sidecar = std::path::PathBuf::from(format!("{}{suffix}", target.display()));
            let _ = tokio::fs::remove_file(&sidecar).await;
        }
    }

    tokio::fs::rename(&marker, db_path)
        .await
        .map_err(|e| DatabaseError::IoError(e.to_string()))?;

    tracing::warn!(
        path = %db_path.display(),
        safety = %safety.display(),
        "staged restore applied on launch"
    );
    Ok(true)
}

/// Owns the application's SQLite connection pool.
///
/// Cheap to clone-and-share: `Database` wraps an `sqlx::SqlitePool`,
/// which is itself an `Arc`-backed handle, so cloning a `Database` (or
/// just cloning the pool via [`Database::pool`]) never opens a new
/// physical connection.
#[derive(Debug, Clone)]
pub struct Database {
    pool: SqlitePool,
}

impl Database {
    /// Initializes the database using Tauri's resolved app-data
    /// directory (`<app-data>/chronodesk.db`), creating the directory and
    /// the database file on first launch, then applying all pending
    /// migrations.
    ///
    /// This is the constructor `lib.rs` calls from `setup()`. It never
    /// touches a hardcoded path — the directory comes from
    /// [`tauri::path::PathResolver::app_data_dir`], which resolves to the
    /// correct per-OS location (e.g. `%APPDATA%\com.chronodesk.app` on
    /// Windows, `~/Library/Application Support/com.chronodesk.app` on
    /// macOS, `~/.local/share/com.chronodesk.app` on Linux).
    ///
    /// # Errors
    /// Returns [`DatabaseError::AppDataDir`] if the directory can't be
    /// resolved or created, or the connection/migration errors documented
    /// on [`Database::initialize_at`].
    pub async fn initialize(app_handle: &AppHandle) -> Result<Database, DatabaseError> {
        let app_data_dir = app_handle
            .path()
            .app_data_dir()
            .map_err(|e| DatabaseError::AppDataDir(e.to_string()))?;

        tokio::fs::create_dir_all(&app_data_dir)
            .await
            .map_err(|e| DatabaseError::AppDataDir(e.to_string()))?;

        let db_path = app_data_dir.join("chronodesk.db");
        Database::initialize_at(&db_path).await
    }

    /// Initializes the database at an explicit path: opens (creating if
    /// necessary) the SQLite file, configures the connection pool (WAL
    /// mode, foreign keys — see [`connection::create_pool`]), and applies
    /// all pending migrations (see [`migrations::run`]).
    ///
    /// Split out from [`Database::initialize`] so tests can point this at
    /// a `tempfile` path instead of constructing a real [`AppHandle`].
    ///
    /// # Errors
    /// - [`DatabaseError::Connection`] if the pool can't be created.
    /// - [`DatabaseError::Migration`] if a migration fails to apply. This
    ///   is treated as fatal: ContextSphere will not run against a database
    ///   in an unknown schema state.
    pub async fn initialize_at(db_path: &Path) -> Result<Database, DatabaseError> {
        tracing::info!(path = %db_path.display(), "initializing database");

        // A validated restore staged by a previous session (RC-10 M3) is
        // swapped in here, before any connection is opened, so the swap is
        // atomic from SQLite's point of view.
        let applied = apply_pending_restore(db_path).await?;
        if applied {
            tracing::info!("pending restore applied before opening the pool");
        }

        let pool = connection::create_pool(db_path).await?;
        migrations::run(&pool).await?;

        tracing::info!(
            schema_version = schema::CURRENT_SCHEMA_VERSION,
            "database ready"
        );

        Ok(Database { pool })
    }

    /// The underlying connection pool, for repositories to run queries
    /// against. Cloning it is cheap (see the type-level doc comment).
    pub fn pool(&self) -> &SqlitePool {
        &self.pool
    }
}

/// Convenience alias used by tests to build a database backed by a
/// `tempfile` path that's cleaned up automatically when the returned
/// `TempDir` guard drops. Kept in this module (rather than duplicated in
/// every test file) since every repository test needs it.
#[cfg(test)]
pub(crate) async fn test_database() -> (Database, tempfile::TempDir) {
    let temp_dir = tempfile::tempdir().expect("failed to create temp dir for test database");
    let db_path: PathBuf = temp_dir.path().join("test.db");
    let database = Database::initialize_at(&db_path)
        .await
        .expect("failed to initialize test database");
    (database, temp_dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn initialize_at_creates_database_and_applies_migrations() {
        let (database, _temp_dir) = test_database().await;

        let row: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM workspaces")
            .fetch_one(database.pool())
            .await
            .expect("workspaces table should exist after migrations run");

        assert_eq!(row.0, 0, "freshly migrated database should have no rows");
    }

    #[tokio::test]
    async fn initialize_at_is_idempotent() {
        let temp_dir = tempfile::tempdir().expect("failed to create temp dir");
        let db_path = temp_dir.path().join("test.db");

        Database::initialize_at(&db_path)
            .await
            .expect("first initialize should succeed");

        // Re-opening (and re-running migrations against) the same file
        // must not fail — this is exactly what happens on every app
        // launch after the first.
        Database::initialize_at(&db_path)
            .await
            .expect("second initialize against the same file should succeed");
    }

    #[tokio::test]
    async fn foreign_keys_are_enforced() {
        let (database, _temp_dir) = test_database().await;

        // Inserting a file that references a non-existent workspace must
        // fail with a foreign-key constraint violation, proving
        // `PRAGMA foreign_keys = ON` actually took effect on this
        // connection (SQLite silently ignores the constraint otherwise).
        let result = sqlx::query(
            "INSERT INTO files (id, workspace_id, artifact_type, path_or_url, created_at, updated_at)
             VALUES ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'file', '/tmp/x', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
        )
        .execute(database.pool())
        .await;

        assert!(
            result.is_err(),
            "expected a foreign key violation when workspace_id doesn't exist"
        );
    }

    #[tokio::test]
    async fn pending_restore_is_applied_before_the_pool_opens() {
        let temp_dir = tempfile::tempdir().expect("failed to create temp dir");
        let db_path = temp_dir.path().join("test.db");

        // Live database with one workspace.
        let live = Database::initialize_at(&db_path).await.expect("live init");
        sqlx::query(
            "INSERT INTO workspaces (id, name, created_at, updated_at, last_active_at)
             VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'live', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
        )
        .execute(live.pool())
        .await
        .expect("insert live workspace");
        drop(live);

        // A second database (the "restore source") with different content.
        // Rows are written, then a checkpoint flushes the WAL into the
        // main file so the renamed file is self-contained (a real restore
        // goes through `VACUUM INTO`, which produces exactly such a file —
        // no WAL sidecars).
        let source_path = temp_dir.path().join("source.db");
        let source = Database::initialize_at(&source_path)
            .await
            .expect("source init");
        sqlx::query(
            "INSERT INTO workspaces (id, name, created_at, updated_at, last_active_at)
             VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'restored', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
        )
        .execute(source.pool())
        .await
        .expect("insert restored workspace");
        sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
            .execute(source.pool())
            .await
            .expect("checkpoint restored source");
        drop(source);

        // Stage the source as the pending restore and re-initialize.
        tokio::fs::rename(&source_path, temp_dir.path().join(RESTORE_PENDING_FILE))
            .await
            .expect("stage restore marker");

        let reopened = Database::initialize_at(&db_path)
            .await
            .expect("re-open with restore");

        let (names,): (String,) = sqlx::query_as("SELECT name FROM workspaces")
            .fetch_one(reopened.pool())
            .await
            .expect("read restored workspace");
        assert_eq!(names, "restored", "restored data replaced the live data");

        let safety = std::fs::read_dir(temp_dir.path())
            .expect("read dir")
            .filter_map(Result::ok)
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .find(|name| name.starts_with(PRE_RESTORE_BACKUP_PREFIX));
        assert!(safety.is_some(), "pre-restore safety backup must exist");
    }

    #[tokio::test]
    async fn initialize_without_marker_is_unchanged() {
        let temp_dir = tempfile::tempdir().expect("failed to create temp dir");
        let db_path = temp_dir.path().join("test.db");

        Database::initialize_at(&db_path).await.expect("first init");
        Database::initialize_at(&db_path)
            .await
            .expect("second init");

        let names = std::fs::read_dir(temp_dir.path())
            .expect("read dir")
            .filter_map(Result::ok)
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        assert!(
            !names.iter().any(|n| n == RESTORE_PENDING_FILE),
            "no restore should be applied without a marker"
        );
    }
}
