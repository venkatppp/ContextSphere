import SwiftUI
import AppKit

// MARK: - Workspaces

/// Master-detail workspaces experience. The list is the navigation
/// layer; the detail is calm material content. Empty states are
/// first-class — a new user should immediately understand what a
/// workspace is and how to create one.
struct WorkspacesView: View {
    let workspaces: [Workspace]

    @EnvironmentObject private var router: AppRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showCreate = false
    @State private var selected: Workspace?
    @State private var detail: Workspace?
    @State private var detailError: String?
    @State private var isLoadingDetail = false

    private var activeWorkspaces: [Workspace] {
        workspaces.filter { $0.status == .active }
    }

    private var archivedWorkspaces: [Workspace] {
        workspaces.filter { $0.status == .archived }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HSplitView {
                masterList
                    .frame(minWidth: 260, idealWidth: 320)
                detailPane
                    .frame(minWidth: 380)
            }
        }
        .background(ContentBackdrop())
        .toolbar {
            ToolbarItem {
                Button {
                    showCreate = true
                } label: {
                    Label("New Workspace", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("Create a new workspace")
                .accessibilityLabel("Create new workspace")
            }
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
            guard let requestedID,
                  let workspace = workspaces.first(where: { $0.id == requestedID }) else {
                router.revealWorkspaceRequest = nil
                return
            }
            router.revealWorkspaceRequest = nil
            selected = workspace
        }
        .sheet(isPresented: $showCreate) {
            CreateWorkspaceSheet()
        }
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
            if workspaces.isEmpty == false {
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
                WorkspaceDetailView(workspace: detail)
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
}

// MARK: - List row

struct WorkspaceListRow: View {
    let workspace: Workspace
    var isSelected = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.accentColor.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: workspace.status == .active ? "folder.fill" : "archivebox.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .primary : .primary)
                if let path = workspace.rootPath, !path.isEmpty {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if let description = workspace.description, !description.isEmpty {
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if workspace.status == .active {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(workspace.name), \(workspace.status.rawValue), \(workspace.rootPath ?? "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Detail

struct WorkspaceDetailView: View {
    let workspace: Workspace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                identity
                metrics
                if let description = workspace.description, !description.isEmpty {
                    ContentCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Description", systemImage: "text.alignleft")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(description)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                meta
            }
            .frame(maxWidth: Theme.contentMaxWidth)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 48, height: 48)
                Image(systemName: "folder.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.name)
                    .font(.title2.weight(.bold))
                    .tracking(-0.2)
                    .lineLimit(2)
                if let path = workspace.rootPath, !path.isEmpty {
                    Label(path, systemImage: "folder")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Text(workspace.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help("Workspace identifier")
            }
            Spacer()
            StatusBadge(status: workspace.status)
        }
        .accessibilityElement(children: .combine)
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            ContentCard(cornerRadius: Theme.cornerRegular) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Health", systemImage: "heart.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(Int(workspace.healthScore))")
                            .font(.system(size: 28, weight: .bold).monospacedDigit())
                            .foregroundStyle(healthColor)
                        Text("%")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: workspace.healthScore / 100)
                        .tint(healthColor)
                        .scaleEffect(x: 1, y: 0.9, anchor: .center)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ContentCard(cornerRadius: Theme.cornerRegular) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Created", systemImage: "calendar")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(workspace.createdAt.isoDate?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                        .font(.callout.weight(.medium))
                    Text(workspace.createdAt.relativeTime)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ContentCard(cornerRadius: Theme.cornerRegular) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Last active", systemImage: "clock.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(workspace.lastActiveAt.relativeTime)
                        .font(.callout.weight(.medium))
                    Text(workspace.lastActiveAt.isoDate?.formatted(date: .abbreviated, time: .shortened) ?? "")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var meta: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Details", systemImage: "info.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                LabeledContent("Status", value: workspace.status.rawValue.capitalized)
                    .font(.callout)
                LabeledContent("Updated", value: workspace.updatedAt.relativeTime)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var healthColor: Color {
        if workspace.healthScore >= 70 { return .green }
        if workspace.healthScore >= 40 { return .orange }
        return .red
    }
}

// MARK: - Stat tile (shared)

struct StatTile: View {
    let label: String
    let value: String
    let symbol: String

    var body: some View {
        ContentCard(cornerRadius: Theme.cornerRegular) {
            VStack(alignment: .leading, spacing: 6) {
                Label(label, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct StatusBadge: View {
    let status: WorkspaceStatus

    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(status == .active ? Color.green.opacity(0.14) : Color.secondary.opacity(0.12),
                        in: Capsule())
            .foregroundStyle(status == .active ? Color.green : Color.secondary)
            .overlay(
                Capsule().strokeBorder(status == .active ? Color.green.opacity(0.25) : Color.clear, lineWidth: 0.5)
            )
            .accessibilityLabel("Status \(status.rawValue)")
    }
}

// MARK: - Create sheet

struct CreateWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @State private var name = ""
    @State private var rootPath = ""
    @State private var description = ""
    @State private var error: String?
    @State private var working = false

    private enum Field { case name, path, description }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            form
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Error: \(error)")
            }
            actions
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { focusedField = .name }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New Workspace")
                .font(.title3.weight(.semibold))
            Text("A workspace is a context boundary — ContextSphere learns the files, rhythms, and relationships inside it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.callout.weight(.medium))
                TextField("My Project", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
                    .onSubmit { focusedField = .path }
                    .accessibilityLabel("Workspace name")
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Root path")
                        .font(.callout.weight(.medium))
                    Text("optional")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary.opacity(0.4), in: Capsule())
                }
                HStack(spacing: 8) {
                    TextField("/path/to/project", text: $rootPath)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .path)
                        .onSubmit { focusedField = .description }
                        .help("Absolute path to the directory this workspace represents")
                        .accessibilityLabel("Workspace root path")
                    Button("Browse…") { choosePath() }
                        .help("Choose a folder")
                        .accessibilityLabel("Browse for workspace folder")
                }
                Text("Leave empty to create a workspace without a directory.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Description")
                        .font(.callout.weight(.medium))
                    Text("optional")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary.opacity(0.4), in: Capsule())
                }
                TextField("What is this workspace for?", text: $description, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                    .focused($focusedField, equals: .description)
                    .accessibilityLabel("Workspace description")
            }
        }
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel creating workspace")
            Button {
                Task { await create() }
            } label: {
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Create")
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(trimmedName.isEmpty || working)
            .accessibilityLabel("Create workspace")
        }
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            rootPath = url.path
        }
    }

    private func create() async {
        working = true
        defer { working = false }
        do {
            let params: [String: Any] = [
                "name": trimmedName,
                "rootPath": rootPath.trimmingCharacters(in: .whitespaces).isEmpty ? NSNull() : rootPath,
                "description": description.trimmingCharacters(in: .whitespaces).isEmpty ? NSNull() : description,
            ]
            let _: Workspace = try await CoreBridge.shared.request(
                "create_workspace", params: params, as: Workspace.self)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
