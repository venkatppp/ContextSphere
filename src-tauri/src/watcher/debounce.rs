//! Per-path event debouncing.
//!
//! Editors commonly fire several raw filesystem events for a single
//! logical save (write a temp file, then rename it over the original),
//! and a build or `git checkout` touching hundreds of files in one pass
//! would otherwise generate hundreds of individual timeline events. The
//! debouncer coalesces same-path events within a time window into one,
//! keeping only the most recent kind — the blueprint's "Debouncing"
//! requirement.
//!
//! Deliberately independent of the `notify` crate: [`super::event_handler`]
//! normalizes raw `notify::Event`s down to the `(PathBuf, DebouncedEventKind)`
//! shape this module works with, so `Debouncer` itself is unit-testable
//! without touching a real filesystem or the `notify` API at all.

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use tokio::sync::Mutex;

/// The normalized kind of change a debounced event represents.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DebouncedEventKind {
    Created,
    Modified,
    Removed,
    Renamed,
}

/// A single coalesced event, ready for the pipeline's next stage
/// (workspace detection).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DebouncedEvent {
    pub path: PathBuf,
    pub kind: DebouncedEventKind,
    /// For `Renamed`, the previous path. `None` for other kinds.
    pub from: Option<PathBuf>,
}

struct PendingEvent {
    kind: DebouncedEventKind,
    from: Option<PathBuf>,
    last_seen: Instant,
}

/// Coalesces per-path events within `window`.
///
/// Implemented as a shared map plus a periodic sweep (see
/// [`Debouncer::drain_ready`], called on a tick by
/// [`super::watcher::FileWatcher`]) rather than one timer task per path —
/// watching a tree with thousands of files must not mean spawning
/// thousands of concurrent timers.
pub struct Debouncer {
    window: Duration,
    pending: Mutex<HashMap<PathBuf, PendingEvent>>,
}

impl Debouncer {
    pub fn new(window: Duration) -> Self {
        Self {
            window,
            pending: Mutex::new(HashMap::new()),
        }
    }

    /// Records a new event for `path`, coalescing with any pending event
    /// for the same path rather than emitting immediately.
    ///
    /// Merge rule: a `Removed` is terminal for the window — it is never
    /// cancelled out (a duplicate late `Create` on macOS must not make a
    /// real deletion disappear) and no later event kind can overwrite it
    /// (the trailing `Modify` burst FSEvents delivers right after a
    /// deletion must not become a bogus edit for a file that no longer
    /// exists). Any other combination keeps the *latest* kind and resets
    /// the window. `Renamed` is treated as `Removed` for the `from` path
    /// and `Created` for the `to` path at the event-handler level, so the
    /// debouncer never sees a bare `Renamed` that needs merging — it sees
    /// the two correlated events with an explicit `from`.
    pub async fn push(&self, path: PathBuf, kind: DebouncedEventKind) {
        self.push_with_from(path, kind, None).await
    }

    /// Like `push`, but for `Renamed` carries the `from` path for correlation.
    pub async fn push_with_from(
        &self,
        path: PathBuf,
        kind: DebouncedEventKind,
        from: Option<PathBuf>,
    ) {
        let mut pending = self.pending.lock().await;

        let merged_kind = match (pending.get(&path), kind) {
            (_, DebouncedEventKind::Removed) => DebouncedEventKind::Removed,
            (_, DebouncedEventKind::Renamed) => DebouncedEventKind::Renamed,
            (Some(existing), _) if existing.kind == DebouncedEventKind::Removed => {
                DebouncedEventKind::Removed
            }
            (Some(existing), _) if existing.kind == DebouncedEventKind::Renamed => {
                DebouncedEventKind::Renamed
            }
            _ => kind,
        };

        // For Renamed, keep the original `from` if we already have one (first wins)
        let merged_from = match pending.get(&path) {
            Some(existing) if existing.from.is_some() => existing.from.clone(),
            _ => from,
        };

        pending.insert(
            path,
            PendingEvent {
                kind: merged_kind,
                from: merged_from,
                last_seen: Instant::now(),
            },
        );
    }

    /// Removes and returns every pending event whose debounce window has
    /// elapsed since its last update.
    pub async fn drain_ready(&self) -> Vec<DebouncedEvent> {
        let now = Instant::now();
        let mut pending = self.pending.lock().await;

        let ready_paths: Vec<PathBuf> = pending
            .iter()
            .filter(|(_, event)| now.duration_since(event.last_seen) >= self.window)
            .map(|(path, _)| path.clone())
            .collect();

        ready_paths
            .into_iter()
            .filter_map(|path| {
                pending.remove(&path).map(|event| DebouncedEvent {
                    path,
                    kind: event.kind,
                    from: event.from,
                })
            })
            .collect()
    }

    /// True if no events are currently pending. Exposed for tests and
    /// diagnostics.
    pub async fn is_empty(&self) -> bool {
        self.pending.lock().await.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn path(s: &str) -> PathBuf {
        PathBuf::from(s)
    }

    #[tokio::test]
    async fn a_single_event_is_not_ready_before_the_window_elapses() {
        let debouncer = Debouncer::new(Duration::from_millis(50));
        debouncer
            .push(path("/a.txt"), DebouncedEventKind::Created)
            .await;

        assert!(debouncer.drain_ready().await.is_empty());
        assert!(!debouncer.is_empty().await);
    }

    #[tokio::test]
    async fn a_single_event_is_ready_after_the_window_elapses() {
        let debouncer = Debouncer::new(Duration::from_millis(20));
        debouncer
            .push(path("/a.txt"), DebouncedEventKind::Created)
            .await;

        tokio::time::sleep(Duration::from_millis(30)).await;

        let ready = debouncer.drain_ready().await;
        assert_eq!(ready.len(), 1);
        assert_eq!(ready[0].path, Path::new("/a.txt"));
        assert_eq!(ready[0].kind, DebouncedEventKind::Created);
        assert!(debouncer.is_empty().await);
    }

    #[tokio::test]
    async fn repeated_events_for_the_same_path_coalesce_into_one() {
        let debouncer = Debouncer::new(Duration::from_millis(30));

        debouncer
            .push(path("/a.txt"), DebouncedEventKind::Created)
            .await;
        tokio::time::sleep(Duration::from_millis(10)).await;
        debouncer
            .push(path("/a.txt"), DebouncedEventKind::Modified)
            .await;
        tokio::time::sleep(Duration::from_millis(10)).await;
        debouncer
            .push(path("/a.txt"), DebouncedEventKind::Modified)
            .await;

        // Not ready yet — the last push reset the window.
        assert!(debouncer.drain_ready().await.is_empty());

        tokio::time::sleep(Duration::from_millis(35)).await;
        let ready = debouncer.drain_ready().await;

        assert_eq!(
            ready.len(),
            1,
            "three events on one path must coalesce into one"
        );
        assert_eq!(
            ready[0].kind,
            DebouncedEventKind::Modified,
            "the latest kind wins"
        );
    }

    #[tokio::test]
    async fn removed_is_terminal_and_not_cancelled_by_a_stale_create() {
        let debouncer = Debouncer::new(Duration::from_millis(50));

        debouncer
            .push(path("/a.txt"), DebouncedEventKind::Created)
            .await;
        // The create is drained (recorded) before the deletion burst.
        tokio::time::sleep(Duration::from_millis(60)).await;
        assert_eq!(debouncer.drain_ready().await.len(), 1);

        // macOS FSEvents can re-deliver a duplicate Create microseconds
        // before the Remove (plus a trailing Modify) at deletion time.
        debouncer
            .push(path("/a.txt"), DebouncedEventKind::Created)
            .await;
        debouncer
            .push(path("/a.txt"), DebouncedEventKind::Removed)
            .await;
        debouncer
            .push(path("/a.txt"), DebouncedEventKind::Modified)
            .await;

        assert!(
            !debouncer.is_empty().await,
            "a removal within the window must stay pending"
        );

        tokio::time::sleep(Duration::from_millis(60)).await;
        let ready = debouncer.drain_ready().await;
        assert_eq!(
            ready.len(),
            1,
            "the burst must coalesce into a single event"
        );
        assert_eq!(
            ready[0].kind,
            DebouncedEventKind::Removed,
            "the removal must win over the trailing Modify"
        );
    }

    #[tokio::test]
    async fn different_paths_are_tracked_independently() {
        let debouncer = Debouncer::new(Duration::from_millis(20));

        debouncer
            .push(path("/a.txt"), DebouncedEventKind::Created)
            .await;
        tokio::time::sleep(Duration::from_millis(25)).await;
        debouncer
            .push(path("/b.txt"), DebouncedEventKind::Created)
            .await;

        // /a.txt's window has elapsed; /b.txt's has not.
        let ready = debouncer.drain_ready().await;
        assert_eq!(ready.len(), 1);
        assert_eq!(ready[0].path, Path::new("/a.txt"));
        assert!(
            !debouncer.is_empty().await,
            "/b.txt should still be pending"
        );
    }
}
