//! ContextSphere backend library.
//!
//! This crate is split by domain, mirroring the engines described in the
//! product blueprint (§4 Software Architecture).
//!
//! | Module      | Owns                                   | Ships in |
//! |-------------|-----------------------------------------|----------|
//! | `commands`  | Tauri IPC command handlers              | Phase 1  |
//! | `database`  | SQLite connection pool & migrations     | Phase 2 ✅ |
//! | `watcher`   | OS file-system event watcher            | Phase 3 ✅ |
//! | `workspace` | Workspace Engine (lifecycle, detection) | Phase 3 ✅ |
//! | `timeline`  | Timeline Engine (append-only event log) | Phase 3 ✅ |
//! | `search`    | Hybrid keyword + vector search engine   | Phase 4 ✅ |
//! | `graph`     | Knowledge Graph Engine                  | Phase 4 ✅ |
//! | `session`   | Session Intelligence & Context Scoring  | Phase 5  |
//! | `ml`        | ONNX Runtime inference layer            | Phase 5  |
//!
//! Plus three supporting layers cutting across the table above:
//! `errors` (shared error types), `models` (typed domain structs + DTOs),
//! `repositories` (all SQL, one module per aggregate), and `services`
//! (business logic composing repositories) — `commands` depends on
//! `services`/engines, engines depend on `services`, `services` depend on
//! `repositories`, `repositories` depend on `database` and `models`. A
//! strict one-way chain, enforced by convention. `app_events` is the one
//! deliberate exception: it's reached from both `commands` (thin,
//! Tauri-aware) and `watcher` (a background engine), since both are the
//! places a user-visible change actually happens and needs to reach the
//! frontend.
//!
//! ## Phase 3 event pipeline
//!
//! ```text
//! notify::Event
//!     │
//!     ▼
//! watcher::event_handler::normalize()   (drop ignored paths, collapse rename→remove+create)
//!     │
//!     ▼
//! watcher::debounce::Debouncer          (coalesce rapid same-path events)
//!     │
//!     ▼
//! workspace::WorkspaceManager           (find-or-create the workspace this path belongs to)
//!     │
//!     ▼
//! timeline::TimelineEngine              (record the activity, auto-creating the files row)
//!     │
//!     ▼
//! repositories::* → database::Database  (SQLite, WAL mode)
//!     │
//!     ▼
//! app_events::AppEventEmitter           (workspace:updated, file:changed, timeline:event_added)
//!     │
//!     ▼
//! frontend (@tauri-apps/api/event listen())
//! ```

pub mod actions;
pub mod ai;
pub mod analytics;
pub mod app_events;
pub mod commands;
pub mod core_server;
pub mod context_memory;
pub mod copilot;
pub mod database;
pub mod duplicates;
pub mod errors;
pub mod graph;
pub mod hashing;
pub mod intelligence;
pub mod learning;
pub mod llm;
pub mod maintenance;
pub mod ml;
pub mod models;
pub mod performance;
pub mod predictive;
pub mod repositories;
pub mod runtime;
pub mod search;
pub mod security;
pub mod semantic;
pub mod services;
pub mod session;
pub mod timeline;
pub mod watcher;
pub mod workspace;

use std::sync::Arc;

use tauri::Manager;

use actions::{ActionEngine, ActionRepository, ActionService};
use analytics::AnalyticsEngine;
use context_memory::{ContextMemoryEngine, ContextMemoryRepository};
use duplicates::DuplicateDetectionEngine;
use graph::GraphEngine;
use intelligence::health::{HealthService, WorkspaceHealthEngine};
use intelligence::recommendation::RecommendationEngine;
use maintenance::MaintenanceEngine;
use performance::recovery::RecoveryManager;
use performance::{
    BenchmarkEngine, Diagnostics, PerformanceEngine, PerformanceProfiler, StartupProfiler,
};
use predictive::{
    AdaptiveLearning, AutomationEngine, PredictiveEngine, PredictiveRepository, WorkflowEngine,
};
use repositories::{
    ContextIntelRepository, FileRepository, GraphRepository, KgLiveRepository, KgOptRepository,
    KgRepository, LLMRepository, MLRepository, MaintenanceRepository, PerformanceRepository,
    RecoveryRepository, SearchRepository, SecurityRepository, SettingsRepository,
    TimelineRepository, WorkspaceRepository,
};
use search::SearchEngine;
use security::SecurityEngine;
use services::{
    ContextIntelService, ContextService, GraphHealthService, GraphService, KgLiveService,
    KgOptService, KgService, MLService, SearchService, TimelineService, WorkspaceService,
};
use session::SessionEngine;
use timeline::recorder::TimelineRecorder;
use timeline::TimelineEngine;
use watcher::FileWatcher;
use workspace::WorkspaceManager;


/// Initializes every ContextSphere core subsystem (database, repositories,
/// services, engines, watcher, ML, graph, memory) into a Tauri app.
/// Shared by the GUI entry point [`run`] and by the headless
/// `contextsphere-core` daemon binary that serves the native macOS SwiftUI
/// frontend over JSON-RPC (stdin/stdout).
pub fn initialize_core(app: &mut tauri::App) -> Result<(), Box<dyn std::error::Error>> {
            let _ = tracing_subscriber::fmt()
                .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
                .try_init();

            tracing::info!(
                version = env!("CARGO_PKG_VERSION"),
                "ContextSphere backend starting"
            );

            // RC-10 M1: the startup profiler is created before anything
            // else so every initialization stage below can be measured.
            // Markers are infallible; the run is persisted at the end of
            // setup once the performance engine exists.
            let startup_profiler = StartupProfiler::new();

            // Database initialization is async (sqlx) but `setup` is sync,
            // and the app must not accept commands before the schema is
            // ready — so this blocks startup on it rather than spawning
            // it in the background. For a local SQLite file this is a
            // few milliseconds; not worth deferring command availability
            // for.
            let app_handle = app.handle().clone();
            startup_profiler.stage_start("database", "Database initialization & repositories");
            let database =
                tauri::async_runtime::block_on(database::Database::initialize(&app_handle))?;
            let pool = database.pool().clone();

            // --- Repositories (data access, one per aggregate) ---
            let workspace_repository = WorkspaceRepository::new(pool.clone());
            let file_repository = FileRepository::new(pool.clone());
            let timeline_repository = TimelineRepository::new(pool.clone());
            let settings_repository = SettingsRepository::new(pool.clone());
            let search_repository = SearchRepository::new(pool.clone());
            let graph_repository = GraphRepository::new(pool.clone());
            let ml_repository = MLRepository::new(pool.clone());
            let secret_store = Arc::new(llm::KeyringSecretStore::new());
            let llm_repository = Arc::new(LLMRepository::new(pool.clone(), secret_store.clone()));
            startup_profiler.stage_end();

            // --- Services (business logic composing repositories) ---
            startup_profiler.stage_start("services", "Service construction");
            let workspace_service =
                WorkspaceService::new(workspace_repository.clone(), timeline_repository.clone());
            let timeline_recorder =
                TimelineRecorder::new(file_repository.clone(), timeline_repository.clone());
            let timeline_service =
                TimelineService::new(timeline_recorder, timeline_repository.clone());
            let search_service = SearchService::new(search_repository.clone());
            let graph_service = GraphService::new(graph_repository.clone());
            let ml_service = MLService::new(ml_repository.clone(), file_repository.clone());
            startup_profiler.stage_end();

            // --- RC-8 M1: Knowledge Graph Foundation ---
            // The RC-8 knowledge graph (typed `graph_nodes` registry +
            // `graph_relationships`) is constructed automatically from
            // every source aggregate. The engine holds both the legacy
            // Phase 4 graph service and the new knowledge graph service.
            let kg_repository = KgRepository::new(pool.clone());
            let kg_service = KgService::new(kg_repository);

            // --- Engines (the public facades commands and the watcher pipeline hold) ---
            let workspace_manager = WorkspaceManager::new(workspace_service.clone());
            let timeline_engine = TimelineEngine::new(timeline_service.clone());
            let search_engine = SearchEngine::new(search_service.clone());
            let graph_engine = GraphEngine::new(graph_service.clone())
                .with_kg_service(kg_service.clone());

            // RC-8 M1: build the knowledge graph once at startup (and on
            // every later launch) so the Graph page is populated even
            // before the first manual sync. The pass is idempotent.
            startup_profiler.stage_start("graph_sync", "Initial knowledge graph sync");
            match tauri::async_runtime::block_on(graph_engine.sync_graph()) {
                Ok(summary) => tracing::info!(
                    nodes = summary.total_nodes,
                    edges = summary.total_edges,
                    created_nodes = summary.created_nodes,
                    created_edges = summary.created_edges,
                    "knowledge graph synced at startup"
                ),
                Err(error) => {
                    tracing::error!(error = %error, "initial knowledge graph sync failed")
                }
            }
            startup_profiler.stage_end();

            // --- Session Engine & Context Service (Phase 5A) ---
            startup_profiler.stage_start("session_context", "Session & context services");
            let session_engine =
                SessionEngine::new(timeline_repository.clone(), file_repository.clone());
            let context_service = ContextService::new(
                session_engine.clone(),
                workspace_repository.clone(),
                settings_repository.clone(),
            );

            // --- Analytics Engine & Service (Phase 5B) ---
            let analytics_repository =
                analytics::repository::AnalyticsRepository::new(pool.clone());
            let analytics_service = analytics::service::AnalyticsService::new(
                analytics_repository,
                context_service.clone(),
                workspace_repository.clone(),
                file_repository.clone(),
            );
            let analytics_engine = AnalyticsEngine::new(analytics_service);

            // --- Intelligence Layer (Phase 5C) ---
            let health_service = HealthService::new(pool.clone());
            let health_engine = WorkspaceHealthEngine::new(
                health_service,
                workspace_repository.clone(),
                timeline_repository.clone(),
                file_repository.clone(),
                context_service.clone(),
            );
            let recommendation_engine = RecommendationEngine::new(
                workspace_repository.clone(),
                file_repository.clone(),
                context_service.clone(),
            );

            // --- Action Engine & Service (Phase 5D) ---
            let action_repository = ActionRepository::new(pool.clone());
            let action_engine = ActionEngine::new(
                action_repository.clone(),
                workspace_repository.clone(),
                file_repository.clone(),
            );
            let action_service = ActionService::new(action_repository.clone(), action_engine);

            // --- Context Memory Engine (Phase 5E) ---
            let context_memory_repository = ContextMemoryRepository::new(pool.clone());
            let context_memory_engine = ContextMemoryEngine::new(
                context_memory_repository,
                workspace_repository.clone(),
                context_service.clone(),
            );

            // --- Duplicate Detection Engine (Phase 5 Stage 2) ---
            let duplicate_engine = DuplicateDetectionEngine::new(file_repository.clone())
                .with_event_emitter(
                    Arc::new(app_handle.clone()) as Arc<dyn app_events::AppEventEmitter>
                );
            startup_profiler.stage_end();

            // --- Predictive Intelligence & Workflow Automation (Phase 5F) ---
            startup_profiler.stage_start("predictive", "Predictive intelligence engines");
            let predictive_repository = PredictiveRepository::new(pool.clone());

            let predictive_engine = PredictiveEngine::new(
                workspace_repository.clone(),
                timeline_repository.clone(),
                context_service.clone(),
                analytics_engine.clone(),
                context_memory_engine.clone(),
            );

            let workflow_engine = WorkflowEngine::new(
                timeline_repository.clone(),
                file_repository.clone(),
                context_service.clone(),
            );

            let adaptive_learning = AdaptiveLearning::new(
                predictive_repository.clone(),
                workspace_repository.clone(),
                timeline_repository.clone(),
                context_service.clone(),
            );

            let automation_engine = AutomationEngine::new(
                predictive_repository.clone(),
                workspace_repository.clone(),
                file_repository.clone(),
                context_memory_engine.clone(),
                recommendation_engine.clone(),
            );

            // --- Real-Time Intelligence Runtime (Phase 5G) ---
            let emitter = runtime::IntelligenceEmitter::new(
                Arc::new(app_handle.clone()) as Arc<dyn app_events::AppEventEmitter>
            );
            let cache = runtime::IntelligenceCache::new();

            // --- Runtime Health & Diagnostics (Phase 5H) ---
            let health_service = runtime::RuntimeHealthService::new(cache.clone());
            let diagnostics_service = runtime::DiagnosticsService::new(health_service.clone());
            let recovery_service = runtime::RecoveryService::new(pool.clone());

            // Initialize recovery system
            tauri::async_runtime::block_on(recovery_service.initialize())?;

            // Check if recovery is needed
            if tauri::async_runtime::block_on(recovery_service.needs_recovery())? {
                tracing::warn!("Detected interrupted shutdown, performing recovery");
                let recovered_jobs = tauri::async_runtime::block_on(recovery_service.recover())?;
                tracing::info!("Recovered {} interrupted jobs", recovered_jobs.len());
            }

            // Record clean startup
            tauri::async_runtime::block_on(recovery_service.checkpoint(
                runtime::RecoveryState::Clean,
                vec![],
                serde_json::Value::Null,
            ))?;

            let runtime_workers = Arc::new(runtime::RuntimeWorkers::new(
                emitter.clone(),
                cache.clone(),
                predictive_engine.clone(),
                workflow_engine.clone(),
                health_engine.clone(),
                recommendation_engine.clone(),
                context_memory_engine.clone(),
            ));

            // Start background workers
            runtime_workers.clone().start();
            startup_profiler.stage_end();

            // --- AI & Model Management (Phase 6B) ---
            startup_profiler.stage_start("ai_models", "AI & model management");
            let models_dir = app_handle
                .path()
                .app_data_dir()
                .expect("Failed to get app data dir")
                .join("models");

            let ai_settings = ai::AISettings::with_models_dir(models_dir);
            let model_manager = ai::ModelManager::new(ai_settings);

            // Shared local embedding provider — the single local semantic
            // representation for memory, search, graph and the Context Field.
            // Starts as deterministic n-gram fallback; swapped to ONNX when
            // all-MiniLM is loaded. No second vector DB, no external service.
            let shared_provider = std::sync::Arc::new(crate::ai::SharedProvider::new(
                std::sync::Arc::new(copilot::memory::vector::LocalVectorProvider::default()),
            ));

            let ai_state = commands::ai::AIState {
                manager: model_manager,
                reranker: parking_lot::RwLock::new(None),
                embedding_provider: parking_lot::RwLock::new(None),
                shared_provider: shared_provider.clone(),
            };

            // --- Semantic Intelligence Layer (Phase 6A) ---
            let semantic_repository = semantic::SemanticRepository::new(pool.clone());
            tauri::async_runtime::block_on(semantic_repository.initialize())?;
            startup_profiler.stage_end();

            // RC-6 M2: warm the in-memory k-NN index from the durable

            let semantic_engine = semantic::SemanticMemoryEngine::new(
                semantic_repository.clone(),
                shared_provider.clone() as Arc<dyn semantic::EmbeddingProvider>,
            );
            let semantic_search = semantic::SemanticSearchEngine::new(
                semantic_engine.clone(),
                semantic_repository.clone(),
            );
            let reasoning_engine = semantic::ContextReasoningEngine::new(
                semantic_engine.clone(),
                semantic_search.clone(),
                predictive_engine.clone(),
                recommendation_engine.clone(),
                context_memory_engine.clone(),
            );

            // --- Adaptive Learning Engine (Phase 6C) ---
            let learning_repository = learning::LearningRepository::new(pool.clone());
            let learning_engine = Arc::new(learning::AdaptiveLearningEngine::new(Arc::new(
                learning_repository.clone(),
            )));

            // Start learning workers
            let learning_worker = learning::LearningWorker::new(learning_engine.clone(), 3600);
            let preference_worker =
                learning::PreferenceLearningWorker::new(learning_engine.clone(), 1800);
            let calibration_worker =
                learning::ConfidenceCalibrationWorker::new(learning_engine.clone(), 7200);

            tauri::async_runtime::spawn(learning_worker.start());
            tauri::async_runtime::spawn(preference_worker.start());
            tauri::async_runtime::spawn(calibration_worker.start());
            startup_profiler.stage_end();

            // --- Copilot Engine (Phase 7A) ---
            startup_profiler.stage_start("copilot", "Copilot engine");
            let copilot_repository = copilot::CopilotRepository::new(pool.clone());

            // Initialize LLM service
            let llm_service = Arc::new(llm::LLMService::new(llm_repository.clone()));
            tauri::async_runtime::block_on(llm_service.initialize())?;

            // Persistent tool permission policies (stored in the settings
            // table) gate tool execution and plan pipelines.
            let tool_permission_service = Arc::new(tauri::async_runtime::block_on(
                copilot::ToolPermissionService::new(settings_repository.clone()),
            )?);

            let tool_executor = Arc::new(
                copilot::ToolExecutor::new(
                    Arc::new(workspace_service.clone()),
                    Arc::new(session_engine.clone()),
                    Arc::new(timeline_engine.clone()),
                )
                .with_permission_service(tool_permission_service.clone())
                .with_event_emitter(
                    Arc::new(app_handle.clone()) as Arc<dyn app_events::AppEventEmitter>
                ),
            );
            let conversation_manager = Arc::new(copilot::ConversationManager::new(
                Arc::new(copilot_repository.clone()),
                Arc::new(context_memory_engine.clone()),
                Arc::new(session_engine.clone()),
                Arc::new(timeline_engine.clone()),
            ));
            let streaming_manager = Arc::new(copilot::StreamingSessionManager::new(Arc::new(
                app_handle.clone(),
            )));
            let copilot_engine = Arc::new(copilot::CopilotEngine::new(
                conversation_manager,
                tool_executor.clone(),
                Arc::new(copilot_repository),
                llm_service.clone(),
                streaming_manager,
                Arc::new(reasoning_engine.clone()),
                Arc::new(predictive_engine.clone()),
                learning_engine.clone(),
                Arc::new(recommendation_engine.clone()),
                Arc::new(context_memory_engine.clone()),
                Arc::new(session_engine.clone()),
                Arc::new(timeline_engine.clone()),
            ));
            startup_profiler.stage_end();

            // --- Proactive AI Engine (Phase 7B) ---
            // PRODUCT TRUST: real detectors (long focus, repeated edits, idle, etc.)
            // are event-driven via FileWatcher + workspace switch. No fake intelligence.
            let mut proactive_engine = copilot::ProactiveEngine::new(
                Arc::new(timeline_engine.clone()),
                Arc::new(session_engine.clone()),
                Arc::new(predictive_engine.clone()),
                learning_engine.clone(),
                Arc::new(recommendation_engine.clone()),
                Arc::new(context_memory_engine.clone()),
                Arc::new(reasoning_engine.clone()),
            );
            // Forward queued notifications to the frontend as
            // `proactive:notification` (native macOS notifications).
            proactive_engine.set_event_emitter(
                Arc::new(app_handle.clone()) as Arc<dyn app_events::AppEventEmitter>
            );
            let proactive_engine = Arc::new(proactive_engine);

            // --- Execution Memory & Learning (RC-6 M1 + M2) ---
            // The memory system uses its own vector provider (the local
            // n-gram embedder by default; any `VectorProvider` — e.g. an
            // ONNX adapter — can be swapped in). The semantic layer keeps
            // its own `embedding_provider` above.
            startup_profiler.stage_start("memory", "Execution memory engine");
            let memory_engine = Arc::new(copilot::MemoryEngine::new(
                copilot::MemoryRepository::new(pool.clone()),
                shared_provider.clone() as Arc<dyn copilot::memory::vector::provider::VectorProvider>,
            ));

            // RC-6 M2: warm the in-memory k-NN index from the durable
            // vector index, then start the background indexing worker
            // (incremental + batched embedding, auto re-index on change).
            let memory_indexer = memory_engine.vector_system().indexer().clone();
            tauri::async_runtime::block_on(memory_indexer.warm_up())?;
            tauri::async_runtime::spawn({
                let memory_indexer = memory_indexer.clone();
                async move { memory_indexer.run().await }
            });

            // RC-6 M4: background memory lifecycle worker — periodic
            // cleanup passes (expire/delete/dedupe/compress) and
            // automatic snapshots.
            let memory_cleanup =
                copilot::memory::MemoryCleanupWorker::new((*memory_engine).clone());
            tauri::async_runtime::spawn({
                let memory_cleanup = memory_cleanup.clone();
                async move { memory_cleanup.run().await }
            });
            startup_profiler.stage_end();

            // --- RC-8 M2: Live Knowledge Graph (incremental sync, semantic
            // edges, analytics, multi-hop context, recommendations) ---
            // The M1 engine gains the M2 surfaces; node embeddings for
            // semantic `related_to` edges come from the memory vector
            // system's embedder. The engine handle is reassigned so the
            // managed state below carries the live service.
            startup_profiler.stage_start("kg_live", "Live knowledge graph services");
            let kg_live_service = KgLiveService::new(
                kg_service.clone(),
                KgLiveRepository::new(pool.clone()),
            )
            .with_embedder(Arc::new(memory_engine.vector_system().clone()));
            let graph_engine = graph_engine.with_kg_live_service(kg_live_service.clone());

            // --- RC-8 M3: Context Intelligence (context inference,
            // workspace similarity, goal clusters, summaries, snapshots,
            // fusion, planner retrieval, explanations) ---
            // Composes the M1 graph + M2 live graph with persisted
            // cross-workspace relations, snapshots and clusters, sharing
            // the M2 query cache and the memory system's embedder.
            let context_intel_service = ContextIntelService::new(
                kg_service.clone(),
                kg_live_service.clone(),
                workspace_repository.clone(),
                ContextIntelRepository::new(pool.clone()),
            )
            .with_embedder(Arc::new(memory_engine.vector_system().clone()));
            let graph_engine =
                graph_engine.with_context_intel_service(context_intel_service);

            // --- RC-8 M4: Knowledge Graph Optimization & Scale ---
            // Paginated/ranked/vector surfaces + parallel traversal and
            // the health ledger (integrity, repair, consistency,
            // maintenance, benchmarks, metrics, diagnostics) share the
            // memory system's embedder for vector-assisted search.
            let kg_opt_service = KgOptService::new(
                kg_service.clone(),
                KgOptRepository::new(pool.clone()),
                KgLiveRepository::new(pool.clone()),
            )
            .with_embedder(Arc::new(memory_engine.vector_system().clone()));
            let graph_health_service = GraphHealthService::new(
                kg_opt_service.clone(),
                KgLiveRepository::new(pool.clone()),
                KgOptRepository::new(pool.clone()),
            );
            let graph_engine = graph_engine
                .with_kg_opt_service(kg_opt_service.clone())
                .with_graph_health_service(graph_health_service.clone());

            // Advance the incremental-sync watermark to now. The M1 full
            // build above just wrote every node, so this first pass is
            // a cheap idempotent re-sync that leaves future event-driven
            // passes down to the changes only.
            match tauri::async_runtime::block_on(graph_engine.incremental_sync()) {
                Ok(summary) => tracing::info!(
                    total_nodes = summary.total_nodes,
                    total_edges = summary.total_edges,
                    "live knowledge graph watermark established at startup"
                ),
                Err(error) => {
                    tracing::error!(error = %error, "initial incremental graph sync failed")
                }
            }

            // RC-8 M2: background graph maintenance — every 5 minutes an
            // incremental sync pass (event-driven updates stay live), every
            // 6 hours a confidence-decay pass. Each sync emits
            // `graph:updated` so the Graph page refreshes without polling.
            {
                let graph_engine = graph_engine.clone();
                let emitter = Arc::new(app_handle.clone()) as Arc<dyn app_events::AppEventEmitter>;
                tauri::async_runtime::spawn(async move {
                    let mut sync_interval =
                        tokio::time::interval(std::time::Duration::from_secs(300));
                    let mut decay_interval =
                        tokio::time::interval(std::time::Duration::from_secs(6 * 60 * 60));
                    loop {
                        tokio::select! {
                            _ = sync_interval.tick() => {
                                match graph_engine.incremental_sync().await {
                                    Ok(summary) => {
                                        app_events::emit(&*emitter, app_events::EVENT_GRAPH_UPDATED, &summary);
                                    }
                                    Err(error) => tracing::warn!(error = %error, "background graph sync failed"),
                                }
                            }
                            _ = decay_interval.tick() => {
                                match graph_engine.apply_edge_decay().await {
                                    Ok(summary) => tracing::info!(
                                        decayed = summary.decayed,
                                        pruned = summary.pruned,
                                        "semantic edge decay pass completed"
                                    ),
                                    Err(error) => tracing::warn!(error = %error, "background edge decay failed"),
                                }
                            }
                        }
                    }
                });
            }

            // RC-8 M4: background graph maintenance — every hour expired
            // cache entries are swept; every 6 hours an integrity check
            // pass records findings (never auto-repairs — that stays a
            // user-triggered action from the performance page).
            {
                let graph_health_service = graph_health_service.clone();
                tauri::async_runtime::spawn(async move {
                    let mut sweep_interval =
                        tokio::time::interval(std::time::Duration::from_secs(60 * 60));
                    let mut check_interval =
                        tokio::time::interval(std::time::Duration::from_secs(6 * 60 * 60));
                    loop {
                        tokio::select! {
                            _ = sweep_interval.tick() => {
                                match graph_health_service.sweep_expired_cache().await {
                                    Ok(removed) => tracing::debug!(removed, "expired graph cache entries swept"),
                                    Err(error) => tracing::warn!(error = %error, "cache sweep failed"),
                                }
                            }
                            _ = check_interval.tick() => {
                                match graph_health_service.integrity_check().await {
                                    Ok(result) => tracing::info!(
                                        issues = result.issues.len(),
                                        "scheduled graph integrity check completed"
                                    ),
                                    Err(error) => tracing::warn!(error = %error, "scheduled integrity check failed"),
                                }
                            }
                        }
                    }
                });
            }
            startup_profiler.stage_end();

            // --- Execution Engine (RC-2) ---
            startup_profiler.stage_start("execution", "Execution, planner & runtime");
            let execution_repository = Arc::new(copilot::ExecutionRepository::new(pool.clone()));
            let execution_engine = Arc::new(
                copilot::ExecutionEngine::new(execution_repository, tool_executor.clone())
                    .with_event_emitter(
                        Arc::new(app_handle.clone()) as Arc<dyn app_events::AppEventEmitter>
                    )
                    .with_memory(memory_engine.clone()),
            );

            // --- Autonomous Planning Engine (RC-5) ---
            let planner = Arc::new(
                copilot::Planner::new(tool_executor.clone(), Some(tool_permission_service.clone()))
                    .with_execution_engine(execution_engine.clone())
                    .with_memory(memory_engine.clone()),
            );

            // --- Autonomous Agent Runtime (RC-5 M6) ---
            let autonomous_runtime = Arc::new(
                copilot::autonomous::AutonomousRuntime::new(
                    planner.clone(),
                    execution_engine.clone(),
                    tool_executor.clone(),
                )
                .with_event_emitter(
                    Arc::new(app_handle.clone()) as Arc<dyn app_events::AppEventEmitter>
                )
                .with_memory(memory_engine.clone()),
            );
            startup_profiler.stage_end();

            // Wire deterministic planner into proactive engine so
            // `copilot_generate_plan` delegates to real Planner::plan()
            // instead of the former hardcoded template.
            tauri::async_runtime::block_on(proactive_engine.set_planner(planner.clone()));

            // --- File Watcher, wired to a real AppEventEmitter (the AppHandle) ---
            startup_profiler.stage_start("watcher", "File watcher & path restore");
            let file_watcher = FileWatcher::new(workspace_manager, timeline_engine.clone())
                .with_event_emitter(
                    Arc::new(app_handle.clone()) as Arc<dyn app_events::AppEventEmitter>
                )
                .with_proactive_engine(proactive_engine.clone());

            // Restore watch paths persisted from a previous launch before
            // the window is shown, so watching resumes exactly where the
            // user left off with no manual re-add step.
            tauri::async_runtime::block_on(commands::watcher::restore_watched_paths(
                &file_watcher,
                &settings_repository,
            ))?;

            // Minimal periodic proactive check for time-based detectors (idle, long focus).
            // File edits already trigger check_proactive_opportunities via FileWatcher (throttled 5m).
            // This loop covers the idle case where no file events occur.
            {
                let proactive = proactive_engine.clone();
                let ws_service = workspace_service.clone();
                tauri::async_runtime::spawn(async move {
                    let mut interval = tokio::time::interval(std::time::Duration::from_secs(900));
                    loop {
                        interval.tick().await;
                        match ws_service.get_active_workspace().await {
                            Ok(Some(active)) => {
                                if let Err(e) =
                                    proactive.check_proactive_opportunities(active.id).await
                                {
                                    tracing::warn!(error = %e, "periodic proactive check failed");
                                }
                            }
                            Ok(None) => {}
                            Err(e) => tracing::warn!(error = %e, "periodic proactive active workspace lookup failed"),
                        }
                    }
                });
            }

            startup_profiler.stage_end();

            // --- RC-10 M1: Performance & Profiling Engine ---
            // Composed here — before the handles below are moved into
            // `app.manage` — so the benchmark engine and diagnostics can
            // borrow every subsystem. The measured startup run is
            // persisted once setup completes.
            let performance_repository = PerformanceRepository::new(pool.clone());
            let performance_profiler = PerformanceProfiler::new(performance_repository.clone());
            let benchmark_engine = BenchmarkEngine::new(
                performance_repository.clone(),
                Some(planner.clone()),
                Some(execution_engine.clone()),
                Some(memory_engine.clone()),
                Some(graph_engine.clone()),
                Some(semantic_search.clone()),
            );
            let app_data_dir = app_handle.path().app_data_dir();
            let db_path = app_data_dir
                .as_ref()
                .map(|dir| dir.join("chronodesk.db").display().to_string())
                .unwrap_or_else(|_| "unknown".to_string());
            let performance_diagnostics = Diagnostics::new(performance_repository.clone())
                .with_graph_engine(graph_engine.clone())
                .with_runtime_health(health_service.clone())
                .with_intelligence_cache(cache.clone())
                .with_db_path(db_path);
            let performance_engine = PerformanceEngine::new(
                performance_repository,
                startup_profiler.clone(),
                performance_profiler,
                benchmark_engine,
                performance_diagnostics,
            )
            .with_graph_engine(graph_engine.clone());

            // --- RC-10 M2: Reliability & Recovery ---
            // Runs before the window is shown so a crashed previous
            // session is detected, validated and (where possible)
            // resumed/rolled back before the user sees the UI. The
            // watchdog loop keeps monitoring after launch; a clean
            // shutdown is recorded via the `RunEvent::Exit` hook below.
            startup_profiler.stage_start("recovery", "Recovery & crash detection");
            let recovery_manager = RecoveryManager::new(RecoveryRepository::new(pool.clone()));
            match tauri::async_runtime::block_on(recovery_manager.startup()) {
                Ok(run) => tracing::info!(
                    run_id = %run.run_id,
                    outcome = run.outcome.as_str(),
                    actions = run.actions.len(),
                    "startup recovery pass completed"
                ),
                Err(error) => {
                    tracing::error!(error = %error, "startup recovery pass failed")
                }
            }
            tauri::async_runtime::spawn({
                let recovery_manager = recovery_manager.clone();
                async move { recovery_manager.watchdog_loop().await }
            });
            startup_profiler.stage_end();

            // --- RC-10 M3: Data Integrity & Backup ---
            // Snapshots go to `<app-data>/backups`; the pending-restore
            // marker sits next to the database and is swapped in by
            // `Database::initialize_at` on the next launch. The repository
            // is shared (via `Arc`) with the M4 security engine, which
            // verifies backup presence/checksums against the same ledger.
            let maintenance_repository = Arc::new(MaintenanceRepository::new(pool.clone()));
            let db_path = app_data_dir
                .as_ref()
                .map(|dir| dir.join("chronodesk.db"))
                .unwrap_or_default();
            let backup_dir = app_data_dir
                .as_ref()
                .map(|dir| dir.join("backups"))
                .unwrap_or_default();
            let maintenance_engine = MaintenanceEngine::new(
                (*maintenance_repository).clone(),
                db_path.clone(),
                backup_dir.clone(),
            );

            // --- RC-10 M4: Security Hardening ---
            // Composes the security ledgers (audit, config, findings,
            // recommendations) with the shared M3 maintenance ledger and
            // the keyring-backed secret store. Startup validation is
            // non-fatal — a failing check must never block the app; the
            // background monitor loop re-runs the full battery on the
            // policy interval and emits `security:status`.
            let security_engine = SecurityEngine::new(
                SecurityRepository::new(pool.clone()),
                maintenance_repository,
                llm_repository.clone(),
                secret_store,
                db_path,
                backup_dir,
            )
            .with_event_emitter(
                Arc::new(app_handle.clone()) as Arc<dyn app_events::AppEventEmitter>
            );

            match tauri::async_runtime::block_on(security_engine.startup_validation()) {
                Ok(report) => tracing::info!(
                    ok = report.ok,
                    score = report.score,
                    checks = report.total_checks,
                    "startup security validation completed"
                ),
                Err(error) => {
                    tracing::warn!(error = %error, "startup security validation failed")
                }
            }
            tauri::async_runtime::spawn({
                let security_engine = security_engine.clone();
                async move { security_engine.run_monitor_loop().await }
            });

            // Every service/engine/repository above is managed as Tauri
            // state so command handlers can pull the one they need via
            // `tauri::State<'_, T>`. `Database` itself is managed too,
            // for any future code that needs the raw pool directly.
            app.manage(database);
            app.manage(workspace_repository);
            app.manage(file_repository);
            app.manage(timeline_repository);
            app.manage(settings_repository);
            app.manage(search_repository);
            app.manage(graph_repository);
            app.manage(ml_repository);
            app.manage(workspace_service);
            app.manage(timeline_service);
            app.manage(search_service);
            app.manage(graph_service);
            app.manage(ml_service);
            app.manage(context_service);
            app.manage(analytics_engine);
            app.manage(health_engine);
            app.manage(recommendation_engine);
            app.manage(action_service);
            app.manage(context_memory_engine.clone());
            app.manage(predictive_engine);
            app.manage(workflow_engine);
            app.manage(adaptive_learning);
            app.manage(automation_engine);
            app.manage(timeline_engine);
            app.manage(search_engine);
            app.manage(graph_engine);
            app.manage(duplicate_engine);
            app.manage(file_watcher);
            app.manage(emitter);
            app.manage(cache);
            app.manage(runtime_workers);
            app.manage(health_service);
            app.manage(diagnostics_service);
            app.manage(recovery_service);
            app.manage(semantic_engine);
            app.manage(semantic_search);
            app.manage(reasoning_engine);
            app.manage(learning_repository);
            app.manage(learning_engine);
            app.manage(ai_state);
            // Auto-load real ONNX model if already downloaded (no UI block, no auto-download)
            {
                let app_clone = app_handle.clone();
                tauri::async_runtime::spawn(async move {
                    tokio::time::sleep(std::time::Duration::from_millis(800)).await;
                    let ai_state = app_clone.state::<commands::ai::AIState>();
                    let model_id = "all-minilm-l6-v2";
                    if let Some(model) = ai_state.manager.get_model(model_id) {
                        if model.status == crate::ai::models::ModelStatus::Downloaded {
                            if let Some(path) = ai_state.manager.get_model_path(model_id) {
                                let model_file = path.join("model.onnx");
                                let tokenizer_file = path.join("tokenizer.json");
                                if model_file.exists() && tokenizer_file.exists() {
                                    match crate::ai::ONNXEmbeddingProvider::new(
                                        model_id.to_string(),
                                        model_file,
                                        tokenizer_file,
                                        model.metadata.dimensions,
                                        model.metadata.max_sequence_length,
                                        true,
                                        10000,
                                    ) {
                                        Ok(provider) => {
                                            let provider = std::sync::Arc::new(provider);
                                            {
                                                let mut guard = ai_state.embedding_provider.write();
                                                *guard = Some(provider.clone());
                                            }
                                            ai_state.shared_provider.set_provider(
                                                provider as std::sync::Arc<dyn copilot::memory::vector::provider::VectorProvider>
                                            );
                                            let _ = ai_state.manager.mark_loaded(model_id, model.metadata.file_size_bytes);
                                            let _ = ai_state.manager.set_active_embedding_model(model_id.to_string());
                                            tracing::info!(model_id, "auto-loaded ONNX embedding model on startup");
                                        }
                                        Err(e) => tracing::warn!(model_id, error = %e, "auto-load ONNX failed"),
                                    }
                                }
                            }
                        }
                    }
                });
            }
            app.manage(llm_repository);
            app.manage(llm_service);
            app.manage(tool_executor);
            app.manage(tool_permission_service);
            app.manage(copilot_engine);
            app.manage(proactive_engine);
            app.manage(execution_engine);
            app.manage(planner);
            app.manage(autonomous_runtime);
            app.manage(memory_engine);
            app.manage(kg_opt_service);
            app.manage(graph_health_service);
            app.manage(performance_engine.clone());
            app.manage(recovery_manager.clone());
            app.manage(maintenance_engine.clone());
            app.manage(security_engine.clone());

            // Persist the measured startup run once every subsystem is up.
            match tauri::async_runtime::block_on(performance_engine.record_startup()) {
                Ok(profile) => tracing::info!(
                    total_ms = profile.total_ms,
                    stages = profile.stages.len(),
                    "startup profile recorded"
                ),
                Err(error) => tracing::warn!(error = %error, "startup profile could not be recorded"),
            }

            tracing::info!("ContextSphere backend ready");

            Ok(())
}


/// Builds and runs the Tauri application. Called from `main.rs`; kept in
/// the library crate (rather than inline in `main`) so it can also be
/// exercised from integration tests and, eventually, mobile targets.
#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_log::Builder::new().level(log_level()).build())
        .setup(|app| initialize_core(app))




        .invoke_handler(tauri::generate_handler![
            commands::system::get_app_version,
            commands::system::health_check,
            commands::system::open_file,
            commands::workspace::list_active_workspaces,
            commands::workspace::list_archived_workspaces,
            commands::workspace::get_workspace,
            commands::workspace::get_workspace_statistics,
            commands::workspace::create_workspace,
            commands::workspace::update_workspace,
            commands::workspace::delete_workspace,
            commands::workspace::switch_workspace,
            commands::timeline::list_workspace_timeline,
            commands::timeline::get_recent_activity,
            commands::watcher::add_watch_path,
            commands::watcher::remove_watch_path,
            commands::watcher::list_watch_paths,
            commands::search::search,
            commands::search::get_search_history,
            commands::search::save_search_query,
            commands::search::clear_search_history,
            commands::search::save_search,
            commands::search::list_saved_searches,
            commands::search::delete_saved_search,
            commands::search::get_recent_files,
            commands::search::get_workspace_stats,
            commands::graph::get_graph,
            commands::graph::get_node_details,
            commands::graph::get_graph_stats,
            commands::graph::graph_sync,
            commands::graph::graph_search,
            commands::graph::graph_subgraph,
            commands::graph::graph_path,
            commands::graph::graph_context,
            commands::graph::graph_kg_stats,
            commands::graph::graph_nodes,
            commands::graph::graph_incremental_sync,
            commands::graph::graph_sync_entity,
            commands::graph::graph_rebuild_semantic_edges,
            commands::graph::graph_apply_edge_decay,
            commands::graph::graph_analytics,
            commands::graph::graph_expand_context,
            commands::graph::graph_recommendations,
            commands::graph::graph_relationship_details,
            commands::graph::graph_cache_stats,
            commands::graph::graph_infer_context,
            commands::graph::graph_workspace_similarity,
            commands::graph::graph_discover_cross_workspace_relationships,
            commands::graph::graph_goal_clusters,
            commands::graph::graph_knowledge_summary,
            commands::graph::graph_snapshot_create,
            commands::graph::graph_snapshot_list,
            commands::graph::graph_context_timeline,
            commands::graph::graph_fused_context,
            commands::graph::graph_planner_context,
            commands::graph::graph_explain,
            commands::graph_opt::graph_nodes_page,
            commands::graph_opt::graph_edges_page,
            commands::graph_opt::graph_neighbors_page,
            commands::graph_opt::graph_nodes_total,
            commands::graph_opt::graph_ranked_search,
            commands::graph_opt::graph_vector_search,
            commands::graph_opt::graph_parallel_traverse,
            commands::graph_opt::graph_cache_trim,
            commands::graph_opt::graph_clear_expired_cache,
            commands::graph_opt::graph_memory_stats,
            commands::graph_opt::graph_recent_metrics,
            commands::graph_opt::graph_integrity_check,
            commands::graph_opt::graph_repair,
            commands::graph_opt::graph_orphan_summary,
            commands::graph_opt::graph_orphan_cleanup,
            commands::graph_opt::graph_consistency_report,
            commands::graph_opt::graph_maintenance_runs,
            commands::graph_opt::graph_benchmark_suite,
            commands::graph_opt::graph_diagnostics,
            commands::duplicates::scan_workspace_for_duplicates,
            commands::duplicates::scan_file,
            commands::duplicates::get_duplicate_groups,
            commands::duplicates::find_duplicates,
            commands::duplicates::get_scan_progress,
            commands::duplicates::cancel_scan,
            commands::session::get_smart_resume_session,
            commands::session::get_workspace_sessions,
            commands::session::get_latest_workspace_session,
            commands::session::set_session_inactivity_threshold,
            commands::session::get_session_inactivity_threshold,
            commands::analytics::get_daily_briefing,
            commands::analytics::get_today_summary,
            commands::analytics::get_yesterday_summary,
            commands::analytics::get_this_week_summary,
            commands::analytics::get_last_week_summary,
            commands::analytics::get_this_month_summary,
            commands::analytics::get_workspace_insight,
            commands::intelligence::get_workspace_health,
            commands::intelligence::get_latest_workspace_health,
            commands::intelligence::get_workspace_health_history,
            commands::intelligence::get_workspace_recommendations,
            commands::intelligence::get_category_recommendations,
            commands::intelligence::get_priority_recommendations,
            commands::actions::execute_action,
            commands::actions::undo_action,
            commands::actions::get_action_history,
            commands::actions::get_all_action_history,
            commands::actions::clear_action_history,
            commands::actions::clear_workspace_action_history,
            commands::context_memory::create_context_snapshot,
            commands::context_memory::get_workspace_snapshots,
            commands::context_memory::get_latest_snapshot,
            commands::context_memory::detect_workspace_relationships,
            commands::context_memory::get_related_workspaces,
            commands::context_memory::search_knowledge,
            commands::context_memory::snapshot_milestone,
            commands::predictive::get_predictions_summary,
            commands::predictive::get_current_workflow,
            commands::predictive::get_learning_profile,
            commands::predictive::update_learning_profile,
            commands::predictive::create_automation_rule,
            commands::predictive::list_automation_rules,
            commands::predictive::update_automation_rule_enabled,
            commands::predictive::delete_automation_rule,
            commands::runtime::get_runtime_health,
            commands::runtime::get_runtime_diagnostics,
            commands::runtime::get_runtime_summary,
            commands::semantic::semantic_search,
            commands::semantic::find_similar_documents,
            commands::semantic::infer_related_work,
            commands::semantic::detect_recurring_workflows,
            commands::semantic::find_similar_sessions,
            commands::semantic::explain_recommendation,
            commands::semantic::infer_missing_context,
            commands::ai::list_models,
            commands::ai::get_model,
            commands::ai::download_model,
            commands::ai::load_model,
            commands::ai::unload_model,
            commands::ai::get_active_embedding_model,
            commands::ai::get_active_reranker_model,
            commands::ai::get_model_status,
            commands::ai::get_inference_statistics,
            commands::ai::get_ai_diagnostics,
            commands::ai::rerank_documents,
            commands::ai::graph_ai_vector_search,
            commands::learning::submit_feedback,
            commands::learning::get_learning_insights,
            commands::learning::adjust_prediction_confidence,
            commands::learning::learn_workflow_patterns,
            commands::learning::get_user_preferences,
            commands::learning::get_behavioral_patterns,
            commands::learning::get_confidence_trends,
            commands::learning::get_learning_stats,
            commands::copilot::copilot_send_message,
            commands::copilot::copilot_send_message_stream,
            commands::copilot::copilot_cancel_stream,
            commands::copilot::copilot_get_streaming_diagnostics,
            commands::copilot::copilot_get_conversation,
            commands::copilot::copilot_get_recent_conversations,
            commands::copilot::copilot_search_conversations,
            commands::copilot::copilot_get_daily_briefing,
            commands::copilot::copilot_get_tools,
            commands::copilot::copilot_discover_tools,
            commands::copilot::copilot_get_tool_diagnostics,
            commands::copilot::copilot_ask_question,
            commands::copilot::copilot_list_tool_permissions,
            commands::copilot::copilot_set_tool_permission,
            commands::copilot::copilot_clear_tool_permission,
            commands::copilot::copilot_check_tool_permission,
            commands::proactive::copilot_get_notifications,
            commands::proactive::copilot_dismiss_notification,
            commands::proactive::copilot_get_resume_context,
            commands::proactive::copilot_generate_plan,
            commands::proactive::copilot_set_permission,
            commands::proactive::copilot_check_permission,
            commands::proactive::copilot_get_enhanced_briefing,
            commands::proactive::copilot_query_timeline,
            commands::proactive::copilot_check_opportunities,
            commands::llm::llm_get_settings,
            commands::llm::llm_update_settings,
            commands::llm::llm_test_connection,
            commands::llm::llm_is_configured,
            commands::llm::llm_get_diagnostics,
            commands::execution::execution_start,
            commands::execution::execution_pause,
            commands::execution::execution_resume,
            commands::execution::execution_cancel,
            commands::execution::execution_get_progress,
            commands::execution::execution_list_recent,
            commands::memory::memory_search,
            commands::memory::memory_recommend,
            commands::memory::memory_avoid,
            commands::memory::memory_learned_workflows,
            commands::memory::memory_stats,
            commands::memory::memory_index_status,
            commands::memory::memory_reindex,
            commands::memory::memory_recommendation_feedback,
            commands::memory::memory_learning_health,
            commands::memory::memory_failure_patterns,
            commands::memory::memory_workflow_families,
            commands::memory::memory_aging_summary,
            commands::memory::memory_duplicate_groups,
            commands::memory::memory_merge_duplicates,
            commands::memory::memory_set_retention,
            commands::memory::memory_cleanup_now,
            commands::memory::memory_compress_oversized,
            commands::memory::memory_restore_compressed,
            commands::memory::memory_lineage,
            commands::memory::memory_export_json,
            commands::memory::memory_import_json,
            commands::memory::memory_snapshot_create,
            commands::memory::memory_snapshot_list,
            commands::memory::memory_snapshot_restore,
            commands::memory::memory_storage_stats,
            commands::autonomous::autonomous_start,
            commands::autonomous::autonomous_get_progress,
            commands::autonomous::autonomous_list_recent,
            commands::autonomous::autonomous_pause,
            commands::autonomous::autonomous_resume,
            commands::autonomous::autonomous_cancel,
            commands::autonomous::autonomous_approve,
            commands::autonomous::autonomous_reject,
            commands::performance::performance_profile,
            commands::performance::performance_startup,
            commands::performance::performance_benchmark,
            commands::performance::performance_diagnostics,
            commands::performance::performance_optimize,
            commands::performance::performance_history,
            commands::recovery::recovery_status,
            commands::recovery::recovery_history,
            commands::recovery::recovery_crash_reports,
            commands::recovery::recovery_latest_checkpoint,
            commands::recovery::recovery_self_heal,
            commands::recovery::recovery_rollback,
            commands::recovery::recovery_tick,
            commands::maintenance::maintenance_integrity,
            commands::maintenance::maintenance_backup,
            commands::maintenance::maintenance_backups,
            commands::maintenance::maintenance_restore,
            commands::maintenance::maintenance_pending_restore,
            commands::maintenance::maintenance_cancel_restore,
            commands::maintenance::maintenance_optimize,
            commands::security::security_status,
            commands::security::security_diagnostics,
            commands::security::security_secrets,
            commands::security::security_permissions,
            commands::security::security_history,
            commands::security::security_audit_log,
            commands::security::security_config,
            commands::security::security_set_config,
            commands::security::security_recommendations,
            commands::security::security_apply_recommendation,
            commands::security::security_dismiss_recommendation,
            commands::conversation::copilot_rename_conversation,
            commands::conversation::copilot_delete_conversation,
            commands::conversation::copilot_pin_conversation,
            commands::conversation::copilot_export_conversation_json,
            commands::conversation::copilot_export_conversation_markdown,
        ])
        .build(tauri::generate_context!("tauri.core.conf.json"))
        .expect("error while building ContextSphere")
        .run(|app_handle, event| {
            // RC-10 M2: record the clean-shutdown checkpoint on exit so
            // the next launch can distinguish a clean stop from a crash.
            // Best-effort and non-fatal: an interrupted shutdown simply
            // leaves the previous `running` checkpoint, which is exactly
            // the signal crash detection looks for.
            if let tauri::RunEvent::Exit = event {
                if let Some(manager) = app_handle.try_state::<RecoveryManager>() {
                    let _ = tauri::async_runtime::block_on(manager.record_clean_shutdown());
                }
                if let Some(watcher) = app_handle.try_state::<FileWatcher>() {
                    let _ = tauri::async_runtime::block_on(watcher.stop_all());
                }
            }
        });
}

fn log_level() -> log::LevelFilter {
    if cfg!(debug_assertions) {
        log::LevelFilter::Debug
    } else {
        log::LevelFilter::Info
    }
}
