//! [`FileWatcher`]: wraps `notify::RecommendedWatcher`, recursively
//! watching a directory and feeding normalized, debounced events into the
//! workspace-detection + timeline-recording pipeline. Runs entirely on
//! background tokio tasks — nothing here blocks the Tauri event loop, and
//! a failed OS-level watch reconnects automatically rather than silently
//! going dark.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use notify::{RecursiveMode, Watcher};
use tokio::sync::{mpsc, Mutex, RwLock};
use tokio::task::JoinHandle;
use tokio::time::interval;

use crate::app_events::{self, AppEventEmitter, NoopEmitter};
use crate::errors::WatcherError;
use crate::models::Workspace;
use crate::timeline::{TimelineActivity, TimelineEngine};
use crate::workspace::WorkspaceManager;

use super::debounce::{DebouncedEvent, DebouncedEventKind, Debouncer};
use super::event_handler::{is_ignored, normalize};

/// How long a path's events must be quiet before the debouncer emits a
/// coalesced event for it.
const DEBOUNCE_WINDOW: Duration = Duration::from_millis(500);

/// How often the background pipeline checks the debouncer for events
/// ready to flush. Independent of [`DEBOUNCE_WINDOW`] — just small enough
/// that flushed events don't lag noticeably behind the window elapsing.
const DEBOUNCE_TICK: Duration = Duration::from_millis(100);

/// Delay before attempting to re-establish a watch after the underlying
/// OS watch fails (e.g. a watched network volume disconnects).
const RECONNECT_DELAY: Duration = Duration::from_secs(2);

/// Watches directory trees and drives the full event pipeline:
/// notify → normalize → debounce → workspace detection → timeline
/// recording. One [`FileWatcher`] can hold any number of independent
/// watched roots simultaneously, each with its own background tasks.
#[derive(Clone)]
pub struct FileWatcher {
    workspace_manager: WorkspaceManager,
    timeline_engine: TimelineEngine,
    active: Arc<Mutex<HashMap<PathBuf, WatchHandle>>>,
    event_emitter: Arc<dyn AppEventEmitter>,
    proactive_engine: Arc<RwLock<Option<Arc<crate::copilot::ProactiveEngine>>>>,
}

impl FileWatcher {
    pub fn new(workspace_manager: WorkspaceManager, timeline_engine: TimelineEngine) -> Self {
        Self {
            workspace_manager,
            timeline_engine,
            active: Arc::new(Mutex::new(HashMap::new())),
            event_emitter: Arc::new(NoopEmitter),
            proactive_engine: Arc::new(tokio::sync::RwLock::new(None)),
        }
    }

    /// Swaps in a real event emitter (e.g. a [`tauri::AppHandle`]) so the
    /// pipeline's "EventEmitter → Frontend" stage actually reaches a
    /// window. Defaults to a no-op emitter from [`FileWatcher::new`] so
    /// every existing test — none of which need a running Tauri app —
    /// keeps working unchanged; `lib.rs` calls this once, in production,
    /// before the first `watch()`.
    pub fn with_event_emitter(mut self, emitter: Arc<dyn AppEventEmitter>) -> Self {
        self.event_emitter = emitter;
        self
    }

    /// Attaches the proactive engine for real-time edit detection.
    /// Wired in `lib.rs` after both engines are built; `None` in tests keeps behavior inert.
    pub fn with_proactive_engine(
        self,
        proactive: Arc<crate::copilot::ProactiveEngine>,
    ) -> Self {
        // We cannot use async here (builder is sync), so we use blocking write via try_write.
        // The lock is uncontended at startup, so this succeeds.
        if let Ok(mut guard) = self.proactive_engine.try_write() {
            *guard = Some(proactive);
        } else {
            // Fallback: spawn async set (should never happen at startup)
            let proactive_clone = proactive.clone();
            let slot = self.proactive_engine.clone();
            tokio::spawn(async move {
                let mut g = slot.write().await;
                *g = Some(proactive_clone);
            });
        }
        self
    }

    /// Async setter for late binding when the watcher is already shared (Arc).
    pub async fn set_proactive_engine(&self, proactive: Arc<crate::copilot::ProactiveEngine>) {
        let mut guard = self.proactive_engine.write().await;
        *guard = Some(proactive);
    }

    /// Starts recursively watching `root` in the background and returns
    /// once the watch is registered — spawning the background tasks is
    /// fast and non-blocking; this does not wait for the first event.
    ///
    /// Also kicks off an asynchronous initial scan of `root`'s existing
    /// contents ([`FileWatcher::spawn_initial_scan`]), so a newly watched
    /// folder's pre-existing files are indexed immediately instead of
    /// waiting for the first future filesystem event.
    ///
    /// # Errors
    /// - [`WatcherError::InvalidPath`] if `root` doesn't exist or isn't a
    ///   directory.
    /// - [`WatcherError::AlreadyWatching`] if `root` is already watched.
    pub async fn watch(&self, root: PathBuf) -> Result<(), WatcherError> {
        if !root.is_dir() {
            return Err(WatcherError::InvalidPath(root));
        }

        // Canonicalize so macOS /private/var vs /var paths are
        // consistent with the paths notify returns in events.
        let canonical = std::fs::canonicalize(&root).unwrap_or(root);

        let mut active = self.active.lock().await;
        if active.contains_key(&canonical) {
            return Err(WatcherError::AlreadyWatching(canonical));
        }

        let handle = self.spawn_watch(canonical.clone());
        active.insert(canonical.clone(), handle);

        // Index what's already there — notify only reports changes that
        // happen after the OS watch is registered, so without this scan
        // a watched folder with existing files would stay empty forever.
        self.spawn_initial_scan(canonical);
        Ok(())
    }

    /// Stops watching `root` and aborts its background tasks.
    ///
    /// # Errors
    /// [`WatcherError::NotWatching`] if `root` isn't currently watched.
    pub async fn unwatch(&self, root: &Path) -> Result<(), WatcherError> {
        let canonical = std::fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf());
        let mut active = self.active.lock().await;
        match active.remove(&canonical) {
            Some(handle) => {
                handle.stop();
                Ok(())
            }
            None => Err(WatcherError::NotWatching(root.to_path_buf())),
        }
    }

    /// Lists every directory currently being watched.
    pub async fn watched_paths(&self) -> Vec<PathBuf> {
        self.active.lock().await.keys().cloned().collect()
    }

    /// Stops all active watches and aborts their background tasks.
    /// Used for graceful shutdown on `RunEvent::Exit`.
    pub async fn stop_all(&self) {
        let mut active = self.active.lock().await;
        for (_, handle) in active.drain() {
            handle.stop();
        }
    }

    /// Spawns the three background tasks that make up one watch's
    /// pipeline (OS watch + reconnect, intake/normalize, debounce-drain
    /// + record) and returns a handle to stop them.
    fn spawn_watch(&self, root: PathBuf) -> WatchHandle {
        let (raw_tx, mut raw_rx) = mpsc::unbounded_channel::<notify::Event>();
        let debouncer = Arc::new(Debouncer::new(DEBOUNCE_WINDOW));

        // Task 1: owns the OS watch, reconnecting on failure, forwarding
        // every raw event onto `raw_tx`.
        let watcher_task = tokio::spawn(run_watch_loop(root.clone(), raw_tx));

        // Task 2: consumes raw events, normalizes them, feeds the debouncer.
        let intake_debouncer = debouncer.clone();
        let intake_task = tokio::spawn(async move {
            while let Some(event) = raw_rx.recv().await {
                for (path, kind) in normalize(&event) {
                    // Canonicalize — on macOS, notify may return /private/var/…
                    // while the watch root was registered as /var/…, which
                    // breaks the starts_with check in workspace detection.
                    let canonical = std::fs::canonicalize(&path).unwrap_or(path);
                    intake_debouncer.push(canonical, kind).await;
                }
            }
        });

        // Task 3: periodically drains debounced events and runs each
        // through workspace detection + timeline recording.
        let workspace_manager = self.workspace_manager.clone();
        let timeline_engine = self.timeline_engine.clone();
        let event_emitter = self.event_emitter.clone();
        let proactive_engine = self.proactive_engine.clone();
        let pipeline_root = root.clone();
        let pipeline_debouncer = debouncer;
        let pipeline_task = tokio::spawn(async move {
            let mut ticker = interval(DEBOUNCE_TICK);
            loop {
                ticker.tick().await;
                for event in pipeline_debouncer.drain_ready().await {
                    // Clone proactive handle for this event
                    let proactive = proactive_engine.read().await.clone();
                    if let Err(err) = process_event(
                        &workspace_manager,
                        &timeline_engine,
                        event_emitter.as_ref(),
                        proactive.as_ref(),
                        &pipeline_root,
                        event,
                    )
                    .await
                    {
                        tracing::error!(error = %err, "failed to process file watcher event");
                    }
                }
            }
        });

        WatchHandle {
            root,
            watcher_task,
            intake_task,
            pipeline_task,
        }
    }

    /// Scans `root`'s existing contents and indexes every non-ignored
    /// file into the workspace [`WorkspaceManager`] resolves for it.
    ///
    /// Runs entirely in the background so [`FileWatcher::watch`] returns
    /// immediately; `notify` only reports changes that happen after the
    /// OS watch is registered, so without this initial pass a folder
    /// that already contains files would never populate its workspace.
    ///
    /// Every touched workspace gets a final `workspace:updated` event so
    /// open frontends refresh their file counts without a manual reload.
    fn spawn_initial_scan(&self, root: PathBuf) {
        let workspace_manager = self.workspace_manager.clone();
        let timeline_engine = self.timeline_engine.clone();
        let event_emitter = self.event_emitter.clone();
        tokio::spawn(async move {
            let mut touched: Vec<Workspace> = Vec::new();
            let indexed = index_existing_files(&workspace_manager, &timeline_engine, &root, &mut touched).await;
            for workspace in &touched {
                app_events::emit(
                    event_emitter.as_ref(),
                    app_events::EVENT_WORKSPACE_UPDATED,
                    workspace,
                );
            }
            tracing::info!(
                path = %root.display(),
                files = indexed,
                workspaces = touched.len(),
                "initial directory scan complete",
            );
        });
    }
}

/// Resolves the workspace a single debounced event belongs to, records
/// the matching timeline activity, and emits the pipeline's final
/// "EventEmitter → Frontend" stage: `file:changed`, `timeline:event_added`,
/// and `workspace:updated` (the workspace's `last_active_at` changed as
/// part of recording activity against it). A path that resolves to no
/// workspace — which, since the watch root is an implicit workspace
/// root, now only happens if the event path falls outside `watch_root`
/// — is silently skipped (see
/// [`WorkspaceManager::resolve_workspace_for_path`]), not treated as an
/// error, and emits nothing.
async fn process_event(
    workspace_manager: &WorkspaceManager,
    timeline_engine: &TimelineEngine,
    event_emitter: &dyn AppEventEmitter,
    proactive_engine: Option<&Arc<crate::copilot::ProactiveEngine>>,
    watch_root: &Path,
    event: DebouncedEvent,
) -> Result<(), crate::errors::DatabaseError> {
    // Ensure both the event path and watch root are canonicalized on
    // macOS — notify may return /private/var/… while the watch root
    // was registered with /var/…, which breaks starts_with checks.
    let canonical_root =
        std::fs::canonicalize(watch_root).unwrap_or_else(|_| watch_root.to_path_buf());
    let Some(workspace) = workspace_manager
        .resolve_workspace_for_path(&event.path, &canonical_root)
        .await?
    else {
        return Ok(());
    };

    let path_string = event.path.to_string_lossy().into_owned();
    let activity = match event.kind {
        DebouncedEventKind::Created => TimelineActivity::FileCreated {
            path: path_string.clone(),
        },
        DebouncedEventKind::Modified => TimelineActivity::FileModified {
            path: path_string.clone(),
        },
        DebouncedEventKind::Removed => TimelineActivity::FileDeleted {
            path: path_string.clone(),
        },
    };

    let timeline_event = timeline_engine.record_now(workspace.id, activity).await?;

    app_events::emit(
        event_emitter,
        app_events::EVENT_FILE_CHANGED,
        &serde_json::json!({ "workspaceId": workspace.id, "path": path_string, "kind": format!("{:?}", event.kind) }),
    );
    app_events::emit(
        event_emitter,
        app_events::EVENT_TIMELINE_EVENT_ADDED,
        &timeline_event,
    );
    app_events::emit(
        event_emitter,
        app_events::EVENT_WORKSPACE_UPDATED,
        &workspace,
    );

    // Proactive hook: real event-driven trigger for repeated-edits and throttled checks
    if let Some(proactive) = proactive_engine {
        let ws_id = workspace.id;
        let event_type = match event.kind {
            DebouncedEventKind::Modified => "edit",
            DebouncedEventKind::Created => "create",
            DebouncedEventKind::Removed => "delete",
        };
        if let Err(err) = proactive.on_timeline_event(ws_id, event_type).await {
            tracing::warn!(error = %err, workspace_id = %ws_id, "proactive on_timeline_event failed");
        }
    }

    Ok(())
}

/// Iterative recursive walk of `root` (an explicit stack, so deeply
/// nested trees can't overflow the task's call stack), registering every
/// non-ignored file into the workspace [`WorkspaceManager`] resolves for
/// it via [`TimelineEngine::register_file`] — file artifacts only, no
/// timeline events, since pre-existing files weren't "created" now.
///
/// Inaccessible directories/entries and per-file failures are logged and
/// skipped — a scan must never fail the watch it runs under. Returns the
/// number of files indexed; `touched` collects the distinct workspaces
/// that gained artifacts (for the caller's `workspace:updated` events).
async fn index_existing_files(
    workspace_manager: &WorkspaceManager,
    timeline_engine: &TimelineEngine,
    root: &Path,
    touched: &mut Vec<Workspace>,
) -> usize {
    let mut indexed = 0;
    let mut stack = vec![root.to_path_buf()];

    while let Some(dir) = stack.pop() {
        let entries = match std::fs::read_dir(&dir) {
            Ok(entries) => entries,
            Err(err) => {
                tracing::warn!(path = %dir.display(), error = %err, "initial scan: skipping unreadable directory");
                continue;
            }
        };

        for entry in entries {
            let entry = match entry {
                Ok(entry) => entry,
                Err(err) => {
                    tracing::warn!(path = %dir.display(), error = %err, "initial scan: skipping unreadable entry");
                    continue;
                }
            };

            let path = entry.path();
            if is_ignored(&path) {
                continue;
            }

            let file_type = match entry.file_type() {
                Ok(file_type) => file_type,
                Err(err) => {
                    tracing::warn!(path = %path.display(), error = %err, "initial scan: skipping entry with unknown type");
                    continue;
                }
            };

            if file_type.is_dir() {
                stack.push(path);
                continue;
            }
            if !file_type.is_file() {
                continue;
            }

            let canonical = std::fs::canonicalize(&path).unwrap_or(path);
            let workspace = match workspace_manager
                .resolve_workspace_for_path(&canonical, root)
                .await
            {
                Ok(Some(workspace)) => workspace,
                Ok(None) => continue,
                Err(err) => {
                    tracing::warn!(path = %canonical.display(), error = %err, "initial scan: workspace resolution failed");
                    continue;
                }
            };

            if let Err(err) = timeline_engine
                .register_file(workspace.id, &canonical.to_string_lossy())
                .await
            {
                tracing::warn!(path = %canonical.display(), error = %err, "initial scan: failed to index file");
                continue;
            }

            indexed += 1;
            if !touched.iter().any(|w| w.id == workspace.id) {
                touched.push(workspace);
            }
        }
    }

    indexed
}

/// Owns the OS-level watch for one directory, reconnecting automatically
/// if the underlying watch fails (e.g. a watched volume disconnects and
/// later reconnects). Runs until its task is aborted via
/// [`WatchHandle::stop`], or the raw-event receiver is dropped (pipeline
/// shutdown).
async fn run_watch_loop(root: PathBuf, raw_tx: mpsc::UnboundedSender<notify::Event>) {
    loop {
        let (event_tx, mut event_rx) = mpsc::unbounded_channel::<notify::Result<notify::Event>>();

        let mut watcher = match notify::recommended_watcher(
            move |res: notify::Result<notify::Event>| {
                // `notify`'s callback runs on its own internal thread; this
                // send is the hop back onto the tokio runtime.
                let _ = event_tx.send(res);
            },
        ) {
            Ok(w) => w,
            Err(err) => {
                tracing::error!(error = %err, path = %root.display(), "failed to create file watcher, retrying");
                tokio::time::sleep(RECONNECT_DELAY).await;
                continue;
            }
        };

        if let Err(err) = watcher.watch(&root, RecursiveMode::Recursive) {
            tracing::error!(error = %err, path = %root.display(), "failed to start watching, retrying");
            tokio::time::sleep(RECONNECT_DELAY).await;
            continue;
        }

        tracing::info!(path = %root.display(), "file watcher started");

        let mut watch_failed = false;
        while let Some(result) = event_rx.recv().await {
            match result {
                Ok(event) => {
                    tracing::trace!(?event, "raw notify event");
                    if raw_tx.send(event).is_err() {
                        return;
                    }
                }
                Err(err) => {
                    tracing::warn!(error = %err, path = %root.display(), "file watcher reported an error, reconnecting");
                    watch_failed = true;
                    break;
                }
            }
        }

        drop(watcher);
        tracing::info!(path = %root.display(), "file watcher stopped");

        if !watch_failed {
            // The event channel closed without an explicit watch error —
            // the watcher was dropped intentionally (shutdown), not a
            // failure. Don't reconnect.
            return;
        }

        tokio::time::sleep(RECONNECT_DELAY).await;
    }
}

/// Handle to one watched root's background tasks.
struct WatchHandle {
    root: PathBuf,
    watcher_task: JoinHandle<()>,
    intake_task: JoinHandle<()>,
    pipeline_task: JoinHandle<()>,
}

impl WatchHandle {
    /// Aborts every background task associated with this watch.
    fn stop(&self) {
        self.watcher_task.abort();
        self.intake_task.abort();
        self.pipeline_task.abort();
        tracing::info!(path = %self.root.display(), "file watcher tasks stopped");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::test_database;
    use crate::repositories::{FileRepository, TimelineRepository, WorkspaceRepository};
    use crate::services::{TimelineService, WorkspaceService};
    use crate::timeline::recorder::TimelineRecorder;
    use std::fs;
    use tempfile::tempdir;

    async fn test_watcher() -> (FileWatcher, tempfile::TempDir) {
        let (database, db_guard) = test_database().await;
        let workspace_manager = WorkspaceManager::new(WorkspaceService::new(
            WorkspaceRepository::new(database.pool().clone()),
            TimelineRepository::new(database.pool().clone()),
        ));
        let timeline_engine = TimelineEngine::new(TimelineService::new(
            TimelineRecorder::new(
                FileRepository::new(database.pool().clone()),
                TimelineRepository::new(database.pool().clone()),
            ),
            TimelineRepository::new(database.pool().clone()),
        ));

        (
            FileWatcher::new(workspace_manager, timeline_engine),
            db_guard,
        )
    }

    #[tokio::test]
    async fn watch_rejects_a_nonexistent_path() {
        let (watcher, _db_guard) = test_watcher().await;

        let result = watcher
            .watch(PathBuf::from("/definitely/not/a/real/path"))
            .await;
        assert!(matches!(result, Err(WatcherError::InvalidPath(_))));
    }

    #[tokio::test]
    async fn watch_rejects_watching_the_same_path_twice() {
        let (watcher, _db_guard) = test_watcher().await;
        let root = tempdir().unwrap();
        let canonical =
            std::fs::canonicalize(root.path()).unwrap_or_else(|_| root.path().to_path_buf());

        watcher.watch(root.path().to_path_buf()).await.unwrap();
        let second = watcher.watch(root.path().to_path_buf()).await;

        assert!(matches!(second, Err(WatcherError::AlreadyWatching(_))));

        watcher.unwatch(&canonical).await.unwrap();
    }

    #[tokio::test]
    async fn unwatch_unknown_path_returns_not_watching() {
        let (watcher, _db_guard) = test_watcher().await;
        let root = tempdir().unwrap();

        let result = watcher.unwatch(root.path()).await;
        assert!(matches!(result, Err(WatcherError::NotWatching(_))));
    }

    #[tokio::test]
    async fn watched_paths_reflects_watch_and_unwatch() {
        let (watcher, _db_guard) = test_watcher().await;
        let root = tempdir().unwrap();
        let canonical =
            std::fs::canonicalize(root.path()).unwrap_or_else(|_| root.path().to_path_buf());

        assert!(watcher.watched_paths().await.is_empty());

        watcher.watch(root.path().to_path_buf()).await.unwrap();
        assert_eq!(watcher.watched_paths().await, vec![canonical.clone()]);

        watcher.unwatch(&canonical).await.unwrap();
        assert!(watcher.watched_paths().await.is_empty());
    }

    /// End-to-end: a real file write under a watched, detectable
    /// workspace root eventually produces a timeline event. Uses a
    /// generous timeout since this exercises the real OS filesystem
    /// notification mechanism, debounce window, and poll tick together.
    #[tokio::test]
    async fn writing_a_file_under_a_detectable_root_produces_a_timeline_event() {
        let (database, _db_guard) = test_database().await;
        let workspace_repository = WorkspaceRepository::new(database.pool().clone());
        let workspace_manager = WorkspaceManager::new(WorkspaceService::new(
            workspace_repository.clone(),
            TimelineRepository::new(database.pool().clone()),
        ));
        let timeline_repository = TimelineRepository::new(database.pool().clone());
        let timeline_engine = TimelineEngine::new(TimelineService::new(
            TimelineRecorder::new(
                FileRepository::new(database.pool().clone()),
                timeline_repository.clone(),
            ),
            timeline_repository.clone(),
        ));
        let watcher = FileWatcher::new(workspace_manager, timeline_engine);

        let root = tempdir().unwrap();
        let canonical_root =
            std::fs::canonicalize(root.path()).unwrap_or_else(|_| root.path().to_path_buf());
        fs::create_dir(canonical_root.join(".git")).unwrap();

        watcher.watch(canonical_root.clone()).await.unwrap();

        // Give the watch loop a moment to actually register with the OS
        // before writing, then write the file that should be detected.
        tokio::time::sleep(Duration::from_millis(200)).await;
        fs::write(canonical_root.join("main.rs"), "fn main() {}").unwrap();

        let root_path_str = canonical_root.to_string_lossy().into_owned();
        // Debounce window (500ms) + tick (100ms) + generous OS-event
        // latency margin.
        // Poll for the workspace first — process_event creates the workspace
        // inside resolve_workspace_for_path before it records the file event,
        // so the workspace appears first.
        let workspace = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if let Some(ws) = workspace_repository
                    .find_by_root_path(&root_path_str)
                    .await
                    .unwrap()
                {
                    return ws;
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        })
        .await
        .expect("workspace should be auto-created within the timeout");

        // Then poll for the timeline event — process_event records the
        // file event after creating the workspace, so there is a scheduling
        // window where the workspace exists but the file event hasn't been
        // committed yet. The debounce window (500ms) + tick (100ms) + OS
        // latency means the event arrives within ~600ms of the write, but
        // the 5s timeout guards against scheduler stalls on CI.
        let has_file_event = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let events = timeline_repository
                    .list_by_workspace(workspace.id, None)
                    .await
                    .unwrap();
                if events.iter().any(|e| {
                    matches!(
                        e.event_type,
                        crate::models::TimelineEventType::Create
                            | crate::models::TimelineEventType::Edit
                    )
                }) {
                    return true;
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        })
        .await
        .expect("timeline event should appear within the timeout");

        assert!(
            has_file_event,
            "expected a timeline event for the written file (write+metadata may coalesce to Edit)"
        );

        watcher.unwatch(&canonical_root).await.unwrap();
    }

    /// The bug this guards against: adding a watched folder that already
    /// contains files used to leave its workspace at 0 files, because
    /// `notify` only reports changes after the watch is registered. The
    /// initial scan must index the pre-existing tree (nested files
    /// included, ignored paths excluded) with no fake timeline events,
    /// and a remove/re-add must not duplicate the indexed rows.
    #[tokio::test]
    async fn adding_a_watch_indexes_pre_existing_files_without_duplicates() {
        let (database, _db_guard) = test_database().await;
        let file_repository = FileRepository::new(database.pool().clone());
        let workspace_repository = WorkspaceRepository::new(database.pool().clone());
        let workspace_manager = WorkspaceManager::new(WorkspaceService::new(
            workspace_repository.clone(),
            TimelineRepository::new(database.pool().clone()),
        ));
        let timeline_repository = TimelineRepository::new(database.pool().clone());
        let timeline_engine = TimelineEngine::new(TimelineService::new(
            TimelineRecorder::new(
                FileRepository::new(database.pool().clone()),
                timeline_repository.clone(),
            ),
            timeline_repository.clone(),
        ));
        let watcher = FileWatcher::new(workspace_manager, timeline_engine);

        let root = tempdir().unwrap();
        let canonical_root =
            std::fs::canonicalize(root.path()).unwrap_or_else(|_| root.path().to_path_buf());
        fs::create_dir_all(canonical_root.join("src")).unwrap();
        fs::write(canonical_root.join("src/main.rs"), "fn main() {}").unwrap();
        fs::write(canonical_root.join("README.md"), "# hi").unwrap();
        // Ignored content must be skipped by the scan, matching the
        // live-event ignore filter.
        fs::create_dir_all(canonical_root.join("node_modules/pkg")).unwrap();
        fs::write(canonical_root.join("node_modules/pkg/index.js"), "x").unwrap();
        fs::write(canonical_root.join(".DS_Store"), "").unwrap();

        watcher.watch(canonical_root.clone()).await.unwrap();

        let root_path_str = canonical_root.to_string_lossy().into_owned();
        // The workspace has no project markers, so it is created via the
        // watch-root fallback — exactly the "loose folder" case that used
        // to stay at zero files.
        let workspace = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if let Some(ws) = workspace_repository
                    .find_by_root_path(&root_path_str)
                    .await
                    .unwrap()
                {
                    let files = file_repository.list_by_workspace(ws.id).await.unwrap();
                    if files.len() == 2 {
                        return ws;
                    }
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        })
        .await
        .expect("initial scan should index the pre-existing files within the timeout");

        let files = file_repository.list_by_workspace(workspace.id).await.unwrap();
        let mut paths: Vec<String> = files.iter().map(|f| f.path_or_url.clone()).collect();
        paths.sort();
        assert_eq!(
            paths,
            vec![
                format!("{}/README.md", canonical_root.display()),
                format!("{}/src/main.rs", canonical_root.display()),
            ],
            "nested files must be indexed and ignored paths must not"
        );

        let events = timeline_repository
            .list_by_workspace(workspace.id, None)
            .await
            .unwrap();
        assert!(
            events
                .iter()
                .all(|e| e.event_type == crate::models::TimelineEventType::WorkspaceSwitch),
            "indexing pre-existing files must not fabricate file timeline events \
             (only the workspace-creation switch may exist)"
        );

        // Remove and re-add the same path: the second scan must reuse the
        // existing rows, not duplicate them.
        watcher.unwatch(&canonical_root).await.unwrap();
        watcher.watch(canonical_root.clone()).await.unwrap();
        tokio::time::sleep(Duration::from_millis(1500)).await;

        let files_after = file_repository.list_by_workspace(workspace.id).await.unwrap();
        assert_eq!(
            files_after.len(),
            2,
            "re-adding a watch path must not duplicate file artifacts"
        );
    }
}
