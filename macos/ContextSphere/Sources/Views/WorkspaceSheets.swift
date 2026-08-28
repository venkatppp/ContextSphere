import SwiftUI
import AppKit

// MARK: - Create workspace sheet

struct CreateWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @State private var name = ""
    @State private var rootPath = ""
    @State private var description = ""
    @State private var error: String?
    @State private var working = false
    var onCreated: ((Workspace) -> Void)? = nil

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
                    .csForeground(CSColor.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Error: \(error)")
            }
            actions
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { focusedField = .name }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New Workspace")
                .font(.title2.weight(.semibold))
                .tracking(-0.2)
            Text("A workspace is a context boundary — ContextSphere learns the files, rhythms, and relationships inside it.")
                .font(.callout)
                .csForeground(CSColor.textSecondary)
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
                        .csForeground(CSColor.textTertiary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.cs(CSColor.border), in: Capsule())
                }
                HStack(spacing: 8) {
                    TextField("/path/to/project", text: $rootPath)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .path)
                        .onSubmit { focusedField = .description }
                        .help("Absolute path to the directory this workspace represents. It will be watched automatically.")
                        .accessibilityLabel("Workspace root path")
                    Button("Choose…") { choosePath() }
                        .help("Choose a folder")
                        .accessibilityLabel("Choose workspace folder")
                }
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.caption2)
                        .csForeground(CSColor.textTertiary)
                    Text("If you choose a folder, ContextSphere will watch it locally. Files stay on this Mac and are never uploaded. Leave empty for a placeholder workspace.")
                        .font(.caption2)
                        .csForeground(CSColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Description")
                        .font(.callout.weight(.medium))
                    Text("optional")
                        .font(.caption2)
                        .csForeground(CSColor.textTertiary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.cs(CSColor.border), in: Capsule())
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
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Creating…")
                    }
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
            let trimmedRoot = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
            let input: [String: Any] = [
                "name": trimmedName,
                "rootPath": trimmedRoot.isEmpty ? NSNull() : trimmedRoot,
                "description": trimmedDesc.isEmpty ? NSNull() : trimmedDesc,
            ]
            let params: [String: Any] = ["input": input]
            let ws: Workspace = try await CoreBridge.shared.request(
                "create_workspace", params: params, as: Workspace.self)
            // Honest first-run: if a folder was chosen, watch it immediately so Timeline/Graph
            // begin filling without an extra Settings step. Best-effort; creation still succeeds.
            if !trimmedRoot.isEmpty {
                do {
                    try await CoreBridge.shared.call("add_watch_path", params: ["path": trimmedRoot])
                } catch {
                    let msg = error.localizedDescription
                    // AlreadyWatching is not an error for the user — the folder is already observed.
                    if msg.contains("AlreadyWatching") || msg.contains("already watching") {
                        // Silently succeed; no warning needed.
                    } else {
                        // Non-fatal: workspace is created; watch can be added later in Settings.
                        self.error = "Workspace created, but could not watch \(trimmedRoot): \(msg). Add it in Settings → Watched Paths."
                        onCreated?(ws)
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        dismiss()
                        return
                    }
                }
            }
            onCreated?(ws)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Edit workspace sheet

struct EditWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    let workspace: Workspace
    var onSaved: ((Workspace) -> Void)? = nil

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var error: String?
    @State private var working = false

    private enum Field { case name, description }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit Workspace")
                    .font(.title2.weight(.semibold))
                    .tracking(-0.2)
                Text("Update the name or description for “\(workspace.name)”.")
                    .font(.callout)
                    .csForeground(CSColor.textSecondary)
            }
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.callout.weight(.medium))
                    TextField("My Project", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .name)
                        .accessibilityLabel("Workspace name")
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Description")
                            .font(.callout.weight(.medium))
                        Text("optional")
                            .font(.caption2)
                            .csForeground(CSColor.textTertiary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.cs(CSColor.border), in: Capsule())
                    }
                    TextField("What is this workspace for?", text: $description, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        .focused($focusedField, equals: .description)
                        .accessibilityLabel("Workspace description")
                }
                if let path = workspace.rootPath, !path.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Root path")
                            .font(.csEyebrow())
                            .csForeground(CSColor.textTertiary)
                            .textCase(.uppercase)
                            .tracking(0.5)
                        Text(path)
                            .font(.callout)
                            .csForeground(CSColor.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .csForeground(CSColor.error)
                    .accessibilityLabel("Error: \(error)")
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await save() }
                } label: {
                    if working {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Saving…")
                        }
                    } else {
                        Text("Save")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(trimmedName.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            name = workspace.name
            description = workspace.description ?? ""
            focusedField = .name
        }
    }

    private func save() async {
        working = true
        defer { working = false }
        do {
            let trimmedDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
            let input: [String: Any] = [
                "name": trimmedName,
                "description": trimmedDesc.isEmpty ? NSNull() : trimmedDesc,
            ]
            let updated: Workspace = try await CoreBridge.shared.request(
                "update_workspace",
                params: ["id": workspace.id, "input": input],
                as: Workspace.self)
            onSaved?(updated)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
