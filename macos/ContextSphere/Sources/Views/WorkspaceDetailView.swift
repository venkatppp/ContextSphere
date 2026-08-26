import SwiftUI
import Charts

struct WorkspaceDetailView: View {
    let workspace: Workspace
    var isMutating = false
    var mutationError: String? = nil
    var onEdit: (() -> Void)? = nil
    var onArchive: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onSwitch: (() -> Void)? = nil

    @State private var healthReport: WorkspaceHealthReport?
    @State private var healthHistory: [WorkspaceHealthReport] = []
    @State private var healthError: String?
    @State private var isLoadingHealth = false

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
                workspaceHealthCard
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
        .task(id: workspace.id) {
            await loadHealth()
        }
        // Live health pushes (`health:updated`) refresh the card without
        // a manual reload.
        .onReceive(
            NotificationCenter.default.publisher(for: .workspaceHealthDidChange)
        ) { note in
            guard let id = note.userInfo?["workspaceId"] as? String,
                  id == workspace.id else { return }
            Task { await loadHealth() }
        }
    }

    // MARK: - Workspace health intelligence

    /// Live intelligence view of this workspace: overall score with
    /// trend, contributing factors, and a 7-day score history.
    /// Failures degrade to an inline caption — the static gauge above
    /// still communicates the basics.
    @ViewBuilder
    private var workspaceHealthCard: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Workspace Health",
                              subtitle: healthSubtitle,
                              symbol: "stethoscope")
                if let report = healthReport {
                    HStack(spacing: 16) {
                        Text("\(Int((report.overallScore * 100).rounded()))")
                            .font(.system(size: 30, weight: .bold).monospacedDigit())
                            .foregroundStyle(healthColor(report.overallScore))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("of 100")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let trend = report.trend {
                                Label(trend >= 0
                                      ? String(format: "+%.0f%%", trend * 100)
                                      : String(format: "%.0f%%", trend * 100),
                                      systemImage: trend >= 0
                                      ? "arrow.up.right" : "arrow.down.right")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(trend >= 0 ? .green : .orange)
                            }
                        }
                        Spacer()
                        if !healthHistory.isEmpty {
                            HealthSparkline(scores: healthHistory.map(\.overallScore))
                                .frame(width: 120, height: 36)
                                .accessibilityLabel("7-day health history")
                        }
                    }
                    ForEach(report.factors.sorted { $0.score < $1.score }.prefix(4)) { factor in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(factor.name).font(.caption.weight(.medium))
                                Spacer()
                                Text("\(Int((factor.score * 100).rounded()))%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: factor.score)
                                .tint(factor.score >= 0.6 ? .green
                                      : factor.score >= 0.35 ? .orange : .red)
                            Text(factor.description)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(factor.name): \(Int((factor.score * 100).rounded())) percent. \(factor.description)")
                    }
                } else if let healthError {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(healthError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Retry") { Task { await loadHealth() } }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                } else if isLoadingHealth {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Health intelligence appears once the workspace has activity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var healthSubtitle: String? {
        if let report = healthReport { return report.calculatedAt.relativeTime }
        return nil
    }

    private func healthColor(_ score: Double) -> Color {
        score >= 0.6 ? .green : (score >= 0.35 ? .orange : .red)
    }

    private func loadHealth() async {
        isLoadingHealth = true
        defer { isLoadingHealth = false }
        do {
            async let current: WorkspaceHealthReport = CoreBridge.shared.request(
                "get_workspace_health",
                params: ["workspace_id": workspace.id],
                as: WorkspaceHealthReport.self)
            async let past: [WorkspaceHealthReport] = CoreBridge.shared.request(
                "get_workspace_health_history",
                params: ["workspace_id": workspace.id, "days": 7],
                as: [WorkspaceHealthReport].self)
            let (c, h) = try await (current, past)
            healthReport = c
            healthHistory = h
            healthError = nil
        } catch {
            healthError = error.localizedDescription
        }
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

/// Minimal score-history sparkline (Swift Charts). Kept deliberately
/// quiet: no axes, single tinted line.
struct HealthSparkline: View {
    let scores: [Double]

    var body: some View {
        if scores.count >= 2 {
            Chart(Array(scores.enumerated()), id: \.offset) { index, score in
                LineMark(x: .value("Day", index), y: .value("Score", score))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.tint)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .accessibilityHidden(true)
        } else {
            Text("Not enough history yet")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
