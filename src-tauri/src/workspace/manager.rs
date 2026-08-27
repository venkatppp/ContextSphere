//! Workspace Engine orchestration (blueprint §4.2): ties the
//! boundary-detection heuristics in [`super::detector`] to persistence via
//! [`WorkspaceService`]. This is the module the file watcher pipeline
//! calls on every relevant filesystem event.

use std::path::Path;

use crate::errors::DatabaseError;
use crate::models::{CreateWorkspaceInput, Workspace};
use crate::services::WorkspaceService;

use super::detector::{self, DetectedWorkspaceRoot};

/// Automatic workspace lifecycle management: given filesystem activity,
/// finds the workspace it belongs to (creating one if this is the first
/// activity ever seen under that root) and marks it as just-opened.
///
/// Holds a [`WorkspaceService`] rather than a raw repository — every
/// workspace this manager touches should also get the timeline side
/// effects (`workspace_switch` events) that only the service layer
/// knows to record; a manager that reached past the service into
/// `WorkspaceRepository` directly would silently lose that trail.
#[derive(Debug, Clone)]
pub struct WorkspaceManager {
    workspace_service: WorkspaceService,
}

impl WorkspaceManager {
    pub fn new(workspace_service: WorkspaceService) -> Self {
        Self { workspace_service }
    }

    /// Given a file path that just had activity under `watch_root`,
    /// finds or creates the workspace it belongs to and marks it opened.
    ///
    /// Returns `Ok(None)` — not an error — only if `file_path` isn't
    /// under `watch_root` at all. When no ancestor directory within
    /// `watch_root` clears the marker-detection threshold (blueprint
    /// §2.2's heuristics in [`super::heuristics`]) — e.g. a loose file
    /// sitting directly in a watched root with no project markers above
    /// it — `watch_root` itself is treated as an implicit workspace
    /// root: the user explicitly opted into watching that folder, so its
    /// files belong to it rather than being silently dropped.
    pub async fn resolve_workspace_for_path(
        &self,
        file_path: &Path,
        watch_root: &Path,
    ) -> Result<Option<Workspace>, DatabaseError> {
        let Some(detected) = detector::detect_workspace_root(file_path, watch_root).or_else(|| {
            if file_path.starts_with(watch_root) {
                Some(detector::DetectedWorkspaceRoot {
                    path: watch_root.to_path_buf(),
                    markers: Vec::new(),
                    suggested_name: super::heuristics::suggest_name(watch_root),
                })
            } else {
                None
            }
        }) else {
            return Ok(None);
        };

        self.find_or_create_workspace(&detected).await.map(Some)
    }

    /// Finds the existing workspace for an already-detected root, or
    /// creates one. Either way, the returned workspace has just been
    /// "opened" (`last_active_at` bumped — see
    /// [`WorkspaceService::open_workspace`]): any file activity within a
    /// workspace's root is evidence the workspace is currently being
    /// worked on. Only the first detection of a brand-new root appends a
    /// timeline `workspace_switch` (its creation event); every later file
    /// touch records a file event, not a switch — switches are
    /// user-driven, so only [`WorkspaceService::switch_workspace`] records
    /// them.
    pub async fn find_or_create_workspace(
        &self,
        detected: &DetectedWorkspaceRoot,
    ) -> Result<Workspace, DatabaseError> {
        let root_path = detected.path.to_string_lossy().into_owned();

        if let Some(existing) = self.workspace_service.find_by_root_path(&root_path).await? {
            tracing::debug!(workspace_id = %existing.id, root_path, "matched existing workspace");
            return self.workspace_service.open_workspace(existing.id).await;
        }

        // Implicit watch-root workspaces (the detector found no markers,
        // so `detected.path` is the watched folder itself) may already
        // exist as manually-created, filesystem-less workspaces — e.g. the
        // user typed the folder's name into the dashboard before adding
        // the folder to Watched Folders. Adopt that workspace by binding
        // the root path instead of creating a duplicate-named one.
        if detected.markers.is_empty() {
            if let Some(manual) = self
                .workspace_service
                .find_unbound_by_name(&detected.suggested_name)
                .await?
            {
                tracing::info!(
                    workspace_id = %manual.id,
                    root_path,
                    "adopted manually-created workspace as the watch-root workspace"
                );
                self.workspace_service
                    .set_workspace_root_path(manual.id, &root_path)
                    .await?;
                return self.workspace_service.open_workspace(manual.id).await;
            }
        }

        tracing::info!(
            root_path,
            markers = ?detected.markers,
            suggested_name = detected.suggested_name,
            "detected new workspace root"
        );

        let workspace = self
            .workspace_service
            .create_workspace(CreateWorkspaceInput {
                name: detected.suggested_name.clone(),
                description: None,
                root_path: Some(root_path),
            })
            .await?;

        tracing::info!(workspace_id = %workspace.id, "workspace auto-created from detected root");

        self.workspace_service.open_workspace(workspace.id).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::test_database;
    use crate::models::CreateWorkspaceInput;
    use crate::repositories::{TimelineRepository, WorkspaceRepository};
    use std::fs;
    use tempfile::tempdir;

    async fn manager() -> (WorkspaceManager, tempfile::TempDir) {
        let (database, temp_dir) = test_database().await;
        let service = WorkspaceService::new(
            WorkspaceRepository::new(database.pool().clone()),
            TimelineRepository::new(database.pool().clone()),
        );
        (WorkspaceManager::new(service), temp_dir)
    }

    #[tokio::test]
    async fn creates_a_workspace_on_first_detection() {
        let (manager, _db_guard) = manager().await;
        let watch_root = tempdir().unwrap();
        fs::create_dir(watch_root.path().join(".git")).unwrap();
        let file_path = watch_root.path().join("src/main.rs");
        fs::create_dir_all(file_path.parent().unwrap()).unwrap();
        fs::write(&file_path, "").unwrap();

        let workspace = manager
            .resolve_workspace_for_path(&file_path, watch_root.path())
            .await
            .expect("resolve should succeed")
            .expect("a git repo root should be detected");

        let expected = std::fs::canonicalize(watch_root.path())
            .unwrap_or_else(|_| watch_root.path().to_path_buf())
            .to_string_lossy()
            .into_owned();
        assert_eq!(workspace.root_path, Some(expected));
    }

    #[tokio::test]
    async fn reuses_the_same_workspace_for_repeated_activity() {
        let (manager, _db_guard) = manager().await;
        let watch_root = tempdir().unwrap();
        fs::write(watch_root.path().join("package.json"), "{}").unwrap();
        let file_a = watch_root.path().join("src/a.js");
        let file_b = watch_root.path().join("src/b.js");
        fs::create_dir_all(file_a.parent().unwrap()).unwrap();
        fs::write(&file_a, "").unwrap();
        fs::write(&file_b, "").unwrap();

        let first = manager
            .resolve_workspace_for_path(&file_a, watch_root.path())
            .await
            .unwrap()
            .unwrap();
        let second = manager
            .resolve_workspace_for_path(&file_b, watch_root.path())
            .await
            .unwrap()
            .unwrap();

        assert_eq!(
            first.id, second.id,
            "two files under the same detected root must resolve to the same workspace"
        );
    }

    #[tokio::test]
    async fn falls_back_to_the_watch_root_when_no_project_markers_exist() {
        let (manager, _db_guard) = manager().await;
        let watch_root = tempdir().unwrap();
        let loose_file = watch_root.path().join("notes.txt");
        fs::write(&loose_file, "").unwrap();

        let workspace = manager
            .resolve_workspace_for_path(&loose_file, watch_root.path())
            .await
            .expect("resolve should succeed")
            .expect("the watch root is an implicit workspace root");

        let expected = std::fs::canonicalize(watch_root.path())
            .unwrap_or_else(|_| watch_root.path().to_path_buf())
            .to_string_lossy()
            .into_owned();
        assert_eq!(workspace.root_path, Some(expected));
    }

    #[tokio::test]
    async fn fallback_adopts_an_existing_unbound_workspace_with_the_same_name() {
        let (database, _db_guard) = test_database().await;
        let workspace_repository = WorkspaceRepository::new(database.pool().clone());
        let manager = WorkspaceManager::new(WorkspaceService::new(
            workspace_repository.clone(),
            TimelineRepository::new(database.pool().clone()),
        ));
        let watch_root = tempdir().unwrap();
        let folder_name = watch_root
            .path()
            .file_name()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        let manual = workspace_repository
            .create(CreateWorkspaceInput {
                name: folder_name.clone(),
                description: None,
                root_path: None,
            })
            .await
            .unwrap();
        let loose_file = watch_root.path().join("notes.txt");
        fs::write(&loose_file, "").unwrap();

        let workspace = manager
            .resolve_workspace_for_path(&loose_file, watch_root.path())
            .await
            .expect("resolve should succeed")
            .expect("the watch root is an implicit workspace root");

        assert_eq!(
            workspace.id, manual.id,
            "the existing filesystem-less workspace must be adopted, not duplicated"
        );
        let expected = std::fs::canonicalize(watch_root.path())
            .unwrap_or_else(|_| watch_root.path().to_path_buf())
            .to_string_lossy()
            .into_owned();
        assert_eq!(workspace.root_path, Some(expected));
    }
}
