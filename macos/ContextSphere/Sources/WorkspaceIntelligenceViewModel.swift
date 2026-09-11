import SwiftUI
import Combine

/// Manages workspace intelligence data, confidence scoring signals,
/// active workspace inference, contextual suggestions, and context continuity.
@MainActor
final class WorkspaceIntelligenceViewModel: ObservableObject {
    @Published var activeInference: ActiveWorkspaceInference?
    @Published var selectedIntelligence: WorkspaceIntelligence?
    @Published var allWorkspacesIntelligence: [WorkspaceIntelligence] = []
    @Published var smartResumeContext: ReconstructedContext?
    @Published var selectedReconstructedContext: ReconstructedContext?
    @Published var isLoading = false
    @Published var error: String?

    private var loadTask: Task<Void, Never>?

    init() {
        refresh()
    }

    func initialLoadIfNeeded() {
        guard activeInference == nil && !isLoading else { return }
        refresh()
    }

    func refresh() {
        loadTask?.cancel()
        loadTask = Task { await load() }
    }

    /// Loads active workspace inference, intelligence across workspaces, and smart resume context.
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let activeTask: ActiveWorkspaceInference = CoreBridge.shared.request(
                "get_active_workspace_inference",
                as: ActiveWorkspaceInference.self
            )
            async let allTask: [WorkspaceIntelligence] = CoreBridge.shared.request(
                "list_workspaces_intelligence",
                as: [WorkspaceIntelligence].self
            )
            async let resumeTask: ReconstructedContext? = CoreBridge.shared.request(
                "get_smart_resume_context",
                as: ReconstructedContext?.self
            )

            let (active, all, resume) = try await (activeTask, allTask, resumeTask)
            self.activeInference = active
            self.allWorkspacesIntelligence = all
            self.smartResumeContext = resume
            self.error = nil
        } catch {
            self.error = (error as NSError).localizedDescription
        }
    }

    /// Fetches detailed intelligence and reconstructed context for a specific workspace ID.
    func loadIntelligence(for workspaceId: String) async {
        do {
            async let intelTask: WorkspaceIntelligence = CoreBridge.shared.request(
                "get_workspace_intelligence",
                params: ["workspace_id": workspaceId],
                as: WorkspaceIntelligence.self
            )
            async let contextTask: ReconstructedContext = CoreBridge.shared.request(
                "reconstruct_workspace_context",
                params: ["workspace_id": workspaceId],
                as: ReconstructedContext.self
            )
            let (intel, ctx) = try await (intelTask, contextTask)
            self.selectedIntelligence = intel
            self.selectedReconstructedContext = ctx
        } catch {
            self.error = (error as NSError).localizedDescription
        }
    }

    /// Captures a deterministic ContextSnapshot of the current work episode.
    func snapshotEpisode(for workspaceId: String) async {
        do {
            let _: ContextSnapshot = try await CoreBridge.shared.request(
                "snapshot_work_episode",
                params: ["workspace_id": workspaceId],
                as: ContextSnapshot.self
            )
            await load()
            if let sel = selectedIntelligence, sel.workspaceId == workspaceId {
                await loadIntelligence(for: workspaceId)
            }
        } catch {
            self.error = "Failed to create snapshot: \(error.localizedDescription)"
        }
    }

    /// Executes an explicit user-controlled resume action.
    func executeResumeAction(_ action: ResumeAction) async {
        guard let target = action.target else { return }
        switch action.actionType {
        case "switch_workspace":
            await resumeEpisode(workspaceId: target)
        case "open_files":
            // Reveal workspace files in sidebar or switch to target
            await resumeEpisode(workspaceId: target)
        default:
            await resumeEpisode(workspaceId: target)
        }
    }

    /// Executes a contextual suggestion surfaced by the intelligence engine.
    func executeSuggestion(_ suggestion: WorkspaceSuggestion) async {
        guard let target = suggestion.target else { return }
        switch suggestion.actionType {
        case "resume_workspace":
            await resumeEpisode(workspaceId: target)

        case "create_snapshot":
            await snapshotEpisode(for: target)

        case "review_health":
            AppRouter.shared.selection = .workspaces
            AppRouter.shared.revealWorkspaceRequest = target

        default:
            break
        }
    }

    /// Resumes work for a workspace associated with an episode.
    func resumeEpisode(workspaceId: String) async {
        do {
            try await CoreBridge.shared.call("switch_workspace", params: ["id": workspaceId])
            AppRouter.shared.reloadRequest = true
            refresh()
        } catch {
            self.error = "Failed to resume episode: \(error.localizedDescription)"
        }
    }

    /// Handles events pushed from CoreBridge daemon.
    func handle(event: String, payload: Data?) {
        if event.hasPrefix("workspace:") ||
           event.hasPrefix("timeline:") ||
           event == "activity:recorded" ||
           event == "health:updated" ||
           event == "snapshot:created" ||
           event == "session:started" ||
           event == "session:ended" {
            Task { await load() }
        }
    }
}
