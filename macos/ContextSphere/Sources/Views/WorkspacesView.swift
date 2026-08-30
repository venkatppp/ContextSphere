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
    @State private var containerWidth: CGFloat = 1024

    private var activeWorkspaces: [Workspace] {
        workspaces.filter { $0.status == .active }
    }

    private var archivedWorkspaces: [Workspace] {
        workspaces.filter { $0.status == .archived }
    }

    var body: some View {
        workspacesContent
            .background(ContentBackdrop())
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
    }

    // MARK: - Header

    private var subtitle: String {
        if workspaces.isEmpty {
            return "Organize your work into contexts ContextSphere can understand."
        }
        return "Your contexts. Switch, archive, or create new ones."
    }

    private var headerTrailing: some View {
        HStack(spacing: 8) {
            if !workspaces.isEmpty {
                HStack(spacing: 6) {
                    Text("\(activeWorkspaces.count) active")
                        .font(.caption2.weight(.medium))
                        .csForeground(CSColor.success)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Color.cs(CSColor.success).opacity(0.14),
                            in: Capsule(style: .continuous)
                        )
                    Text("\(archivedWorkspaces.count) archived")
                        .font(.caption2.weight(.medium))
                        .csForeground(CSColor.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Color.cs(CSColor.textTertiary).opacity(0.10),
                            in: Capsule(style: .continuous)
                        )
                }
            }
            Button { showCreate = true } label: {
                Label("New", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityLabel("Create new workspace")
        }
    }

    private var workspacesContent: some View {
        VStack(spacing: 0) {
            StandardPageHeader(
                section: .workspaces,
                activeWorkspace: workspaces.first { $0.status == .active } ?? workspaces.first,
                title: "Workspaces",
                subtitle: subtitle,
                symbol: AppSection.workspaces.symbol,
                eyebrow: NavGroup.workspace.title.uppercased()
            ) { headerTrailing }
                .padding(.horizontal, Theme.horizontalPadding(for: containerWidth))
                .padding(.vertical, Theme.pageHeaderVerticalPadding)
            Hairline(opacity: Theme.pageHeaderDividerOpacity)
            HSplitView {
                masterList
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
                detailPane
                    .frame(minWidth: 440)
            }
        }
        .overlay {
            GeometryReader { geo in
                Color.clear
                    .onAppear { containerWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in containerWidth = new }
            }
            .frame(height: 0)
        }
    }

    // MARK: - Master

    private var masterList: some View {
        VStack(spacing: 0) {
            if workspaces.isEmpty {
                masterEmpty
            } else {
                List(selection: $selected) {
                    if !activeWorkspaces.isEmpty {
                        Section {
                            ForEach(activeWorkspaces) { workspace in
                                WorkspaceListRow(workspace: workspace, isSelected: selected?.id == workspace.id)
                                    .tag(workspace)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                                    .listRowSeparator(.hidden)
                                    .contextMenu { rowContextMenu(for: workspace) }
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .csForeground(CSColor.textTertiary)
                                Text("Active")
                                    .font(.csEyebrow(size: 10))
                                    .tracking(0.7)
                                    .csForeground(CSColor.textTertiary)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.bottom, 4)
                        }
                    }
                    if !archivedWorkspaces.isEmpty {
                        Section {
                            ForEach(archivedWorkspaces) { workspace in
                                WorkspaceListRow(workspace: workspace, isSelected: selected?.id == workspace.id)
                                    .tag(workspace)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                                    .listRowSeparator(.hidden)
                                    .contextMenu { rowContextMenu(for: workspace) }
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: "archivebox")
                                    .font(.system(size: 10, weight: .semibold))
                                    .csForeground(CSColor.textTertiary)
                                Text("Archived")
                                    .font(.csEyebrow(size: 10))
                                    .tracking(0.7)
                                    .csForeground(CSColor.textTertiary)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.bottom, 4)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .lgSidebarBackground()
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
        EmptyStateView(
            title: "No workspaces yet",
            message: "Create your first workspace — ContextSphere will learn from the work you do inside it.",
            symbol: "folder.badge.plus",
            primaryAction: ("Create Workspace", { showCreate = true })
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Detail

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
                EmptyStateView(
                    title: "Select a workspace",
                    message: "Choose a workspace from the list to see its health, metrics, and recent activity.",
                    symbol: "folder"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cs(CSColor.surface))
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

    // MARK: - Mutations

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
