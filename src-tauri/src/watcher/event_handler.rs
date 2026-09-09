//! Raw `notify::Event` normalization and ignore-path filtering.
//!
//! Two responsibilities, kept together because they both operate on the
//! same raw event before anything downstream (the debouncer, workspace
//! detection) ever sees it:
//! 1. [`is_ignored`] — drop paths inside VCS/dependency/build
//!    directories, OS metadata files, and editor temp files, so the
//!    watcher never generates timeline noise for `.git/`, `node_modules/`,
//!    `target/`, `.DS_Store`, Vim swap files, and the like.
//! 2. [`normalize`] — collapse `notify`'s (larger, platform-leaky)
//!    `EventKind` taxonomy down to [`DebouncedEventKind`]'s three
//!    variants, including treating a same-event rename
//!    (`ModifyKind::Name(RenameMode::Both)`) as a remove-then-create pair
//!    at the two paths involved.

use std::path::{Path, PathBuf};

use notify::event::{ModifyKind, RenameMode};
use notify::{Event, EventKind};

use super::debounce::DebouncedEventKind;

/// Directory names never watched/recorded, regardless of where they
/// appear in a watched tree — build output and VCS/dependency
/// directories generate enormous, uninteresting event volume and are
/// explicitly called out by the blueprint's ignore-list requirement.
///
/// This is the single source of truth for generated/build/dependency
/// exclusions; the timeline recorder applies the same filter
/// (`crate::watcher::event_handler::is_ignored`) as defense-in-depth so
/// no layer (timeline, search, knowledge graph, semantic, analytics)
/// can ingest these paths.
const IGNORED_DIR_NAMES: &[&str] = &[
    ".git",
    "target",
    "node_modules",
    "dist",
    "build",
    "out",
    ".cache",
    "coverage",
    ".next",
    ".turbo",
    ".parcel-cache",
    ".vite",
    "vendor",
    "__pycache__",
    ".venv",
    "venv",
    ".pytest_cache",
    ".mypy_cache",
];

/// True if `path` should never generate a timeline event: it sits inside
/// an ignored directory, is a known OS metadata file, is a dotfile, or
/// looks like a transient editor/OS temp file.
pub fn is_ignored(path: &Path) -> bool {
    let in_ignored_dir = path.components().any(|component| {
        component
            .as_os_str()
            .to_str()
            .is_some_and(|name| IGNORED_DIR_NAMES.contains(&name))
    });
    if in_ignored_dir {
        return true;
    }

    let Some(file_name) = path.file_name().and_then(|n| n.to_str()) else {
        return false;
    };

    if matches!(file_name, ".DS_Store" | "Thumbs.db" | "desktop.ini") {
        return true;
    }

    // Any dotfile/hidden file — covers editor config, `.env`, lockfiles,
    // etc. that are almost never meaningful "project work" on their own.
    if file_name.starts_with('.') {
        return true;
    }

    // Common editor/OS temp-file patterns: backup files, Vim swap files,
    // and files still mid-write (a trailing `~`/`.tmp`, or Office's
    // leading `~$` lock-file prefix).
    if file_name.ends_with('~')
        || file_name.ends_with(".tmp")
        || file_name.ends_with(".swp")
        || file_name.ends_with(".swx")
        || file_name.starts_with("~$")
    {
        return true;
    }

    false
}

/// A normalized, debounced-ready event. For `Renamed`, `from` is `Some(old)`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NormalizedEvent {
    pub path: PathBuf,
    pub kind: DebouncedEventKind,
    pub from: Option<PathBuf>,
}

/// Normalizes a raw `notify::Event` into zero or more `NormalizedEvent`s
/// ready for the debouncer, after dropping every ignored path.
///
/// `notify::Event` can carry multiple paths — a same-event rename
/// (`ModifyKind::Name(RenameMode::Both)`) carries both the old and new
/// path — so this returns a `Vec` rather than a single optional pair.
/// Event kinds this watcher doesn't act on (metadata-only changes,
/// access events, and rename events that only report the old *or* new
/// path in isolation rather than as a `Both` pair — a platform-dependent
/// case `notify` itself documents as best-effort) normalize to an empty
/// result rather than a guess.
///
/// For `RenameMode::Both` with 2 paths, we emit a single `Renamed` event
/// with `path = new`, `from = Some(old)`, preserving the correlation so the
/// pipeline can do an `UPDATE` rather than `DELETE+INSERT` and keep `files.id`.
pub fn normalize(event: &Event) -> Vec<NormalizedEvent> {
    let raw: Vec<NormalizedEvent> = match &event.kind {
        EventKind::Create(_) => event
            .paths
            .iter()
            .cloned()
            .map(|p| NormalizedEvent {
                path: p,
                kind: DebouncedEventKind::Created,
                from: None,
            })
            .collect(),
        EventKind::Modify(ModifyKind::Name(RenameMode::Both)) if event.paths.len() == 2 => {
            vec![NormalizedEvent {
                path: event.paths[1].clone(),
                kind: DebouncedEventKind::Renamed,
                from: Some(event.paths[0].clone()),
            }]
        }
        EventKind::Modify(_) => event
            .paths
            .iter()
            .cloned()
            .map(|p| NormalizedEvent {
                path: p,
                kind: DebouncedEventKind::Modified,
                from: None,
            })
            .collect(),
        EventKind::Remove(_) => event
            .paths
            .iter()
            .cloned()
            .map(|p| NormalizedEvent {
                path: p,
                kind: DebouncedEventKind::Removed,
                from: None,
            })
            .collect(),
        _ => Vec::new(),
    };

    raw.into_iter()
        .filter(|e| !is_ignored(&e.path))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use notify::event::CreateKind;

    #[test]
    fn ignores_paths_inside_dot_git() {
        assert!(is_ignored(Path::new("/repo/.git/HEAD")));
    }

    #[test]
    fn ignores_paths_inside_node_modules_and_target() {
        assert!(is_ignored(Path::new("/repo/node_modules/lib/index.js")));
        assert!(is_ignored(Path::new("/repo/target/debug/app")));
    }

    #[test]
    fn ignores_os_metadata_files() {
        assert!(is_ignored(Path::new("/repo/.DS_Store")));
        assert!(is_ignored(Path::new("/repo/Thumbs.db")));
    }

    #[test]
    fn ignores_editor_temp_files() {
        assert!(is_ignored(Path::new("/repo/src/main.rs~")));
        assert!(is_ignored(Path::new("/repo/src/.main.rs.swp")));
        assert!(is_ignored(Path::new("/repo/~$document.docx")));
    }

    #[test]
    fn does_not_ignore_ordinary_project_files() {
        assert!(!is_ignored(Path::new("/repo/src/main.rs")));
        assert!(!is_ignored(Path::new("/repo/README.md")));
        assert!(!is_ignored(Path::new("/repo/package.json")));
    }

    #[test]
    fn normalize_maps_create_event_to_created() {
        let event =
            Event::new(EventKind::Create(CreateKind::File)).add_path(PathBuf::from("/repo/new.rs"));

        let result = normalize(&event);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].path, PathBuf::from("/repo/new.rs"));
        assert_eq!(result[0].kind, DebouncedEventKind::Created);
        assert!(result[0].from.is_none());
    }

    #[test]
    fn normalize_drops_ignored_paths() {
        let event = Event::new(EventKind::Create(CreateKind::File))
            .add_path(PathBuf::from("/repo/node_modules/x.js"));

        assert!(normalize(&event).is_empty());
    }

    #[test]
    fn normalize_maps_a_same_event_rename_to_remove_then_create() {
        let event = Event::new(EventKind::Modify(ModifyKind::Name(RenameMode::Both)))
            .add_path(PathBuf::from("/repo/old.rs"))
            .add_path(PathBuf::from("/repo/new.rs"));

        let result = normalize(&event);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].path, PathBuf::from("/repo/new.rs"));
        assert_eq!(result[0].kind, DebouncedEventKind::Renamed);
        assert_eq!(result[0].from, Some(PathBuf::from("/repo/old.rs")));
    }
}
