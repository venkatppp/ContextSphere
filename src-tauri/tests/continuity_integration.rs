//! Integration tests for Context Reconstruction & Continuity Engine.

use chrono::Utc;
use std::fs;
use tempfile::tempdir;

use chronodesk_lib::context_memory::{ContextMemoryEngine, ContextMemoryRepository, SnapshotType};
use chronodesk_lib::database::Database;
use chronodesk_lib::intelligence::continuity::ContextContinuityEngine;
use chronodesk_lib::intelligence::health::{HealthService, WorkspaceHealthEngine};
use chronodesk_lib::intelligence::recommendation::RecommendationEngine;
use chronodesk_lib::intelligence::workspace::WorkspaceIntelligenceEngine;
use chronodesk_lib::models::CreateWorkspaceInput;
use chronodesk_lib::repositories::{
    ActivityRepository, FileRepository, SettingsRepository, TimelineRepository, WorkspaceRepository,
};
use chronodesk_lib::services::ContextService;
use chronodesk_lib::session::SessionEngine;
use chronodesk_lib::timeline::events::TimelineActivity;
use chronodesk_lib::timeline::recorder::TimelineRecorder;

struct TestHarness {
    pool: sqlx::SqlitePool,
    workspace_repo: WorkspaceRepository,
    timeline_repo: TimelineRepository,
    continuity_engine: ContextContinuityEngine,
    temp_dir: tempfile::TempDir,
}

async fn setup_harness() -> TestHarness {
    let temp_dir = tempdir().expect("create temp dir");
    let db_path = temp_dir.path().join("test_continuity.db");
    let database = Database::initialize_at(&db_path)
        .await
        .expect("initialize test db");
    let pool = database.pool().clone();

    let workspace_repo = WorkspaceRepository::new(pool.clone());
    let file_repo = FileRepository::new(pool.clone());
    let timeline_repo = TimelineRepository::new(pool.clone());
    let settings_repo = SettingsRepository::new(pool.clone());
    let activity_repo = ActivityRepository::new(pool.clone());

    let session_engine = SessionEngine::new(timeline_repo.clone(), file_repo.clone());
    let context_service = ContextService::new(
        session_engine.clone(),
        workspace_repo.clone(),
        settings_repo.clone(),
    );

    let health_service = HealthService::new(pool.clone());
    let health_engine = WorkspaceHealthEngine::new(
        health_service,
        workspace_repo.clone(),
        timeline_repo.clone(),
        file_repo.clone(),
        context_service.clone(),
    );
    let recommendation_engine = RecommendationEngine::new(
        workspace_repo.clone(),
        file_repo.clone(),
        context_service.clone(),
    );

    let intelligence_engine = WorkspaceIntelligenceEngine::new(
        workspace_repo.clone(),
        timeline_repo.clone(),
        activity_repo.clone(),
        context_service.clone(),
        health_engine,
    )
    .with_recommendation_engine(recommendation_engine);

    let memory_repo = ContextMemoryRepository::new(pool.clone());
    let memory_engine = ContextMemoryEngine::new(
        memory_repo,
        workspace_repo.clone(),
        context_service.clone(),
    );

    let continuity_engine = ContextContinuityEngine::new(
        intelligence_engine,
        memory_engine,
        context_service,
        workspace_repo.clone(),
        timeline_repo.clone(),
        activity_repo,
    );

    TestHarness {
        pool,
        workspace_repo,
        timeline_repo,
        continuity_engine,
        temp_dir,
    }
}

#[tokio::test]
async fn test_continuity_snapshot_and_reconstruction() {
    let harness = setup_harness().await;

    // 1. Create a workspace with a real directory and file on disk
    let ws_dir = harness.temp_dir.path().join("workspace_alpha");
    fs::create_dir_all(&ws_dir).unwrap();
    let src_file = ws_dir.join("main.rs");
    fs::write(&src_file, "fn main() { println!(\"alpha\"); }").unwrap();

    let ws = harness
        .workspace_repo
        .create(CreateWorkspaceInput {
            name: "Alpha Workspace".to_string(),
            description: Some("Continuity Alpha Test".to_string()),
            root_path: Some(ws_dir.to_string_lossy().to_string()),
        })
        .await
        .expect("create workspace");

    // 2. Record timeline event referencing the file
    let timeline_recorder = TimelineRecorder::new(
        FileRepository::new(harness.pool.clone()),
        harness.timeline_repo.clone(),
    );
    timeline_recorder
        .record(
            ws.id,
            TimelineActivity::FileModified {
                path: src_file.to_string_lossy().to_string(),
            },
            Utc::now(),
        )
        .await
        .expect("record timeline event");

    // 3. Snapshot work episode
    let snapshot = harness
        .continuity_engine
        .snapshot_work_episode(ws.id, SnapshotType::Manual)
        .await
        .expect("snapshot work episode");

    assert_eq!(snapshot.workspace_id, ws.id.to_string());
    assert_eq!(snapshot.snapshot_type, SnapshotType::Manual);

    // 4. Reconstruct context
    let ctx = harness
        .continuity_engine
        .reconstruct_workspace_context(ws.id)
        .await
        .expect("reconstruct context");

    assert_eq!(ctx.workspace_id, ws.id);
    assert_eq!(ctx.workspace_name, "Alpha Workspace");
    assert!(ctx.continuity_score > 0.0, "Score should be non-zero");
    assert!(ctx.is_resumable, "Should be resumable");
    assert!(!ctx.signals.is_empty(), "Should yield explainable signals");

    // Weights must sum to 1.0
    let weight_sum: f64 = ctx.signals.iter().map(|s| s.weight).sum();
    assert!((weight_sum - 1.0).abs() < 1e-6, "Weights must sum to 1.0");

    // Verify ground-truth file presence
    let found_file = ctx
        .relevant_files
        .iter()
        .find(|f| f.path == src_file.to_string_lossy());
    assert!(found_file.is_some(), "Source file should be in relevant files");
    let file_info = found_file.unwrap();
    assert!(file_info.exists_on_disk, "File must exist on disk");
    assert!(!file_info.is_inferred, "Edited file is a known fact, not inferred");
}

#[tokio::test]
async fn test_ground_truth_file_verification_handles_missing_file() {
    let harness = setup_harness().await;

    let ws_dir = harness.temp_dir.path().join("workspace_beta");
    fs::create_dir_all(&ws_dir).unwrap();
    let missing_file = ws_dir.join("deleted_after_session.ts");

    let ws = harness
        .workspace_repo
        .create(CreateWorkspaceInput {
            name: "Beta Workspace".to_string(),
            description: Some("Beta Test".to_string()),
            root_path: Some(ws_dir.to_string_lossy().to_string()),
        })
        .await
        .expect("create workspace");

    // Record event for file that does not exist on disk
    let timeline_recorder = TimelineRecorder::new(
        FileRepository::new(harness.pool.clone()),
        harness.timeline_repo.clone(),
    );
    timeline_recorder
        .record(
            ws.id,
            TimelineActivity::FileCreated {
                path: missing_file.to_string_lossy().to_string(),
            },
            Utc::now(),
        )
        .await
        .expect("record timeline event");

    // Reconstruct without crashing
    let ctx = harness
        .continuity_engine
        .reconstruct_workspace_context(ws.id)
        .await
        .expect("reconstruction should succeed even with missing files");

    let found_missing = ctx
        .relevant_files
        .iter()
        .find(|f| f.path == missing_file.to_string_lossy());
    assert!(found_missing.is_some());
    let missing_info = found_missing.unwrap();
    assert!(!missing_info.exists_on_disk, "Should accurately detect missing file on disk");
}

#[tokio::test]
async fn test_smart_resume_selection_across_competing_workspaces() {
    let harness = setup_harness().await;

    // Workspace 1: older activity
    let dir1 = harness.temp_dir.path().join("ws_one");
    fs::create_dir_all(&dir1).unwrap();
    let _ws1 = harness
        .workspace_repo
        .create(CreateWorkspaceInput {
            name: "First WS".to_string(),
            description: None,
            root_path: Some(dir1.to_string_lossy().to_string()),
        })
        .await
        .expect("create ws1");

    // Workspace 2: active work
    let dir2 = harness.temp_dir.path().join("ws_two");
    fs::create_dir_all(&dir2).unwrap();
    let file2 = dir2.join("service.go");
    fs::write(&file2, "package main").unwrap();
    let ws2 = harness
        .workspace_repo
        .create(CreateWorkspaceInput {
            name: "Second WS".to_string(),
            description: None,
            root_path: Some(dir2.to_string_lossy().to_string()),
        })
        .await
        .expect("create ws2");

    let timeline_recorder = TimelineRecorder::new(
        FileRepository::new(harness.pool.clone()),
        harness.timeline_repo.clone(),
    );
    timeline_recorder
        .record(
            ws2.id,
            TimelineActivity::FileModified {
                path: file2.to_string_lossy().to_string(),
            },
            Utc::now(),
        )
        .await
        .expect("record ws2 activity");

    // Select smart resume
    let best_context = harness
        .continuity_engine
        .get_smart_resume_context()
        .await
        .expect("get smart resume context");

    assert!(best_context.is_some(), "Smart resume should find a candidate");
    let chosen = best_context.unwrap();
    assert_eq!(chosen.workspace_id, ws2.id, "Most active workspace should be selected");
    assert!(!chosen.recommended_actions.is_empty(), "Should provide non-destructive actions");
    assert_eq!(chosen.recommended_actions[0].action_type, "switch_workspace");
}
