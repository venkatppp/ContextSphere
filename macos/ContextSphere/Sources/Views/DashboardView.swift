import SwiftUI
import AppKit

/// ContextSphere's flagship screen. Communicates:
/// - "What am I working on?"   → current workspace hero + resume context
/// - "What should I do next?"  → intelligence (predictions + recommendations)
/// - "What changed?"           → recent context (activity + open files)
/// - "Is everything healthy?"  → compact system health strip
///
/// The information layer uses calm native material. Glass is reserved for
/// the hero chrome and interactive controls only.
struct DashboardView: View {
    let workspaces: [Workspace]
    let onRevealWorkspace: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var activity: [TimelineEvent] = []
    @State private var health: RuntimeHealth?
    @State private var predictions: PredictionsSummary?
    @State private var recommendations: [Recommendation] = []
    @State private var resume: ResumeContext?
    @State private var loading = true

    init(workspaces: [Workspace], onRevealWorkspace: @escaping (String) -> Void = { _ in }) {
        self.workspaces = workspaces
        self.onRevealWorkspace = onRevealWorkspace
    }

    private var currentWorkspace: Workspace? {
        workspaces.first { $0.status == .active } ?? workspaces.first
    }

    private var emptyWorkspaces: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Create your first workspace")
                .font(.title3.weight(.semibold))
            Text("ContextSphere learns from the work you do inside a workspace. Create one and it will begin tracking context here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .accessibilityElement(children: .combine)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if workspaces.isEmpty {
                    emptyWorkspaces
                } else {
                    hero
                    intelligenceRow
                    systemHealth
                }
            }
            .frame(maxWidth: Theme.contentMaxWidth)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .task(id: workspaces.first?.id) {
            await load()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Image(systemName: "scope")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("ContextSphere")
                        .font(.system(size: 28, weight: .semibold))
                        .tracking(-0.4)
                        .accessibilityLabel("ContextSphere")
                }
                if let workspace = currentWorkspace {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.tint)
                            .font(.caption)
                        Text(workspace.name)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                }
            }
            Spacer()
            refreshControl
        }
        .padding(.horizontal, 8)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.bottom, 4)
    }

    private var refreshControl: some View {
        Button {
            Task { await load() }
        } label: {
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .buttonStyle(.plain)
        .help("Refresh dashboard data")
        .accessibilityLabel("Refresh dashboard")
    }

    // MARK: - Hero

    private var hero: some View {
        GlassSection(tint: .indigo, interactive: true) {
            if let workspace = currentWorkspace {
                HStack(alignment: .top, spacing: 20) {
                    workspaceIdentity(workspace)
                    Spacer(minLength: 24)
                    healthGauge(workspace)
                    VStack(alignment: .trailing, spacing: 10) {
                        StatusBadge(status: workspace.status)
                        Text("Active \(workspace.lastActiveAt.relativeTime)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            onRevealWorkspace(workspace.id)
                        } label: {
                            Label("Resume", systemImage: "arrow.uturn.forward.circle")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.indigo)
                        .accessibilityHint("Opens the Workspaces section")
                    }
                }

                if let resume, !resume.unfinishedWork.isEmpty {
                    Divider().opacity(0.5)
                    unfinishedWorkList(resume.unfinishedWork)
                }
            }
        }
        .animation(Theme.spring(reduceMotion), value: resume?.unfinishedWork.count)
    }

    private func workspaceIdentity(_ workspace: Workspace) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: "folder.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(workspace.name)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                if let path = workspace.rootPath {
                    Text(path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let description = workspace.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let openFiles = resume?.openFiles, !openFiles.isEmpty {
                    openFilesLine(openFiles)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func openFilesLine(_ files: [String]) -> some View {
        HStack(spacing: 6) {
            Text("Open:")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(files.prefix(3), id: \.self) { file in
                Label((file as NSString).lastPathComponent, systemImage: "doc")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(file)
            }
        }
        .padding(.top, 4)
    }

    private func healthGauge(_ workspace: Workspace) -> some View {
        VStack(spacing: 6) {
            Gauge(value: workspace.healthScore, in: 0...100) {
                Text("Health")
            } currentValueLabel: {
                Text("\(Int(workspace.healthScore))%")
                    .font(.system(size: 20, weight: .bold).monospacedDigit())
            }
            .gaugeStyle(.accessoryCircular)
            .tint(healthColor(workspace.healthScore))
            .frame(width: 74, height: 74)
            .accessibilityLabel("Workspace health \(Int(workspace.healthScore)) percent")
        }
    }

    private func healthColor(_ score: Double) -> Color {
        if score >= 70 { return .green }
        if score >= 40 { return .orange }
        return .red
    }

    private func unfinishedWorkList(_ items: [UnfinishedWork]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Unfinished work", systemImage: "tray.full")
                .font(.subheadline.weight(.semibold))
            ForEach(items.prefix(4)) { item in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(Color.accentColor.opacity(0.7))
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.description)
                            .font(.callout)
                        HStack(spacing: 6) {
                            if let file = item.filePath {
                                Text((file as NSString).lastPathComponent)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text("· \(item.confidence.percentString) confidence")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.description), \(item.confidence.percentString) confidence")
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Intelligence + Recent context

    private var intelligenceRow: some View {
        HStack(alignment: .top, spacing: 20) {
            intelligencePanel
                .frame(maxWidth: .infinity)
            recentContextPanel
                .frame(maxWidth: .infinity)
        }
    }

    private var intelligencePanel: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Intelligence",
                              subtitle: "What should you do next?",
                              symbol: "wand.and.stars")

                if let predictions {
                    if let next = predictions.nextWorkspace {
                        nextUpBlock(next)
                    }
                    if let continuation = predictions.sessionContinuation {
                        sessionContinuationBlock(continuation)
                    }
                    if !predictions.nextFiles.isEmpty {
                        nextFilesBlock(Array(predictions.nextFiles.prefix(3)))
                    }
                } else {
                    Text("Predictions will appear here as ContextSphere learns your patterns.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !recommendations.isEmpty {
                    Divider().opacity(0.5)
                    recommendationsBlock
                }
            }
        }
    }

    private func nextUpBlock(_ prediction: WorkspacePrediction) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Next workspace")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(prediction.workspaceName)
                    .font(.callout.weight(.semibold))
                Text(prediction.reason)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(prediction.confidence.percentString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Next workspace: \(prediction.workspaceName). \(prediction.reason). Confidence \(prediction.confidence.percentString)")
    }

    private func sessionContinuationBlock(_ continuation: SessionContinuationPrediction) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(continuation.willContinue ? .green : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(continuation.willContinue ? "Session continuation expected" : "Session winding down")
                    .font(.callout.weight(.medium))
                Text(continuation.reason)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if continuation.willContinue {
                Text("≈ \(Duration.seconds(Double(continuation.estimatedDurationSeconds)).formatted(.units(allowed: [.minutes])))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(continuation.willContinue ? "Session continuation expected" : "Session winding down"). \(continuation.reason)")
    }

    private func nextFilesBlock(_ files: [FilePrediction]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Likely files")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(files) { file in
                Button {
                    openPredictedFile(file.filePath)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text((file.filePath as NSString).lastPathComponent)
                            .font(.callout)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(file.confidence.percentString)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Image(systemName: "arrow.up.forward.app")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(file.filePath)
                .contextMenu {
                    Button {
                        openPredictedFile(file.filePath)
                    } label: {
                        Label("Open", systemImage: "arrow.up.forward.app")
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.filePath)])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    Divider()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(file.filePath, forType: .string)
                    } label: {
                        Label("Copy Path", systemImage: "doc.on.doc")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(file.filePath), \(file.confidence.percentString) confidence")
                .accessibilityHint("Opens the predicted file")
            }
        }
    }

    private func openPredictedFile(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if NSWorkspace.shared.open(url) { return }
        Task {
            try? await CoreBridge.shared.call("open_file", params: ["path": path])
        }
    }

    private var recommendationsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recommended")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(recommendations.prefix(3)) { recommendation in
                Button {
                    onRevealWorkspace(recommendation.workspaceId)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        PriorityPill(priority: recommendation.priority)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recommendation.title)
                                .font(.callout.weight(.medium))
                                .multilineTextAlignment(.leading)
                            Text(recommendation.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(recommendation.priority) priority: \(recommendation.title). \(recommendation.description)")
            }
        }
    }

    private var recentContextPanel: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Recent Context",
                              subtitle: "What changed?",
                              symbol: "clock.arrow.circlepath")

                if activity.isEmpty {
                    Text("No activity recorded yet in \(currentWorkspace?.name ?? "this workspace").")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(activity.prefix(6).enumerated()), id: \.element.id) { index, event in
                            DashboardActivityRow(event: event)
                            if index < min(activity.count, 6) - 1 {
                                Divider().opacity(0.5)
                            }
                        }
                    }
                }

                if let resume, !resume.openFiles.isEmpty {
                    Divider().opacity(0.5)
                    Label("\(resume.openFiles.count) files open",
                          systemImage: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - System health

    private var systemHealth: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "System Health",
                              subtitle: "Core status at a glance",
                              symbol: "waveform.path.ecg")

                if let health {
                    HStack(spacing: 24) {
                        HealthFact(title: "Core",
                                   value: health.isHealthy ? "Healthy" : health.status.capitalized,
                                   symbol: "checkmark.circle.fill",
                                   color: health.isHealthy ? .green : .orange)
                        HealthFact(title: "Uptime",
                                   value: Duration.seconds(Double(health.uptimeSeconds)).formatted(.units(allowed: [.hours, .minutes])),
                                   symbol: "clock",
                                   color: .secondary)
                        HealthFact(title: "Workers",
                                   value: "\(health.workersActive)",
                                   symbol: "person.2",
                                   color: .secondary)
                        HealthFact(title: "Cache hits",
                                   value: health.cacheHitRate.percentString,
                                   symbol: "bolt.horizontal.circle",
                                   color: .secondary)
                        Spacer()
                        if let version = CoreBridge.shared.backendVersion {
                            Text("v\(version)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Runtime health unavailable.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        defer { loading = false }

        let workspace = workspaces.first

        async let activityResult: [TimelineEvent]? = loadActivity(workspace)
        async let healthResult: RuntimeHealth? = loadHealth()
        async let predictionsResult: PredictionsSummary? = loadPredictions()
        async let recommendationsResult: [Recommendation]? = loadRecommendations(workspace)
        async let resumeResult: ResumeContext? = loadResume(workspace)

        let (act, heal, pred, rec, res) = await (
            activityResult, healthResult, predictionsResult, recommendationsResult, resumeResult)

        activity = act ?? []
        health = heal
        predictions = pred
        recommendations = rec ?? []
        resume = res
    }

    private func loadActivity(_ workspace: Workspace?) async -> [TimelineEvent]? {
        guard let workspace else { return [] }
        return try? await CoreBridge.shared.request(
            "get_recent_activity",
            params: ["workspace_id": workspace.id],
            as: [TimelineEvent].self)
    }

    private func loadHealth() async -> RuntimeHealth? {
        try? await CoreBridge.shared.request("get_runtime_health", as: RuntimeHealth.self)
    }

    private func loadPredictions() async -> PredictionsSummary? {
        try? await CoreBridge.shared.request("get_predictions_summary", as: PredictionsSummary.self)
    }

    private func loadRecommendations(_ workspace: Workspace?) async -> [Recommendation]? {
        guard let workspace else { return [] }
        return try? await CoreBridge.shared.request(
            "get_workspace_recommendations",
            params: ["workspace_id": workspace.id],
            as: [Recommendation].self)
    }

    private func loadResume(_ workspace: Workspace?) async -> ResumeContext? {
        guard let workspace else { return nil }
        return try? await CoreBridge.shared.request(
            "copilot_get_resume_context",
            params: ["workspace_id": workspace.id],
            as: ResumeContext.self)
    }
}

// MARK: - Supporting views

struct DashboardActivityRow: View {
    let event: TimelineEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: event.eventType.symbol)
                .font(.system(size: 13))
                .foregroundStyle(event.eventType.color)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.displayTitle)
                    .font(.callout)
                    .lineLimit(1)
                if let artifact = event.artifactName {
                    Text(artifact)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(event.occurredAt.relativeTime)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        [event.displayTitle, event.artifactName, event.occurredAt.relativeTime]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

struct HealthFact: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

struct PriorityPill: View {
    let priority: String

    var body: some View {
        Text(priority.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
            .accessibilityLabel("\(priority) priority")
    }

    private var color: Color {
        switch priority.lowercased() {
        case "critical": .red
        case "high": .orange
        case "medium": .yellow
        default: .secondary
        }
    }
}