import SwiftUI
import AppKit

// MARK: - Workspaces

/// Master-detail workspaces with native CRUD. The list is navigation;
/// the detail is calm material. Mutations use existing RPCs
/// (create/update/delete/switch) and refresh via AppRouter reload.
struct WorkspacesView: View {
    let workspaces: [Workspace]
    var onWorkspacesChanged: (() -> Void)? = nil

    @EnvironmentObject private var router: AppRouter
    @State private var showCreate = false
    @State private var showEdit = false
    @State private var selected: Workspace?
    @State private var detail: Workspace?
    @State private var detailError: String?
    @State private var isLoadingDetail = false
    @State private var showDeleteConfirm = false
    @State private var showArchiveConfirm = false
    @State private var isMutating = false
    @State private var mutationError: String?

    private var activeWorkspaces: [Workspace] {
        workspaces.filter { $0.status == .active }
    }

    private var archivedWorkspaces: [Workspace] {
        workspaces.filter { $0.status == .archived }
    }

    var body: some View {
        AnyView(
            workspacesContent
                .background(ContentBackdrop())
                .toolbar {
                    ToolbarItem { newWorkspaceToolbarButton }
                }
                .onChange(of: selected) { _, newValue in
                    guard let newValue else {
                        detail = nil
                        detailError = nil
                        isLoadingDetail = false
                        return
                    }
                    Task { await loadDetail(newValue) }
                }
                .onChange(of: router.newWorkspaceRequest) { _, requested in
                    guard requested else { return }
                    router.newWorkspaceRequest = false
                    showCreate = true
                }
                .onChange(of: router.revealWorkspaceRequest) { _, requestedID in
                    handleReveal(requestedID)
                }
                .sheet(isPresented: $showCreate) {
                    CreateWorkspaceSheet(onCreated: { workspace in
                        selected = workspace
                        triggerReload()
                    })
                }
        .sheet(isPresented: $showEdit) {
            if let detail {
                EditWorkspaceSheet(workspace: detail, onSaved: { updated in
                    self.detail = updated
                    selected = updated
                    triggerReload()
                })
            }
        }
                .confirmationDialog("Delete workspace?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        Task { await deleteSelected() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    if let detail {
                        Text("“\(detail.name)” and its timeline will be removed from ContextSphere. Files on disk are not deleted.")
                    }
                }
        .confirmationDialog(archiveTitle, isPresented: $showArchiveConfirm, titleVisibility: .visible) {
            Button(archiveActionTitle) {
                Task { await toggleArchive() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(archiveMessage)
        }
        )
    }

    // MARK: Header

    private var header: some View {
        ScreenHeader(
            "Workspaces",
            subtitle: workspaces.isEmpty
                ? "Organize your work into contexts ContextSphere can understand."
                : "\(activeWorkspaces.count) active · \(archivedWorkspaces.count) archived",
            symbol: "folder"
        ) {
            if !workspaces.isEmpty {
                Text("\(workspaces.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.4), in: Capsule())
                    .accessibilityLabel("\(workspaces.count) workspaces")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.quaternary.opacity(0.6), lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }

    private var newWorkspaceToolbarButton: some View {
        Button(action: { showCreate = true }) {
            Image(systemName: "plus")
        }
        .help("Create a new workspace")
    }

    private var workspacesContent: some View {
        VStack(spacing: 0) {
            header
            HSplitView {
                masterList
                    .frame(minWidth: 260, idealWidth: 320)
                detailPane
                    .frame(minWidth: 380)
            }
        }
    }

    // MARK: Master

    private var masterList: some View {
        Group {
            if workspaces.isEmpty {
                masterEmpty
            } else {
                List(selection: $selected) {
                    if !activeWorkspaces.isEmpty {
                        Section {
                            ForEach(activeWorkspaces) { workspace in
                                WorkspaceListRow(workspace: workspace, isSelected: selected?.id == workspace.id)
                                    .tag(workspace)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                                    .contextMenu { rowContextMenu(for: workspace) }
                            }
                        } header: {
                            Label("Active", systemImage: "folder.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !archivedWorkspaces.isEmpty {
                        Section {
                            ForEach(archivedWorkspaces) { workspace in
                                WorkspaceListRow(workspace: workspace, isSelected: selected?.id == workspace.id)
                                    .tag(workspace)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                                    .contextMenu { rowContextMenu(for: workspace) }
                            }
                        } header: {
                            Label("Archived", systemImage: "archivebox")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .background(.regularMaterial)
        .overlay(
            Rectangle().fill(.separator).frame(width: 1),
            alignment: .trailing
        )
    }

    private func rowContextMenu(for workspace: Workspace) -> some View {
        Group {
            Button {
                selected = workspace
            } label: {
                Label("Show Details", systemImage: "eye")
            }
            Button {
                Task { await switchTo(workspace) }
            } label: {
                Label("Switch to Workspace", systemImage: "arrow.triangle.swap")
            }
            Divider()
            Button {
                selected = workspace
                showEdit = true
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            if workspace.status == .active {
                Button {
                    selected = workspace
                    Task { await loadDetail(workspace) }
                    showArchiveConfirm = true
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
            } else {
                Button {
                    selected = workspace
                    Task { await loadDetail(workspace) }
                    showArchiveConfirm = true
                } label: {
                    Label("Unarchive", systemImage: "archivebox.fill")
                }
            }
            Divider()
            Button(role: .destructive) {
                selected = workspace
                Task { await loadDetail(workspace) }
                showDeleteConfirm = true
            } label: {
                Label("Delete…", systemImage: "trash")
            }
        }
    }

    private var masterEmpty: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No workspaces yet")
                .font(.headline)
            Text("Create your first workspace — ContextSphere will learn from the work you do inside it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            Button {
                showCreate = true
            } label: {
                Label("Create Workspace", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .combine)
    }

    // MARK: Detail

    @ViewBuilder
    private var detailPane: some View {
        Group {
            if isLoadingDetail {
                LoadingView(label: "Loading workspace…")
            } else if let detail {
                WorkspaceDetailView(
                    workspace: detail,
                    isMutating: isMutating,
                    mutationError: mutationError,
                    onEdit: { showEdit = true },
                    onArchive: { showArchiveConfirm = true },
                    onDelete: { showDeleteConfirm = true },
                    onSwitch: { Task { await switchTo(detail) } }
                )
            } else if let detailError {
                EmptyStateView(title: "Could not load workspace",
                               message: detailError, symbol: "exclamationmark.triangle")
            } else {
                EmptyStateView(title: "Select a workspace",
                               message: "Choose a workspace to see its details, health, and description.",
                               symbol: "folder")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
    }

    private func loadDetail(_ workspace: Workspace) async {
        isLoadingDetail = true
        detailError = nil
        defer { isLoadingDetail = false }
        do {
            detail = try await CoreBridge.shared.request(
                "get_workspace",
                params: ["id": workspace.id],
                as: Workspace.self)
        } catch {
            detailError = error.localizedDescription
        }
    }

    private var archiveTitle: String {
        detail?.status == .archived ? "Unarchive workspace?" : "Archive workspace?"
    }

    private var archiveActionTitle: String {
        detail?.status == .archived ? "Unarchive" : "Archive"
    }

    private var archiveMessage: String {
        guard let detail else { return "" }
        if detail.status == .archived {
            return "“\(detail.name)” will be moved back to Active."
        }
        return "“\(detail.name)” will be moved to Archived. You can restore it later."
    }

    private func handleReveal(_ id: String?) {
        guard let rid = id else {
            router.revealWorkspaceRequest = nil
            return
        }
        var found: Workspace?
        for w in workspaces where w.id == rid {
            found = w
            break
        }
        guard let workspace = found else {
            router.revealWorkspaceRequest = nil
            return
        }
        router.revealWorkspaceRequest = nil
        selected = workspace
    }

    private func triggerReload() {
        // Notify AppShell to reload active+archived, which propagates to dashboard/timeline/search/graph
        if let onWorkspacesChanged {
            onWorkspacesChanged()
        } else {
            AppRouter.shared.reloadRequest = true
        }
    }

    // MARK: Mutations

    private func toggleArchive() async {
        guard let detail else { return }
        isMutating = true
        mutationError = nil
        defer { isMutating = false }
        let targetStatus: WorkspaceStatus = detail.status == .archived ? .active : .archived
        do {
            let _: Workspace = try await CoreBridge.shared.request(
                "update_workspace",
                params: ["id": detail.id, "input": ["status": targetStatus.rawValue]],
                as: Workspace.self)
            triggerReload()
            // Move selection to reflect new status; a stale detail pane
            // would misreport the outcome of the archive toggle.
            do {
                let updated: Workspace = try await CoreBridge.shared.request(
                    "get_workspace", params: ["id": detail.id], as: Workspace.self)
                self.detail = updated
            } catch {
                mutationError = "Archived, but the details could not be refreshed: \(error.localizedDescription)"
            }
        } catch {
            mutationError = error.localizedDescription
        }
    }

    private func deleteSelected() async {
        guard let detail else { return }
        isMutating = true
        mutationError = nil
        defer { isMutating = false }
        do {
            try await CoreBridge.shared.call("delete_workspace", params: ["id": detail.id])
            self.detail = nil
            selected = nil
            triggerReload()
        } catch {
            mutationError = error.localizedDescription
        }
    }

    private func switchTo(_ workspace: Workspace) async {
        isMutating = true
        mutationError = nil
        defer { isMutating = false }
        do {
            try await CoreBridge.shared.call("switch_workspace", params: ["id": workspace.id])
            triggerReload()
        } catch {
            mutationError = error.localizedDescription
        }
    }
}
