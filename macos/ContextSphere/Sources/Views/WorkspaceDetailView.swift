import SwiftUI

struct WorkspaceDetailView: View {
    let workspace: Workspace
    var isMutating = false
    var mutationError: String? = nil
    var onEdit: (() -> Void)? = nil
    var onArchive: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onSwitch: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                identity
                if let error = mutationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Error: \(error)")
                }
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
                actions
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

    private var actions: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Workspace Actions", systemImage: "wrench.and.screwdriver")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        onEdit?()
                    } label: {
                        Label("Rename…", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isMutating)
                    .accessibilityLabel("Rename workspace")

                    Button {
                        onSwitch?()
                    } label: {
                        Label("Switch", systemImage: "arrow.triangle.swap")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isMutating)
                    .help("Make this the active workspace")
                    .accessibilityLabel("Switch to this workspace")

                    Menu {
                        if workspace.status == .active {
                            Button {
                                onArchive?()
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                        } else {
                            Button {
                                onArchive?()
                            } label: {
                                Label("Unarchive", systemImage: "archivebox.fill")
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            onDelete?()
                        } label: {
                            Label("Delete…", systemImage: "trash")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(isMutating)
                    .accessibilityLabel("More workspace actions")

                    Spacer()
                    if isMutating {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Working")
                    }
                }
                Text("Switch makes this workspace current for Dashboard, Timeline, and Search. Archive moves between Active/Archived. Delete removes the workspace record only — files on disk are not deleted.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var healthColor: Color {
        if workspace.healthScore >= 70 { return .green }
        if workspace.healthScore >= 40 { return .orange }
        return .red
    }
}
