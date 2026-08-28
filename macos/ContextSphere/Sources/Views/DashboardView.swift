import SwiftUI
import AppKit

/// ContextSphere's flagship screen. Communicates:
/// - "What am I working on?"   → current workspace hero + resume context
/// - "What should I do next?"  → intelligence (predictions + recommendations)
/// - "What changed?"           → recent context (activity + open files)
/// - "Is everything healthy?"  → compact system health strip
///
/// Layout is fully responsive: at narrow widths cards stack into a
/// single column; at medium widths the layout splits into a 2-column
/// grid; at wide widths the system health strip becomes a 4-up metric
/// row alongside the daily briefing.
struct DashboardView: View {
    let workspaces: [Workspace]
    let onRevealWorkspace: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activity: [TimelineEvent] = []
    @State private var health: RuntimeHealth?
    @State private var predictions: PredictionsSummary?
    @State private var recommendations: [Recommendation] = []
    @State private var resume: ResumeContext?
    @State private var lastSession: SessionSummary?
    @State private var briefing: DailyBriefing?
    @State private var loading = true
    @State private var loadErrors: [String] = []
    @State private var actionError: String?
    @State private var isSwitching = false
    @State private var explanation: ExplainablePrediction?
    @State private var explainingId: String?
    @State private var explainError: String?
    @State private var intelligenceRefreshTask: Task<Void, Never>?

    init(workspaces: [Workspace], onRevealWorkspace: @escaping (String) -> Void = { _ in }) {
        self.workspaces = workspaces
        self.onRevealWorkspace = onRevealWorkspace
    }

    private var currentWorkspace: Workspace? {
        workspaces.first { $0.status == .active } ?? workspaces.first
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !loadErrors.isEmpty {
                        loadErrorBanner
                    }
                    if workspaces.isEmpty {
                        emptyWorkspaces
                    } else {
                        hero(width: width)
                        briefingRow(width: width)
                        intelligenceRow(width: width)
                        systemHealth(width: width)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, layoutPadding(for: width))
                .padding(.vertical, 20)
            }
            .scrollEdgeEffectStyle(.soft, for: .vertical)
        }
        .task(id: workspaces.first?.id) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .intelligenceDidChange)) { _ in
            intelligenceRefreshTask?.cancel()
            intelligenceRefreshTask = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                await refreshIntelligence()
            }
        }
        .sheet(isPresented: Binding(get: { explanation != nil },
                                    set: { if !$0 { explanation = nil } })) {
            if let current = explanation {
                ExplanationSheet(explanation: current) { explanation = nil }
            }
        }
    }

    // MARK: - Responsive helpers

    private func layoutPadding(for width: CGFloat) -> CGFloat {
        if width < 760 { return 16 }
        if width < 980 { return 20 }
        if width < 1200 { return 24 }
        return 28
    }

    private func splitRatio(for width: CGFloat) -> CGFloat {
        // 60/40 split, but collapses to full-width under 1100.
        if width < 1100 { return 1.0 }
        if width < 1400 { return 0.58 }
        return 0.62
    }

    private func twoColumn(for width: CGFloat) -> Bool {
        width >= 900
    }

    // MARK: - Empty state

    private var emptyWorkspaces: some View {
        VStack(spacing: 18) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 40, weight: .light))
                .csForeground(CSColor.textTertiary)
            VStack(spacing: 6) {
                Text("Create your first workspace")
                    .font(.title2.weight(.semibold))
                    .csForeground(CSColor.textPrimary)
                Text("ContextSphere learns from the work you do inside a workspace. Create one and it will begin tracking context here.")
                    .font(.callout)
                    .csForeground(CSColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            Button {
                AppRouter.shared.newWorkspaceRequest = true
                AppRouter.shared.selection = .workspaces
            } label: {
                Label("Create Workspace", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityLabel("Create your first workspace")

            VStack(alignment: .leading, spacing: 12) {
                Text("How it works")
                    .font(.csEyebrow())
                    .csForeground(CSColor.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                HStack(alignment: .top, spacing: 12) {
                    firstRunStep(number: "1", title: "Create", detail: "Pick a folder for your project.")
                    firstRunStep(number: "2", title: "Work", detail: "Edit files — Timeline fills automatically.")
                    firstRunStep(number: "3", title: "See", detail: "Graph, Dashboard & briefing light up.")
                }
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.caption2)
                        .csForeground(CSColor.textTertiary)
                    Text("Files are observed locally on this Mac and never uploaded. Watch paths are managed in Settings.")
                        .font(.caption2)
                        .csForeground(CSColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
            .padding(16)
            .frame(maxWidth: 460)
            .background(Color.cs(CSColor.surface), in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                    .strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5)
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityElement(children: .contain)
    }

    private func firstRunStep(number: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(number)
                .font(.caption2.weight(.bold))
                .csForeground(CSColor.textOnAccent)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
                .accessibilityHidden(true)
            Text(title)
                .font(.caption.weight(.semibold))
                .csForeground(CSColor.textPrimary)
            Text(detail)
                .font(.caption2)
                .csForeground(CSColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Load error banner

    private var loadErrorBanner: some View {
        StatusBanner(
            message: "\(loadErrors.count) panel\(loadErrors.count == 1 ? "" : "s") couldn't load",
            style: .warning,
            detail: loadErrors.joined(separator: "\n"),
            primaryAction: ("Retry", { Task { await load() } }),
            secondaryAction: ("Dismiss", { loadErrors = [] })
        )
    }

    // MARK: - Hero (full width)

    private func hero(width: CGFloat) -> some View {
        HeroCard {
            if let workspace = currentWorkspace {
                if width < 900 {
                    VStack(alignment: .leading, spacing: 16) {
                        workspaceIdentity(workspace)
                        Hairline()
                        HStack(alignment: .top, spacing: 18) {
                            healthGauge(workspace)
                            actionColumn(workspace)
                        }
                        if let actionError {
                            StatusBanner(message: "Action failed", style: .error, detail: actionError)
                        }
                        if let resume, !resume.unfinishedWork.isEmpty {
                            unfinishedWorkList(resume.unfinishedWork)
                        } else if let session = lastSession,
                                  session.workspaceId != currentWorkspace?.id {
                            lastSessionRow(session)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 18) {
                            workspaceIdentity(workspace)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Spacer(minLength: 16)
                            healthGauge(workspace)
                            actionColumn(workspace)
                        }
                        if let actionError {
                            StatusBanner(message: "Action failed", style: .error, detail: actionError)
                        }
                        if let resume, !resume.unfinishedWork.isEmpty {
                            Hairline()
                            unfinishedWorkList(resume.unfinishedWork)
                        } else if let session = lastSession,
                                  session.workspaceId != currentWorkspace?.id {
                            Hairline()
                            lastSessionRow(session)
                        }
                    }
                }
            }
        }
        .animation(Theme.spring(reduceMotion), value: resume?.unfinishedWork.count)
        .accessibilityElement(children: .contain)
    }

    private func workspaceIdentity(_ workspace: Workspace) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.5)
                    )
                Image(systemName: "folder.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .frame(width: 42, height: 42)
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(workspace.name)
                        .font(.title3.weight(.semibold))
                        .csForeground(CSColor.textPrimary)
                        .lineLimit(1)
                    if workspace.status == .active {
                        CSStatusBadge(text: "Active", kind: .success)
                    }
                }
                if let path = workspace.rootPath, !path.isEmpty {
                    Text(path)
                        .font(.callout)
                        .csForeground(CSColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if let description = workspace.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .csForeground(CSColor.textSecondary)
                        .lineLimit(2)
                }
                if let openFiles = resume?.openFiles, !openFiles.isEmpty {
                    HStack(spacing: 6) {
                        Text("Open")
                            .font(.caption2)
                            .csForeground(CSColor.textTertiary)
                            .textCase(.uppercase)
                            .tracking(0.5)
                        ForEach(openFiles.prefix(3), id: \.self) { file in
                            HStack(spacing: 3) {
                                Image(systemName: "doc")
                                    .font(.caption2)
                                    .csForeground(CSColor.textSecondary)
                                Text((file as NSString).lastPathComponent)
                                    .font(.caption)
                                    .csForeground(CSColor.textSecondary)
                                    .lineLimit(1)
                            }
                            .help(file)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func healthGauge(_ workspace: Workspace) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.cs(CSColor.textTertiary).opacity(0.15), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: max(0.02, workspace.healthScore / 100))
                    .stroke(healthColor(workspace.healthScore),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Theme.spring(reduceMotion), value: workspace.healthScore)
                VStack(spacing: 0) {
                    Text("\(Int(workspace.healthScore))")
                        .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                        .csForeground(CSColor.textPrimary)
                    Text("Health")
                        .font(.system(size: 9, weight: .medium))
                        .csForeground(CSColor.textSecondary)
                }
            }
            .frame(width: 64, height: 64)
            .accessibilityLabel("Workspace health \(Int(workspace.healthScore)) percent")
        }
    }

    private func healthColor(_ score: Double) -> Color {
        if score >= 70 { return Color.cs(CSColor.success) }
        if score >= 40 { return Color.cs(CSColor.warning) }
        return Color.cs(CSColor.error)
    }

    private func actionColumn(_ workspace: Workspace) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button {
                Task { await switchToWorkspace(id: workspace.id, name: workspace.name) }
            } label: {
                HStack(spacing: 6) {
                    if isSwitching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    Text(isSwitching ? "Switching…" : "Resume")
                }
                .frame(minWidth: 100)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(isSwitching)
            .accessibilityHint("Makes this the active workspace and restores its context")

            Text("Active \(workspace.lastActiveAt.relativeTime)")
                .font(.caption2)
                .csForeground(CSColor.textTertiary)
        }
    }

    private func unfinishedWorkList(_ items: [UnfinishedWork]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                    .font(.system(size: 11, weight: .semibold))
                    .csForeground(CSColor.textSecondary)
                Text("Unfinished work")
                    .font(.csEyebrow())
                    .csForeground(CSColor.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
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
                            .csForeground(CSColor.textPrimary)
                        HStack(spacing: 6) {
                            if let file = item.filePath {
                                Text((file as NSString).lastPathComponent)
                                    .font(.caption2)
                                    .csForeground(CSColor.textSecondary)
                            }
                            Text("· \(item.confidence.percentString) confidence")
                                .font(.caption2)
                                .csForeground(CSColor.textTertiary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.description), \(item.confidence.percentString) confidence")
            }
        }
    }

    // MARK: - Daily briefing (full width, then system health)

    private func briefingRow(width: CGFloat) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Daily Briefing",
                              subtitle: briefing?.greeting,
                              symbol: "sun.max")
                if let briefing {
                    HStack(spacing: 10) {
                        briefingStat(briefing.summary.durationSeconds >= 3600
                                     ? "\(briefing.summary.durationSeconds / 3600) h active"
                                     : "\(max(briefing.summary.durationSeconds / 60, 0)) min active",
                                     symbol: "clock")
                        briefingStat("\(briefing.summary.sessionCount) sessions",
                                     symbol: "rectangle.stack")
                        if let lang = briefing.primaryLanguage ?? briefing.summary.primaryLanguage {
                            briefingStat(lang, symbol: "chevron.left.forwardslash.chevron.right")
                        }
                        Spacer()
                    }
                    if !briefing.insights.isEmpty {
                        Hairline()
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(briefing.insights.prefix(3).enumerated()),
                                    id: \.offset) { _, insight in
                                Label(insight, systemImage: "sparkle")
                                    .font(.callout)
                                    .csForeground(CSColor.textPrimary)
                            }
                        }
                    }
                    if !briefing.suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(briefing.suggestions.prefix(2).enumerated()),
                                    id: \.offset) { _, suggestion in
                                Label(suggestion, systemImage: "lightbulb")
                                    .font(.caption)
                                    .csForeground(CSColor.textSecondary)
                            }
                        }
                    }
                } else if !loadErrors.contains(where: { $0.hasPrefix("Daily briefing") }) {
                    Text("Your day at a glance will appear here once there is some activity.")
                        .font(.callout)
                        .csForeground(CSColor.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func briefingStat(_ text: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.caption.weight(.medium))
        }
        .csForeground(CSColor.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.cs(CSColor.textTertiary).opacity(0.09),
                    in: Capsule(style: .continuous))
        .overlay(Capsule().strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5))
    }

    // MARK: - Intelligence + Recent Context

    private func intelligenceRow(width: CGFloat) -> some View {
        if twoColumn(for: width) {
            return AnyView(
                HStack(alignment: .top, spacing: 16) {
                    intelligencePanel
                        .frame(maxWidth: .infinity)
                    recentContextPanel
                        .frame(maxWidth: .infinity)
                }
            )
        } else {
            return AnyView(
                VStack(alignment: .leading, spacing: 16) {
                    intelligencePanel
                    recentContextPanel
                }
            )
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
                        .csForeground(CSColor.textSecondary)
                }

                if !recommendations.isEmpty {
                    Hairline()
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
                    .font(.caption2)
                    .csForeground(CSColor.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Text(prediction.workspaceName)
                    .font(.callout.weight(.semibold))
                    .csForeground(CSColor.textPrimary)
                Text(prediction.reason)
                    .font(.caption2)
                    .csForeground(CSColor.textTertiary)
            }
            Spacer()
            Text(prediction.confidence.percentString)
                .font(.caption.monospacedDigit())
                .csForeground(CSColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Next workspace: \(prediction.workspaceName). \(prediction.reason). Confidence \(prediction.confidence.percentString)")
    }

    private func sessionContinuationBlock(_ continuation: SessionContinuationPrediction) -> some View {
        HStack(spacing: 10) {
            Image(systemName: continuation.willContinue ? "play.circle.fill" : "pause.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .csForeground(continuation.willContinue ? CSColor.success : CSColor.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(continuation.willContinue ? "Session continuation expected" : "Session winding down")
                    .font(.callout.weight(.medium))
                    .csForeground(CSColor.textPrimary)
                Text(continuation.reason)
                    .font(.caption2)
                    .csForeground(CSColor.textTertiary)
            }
            Spacer()
            if continuation.willContinue {
                Text("≈ \(Duration.seconds(Double(continuation.estimatedDurationSeconds)).formatted(.units(allowed: [.minutes])))")
                    .font(.caption.monospacedDigit())
                    .csForeground(CSColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(continuation.willContinue ? "Session continuation expected" : "Session winding down"). \(continuation.reason)")
    }

    private func nextFilesBlock(_ files: [FilePrediction]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Likely files")
                .font(.caption2)
                .csForeground(CSColor.textTertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            ForEach(files) { file in
                Button {
                    openPredictedFile(file.filePath)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .font(.caption2)
                            .csForeground(CSColor.textSecondary)
                            .frame(width: 14)
                        Text((file.filePath as NSString).lastPathComponent)
                            .font(.callout)
                            .lineLimit(1)
                            .csForeground(CSColor.textPrimary)
                        Spacer()
                        Text(file.confidence.percentString)
                            .font(.caption2.monospacedDigit())
                            .csForeground(CSColor.textTertiary)
                        Image(systemName: "arrow.up.forward.app")
                            .font(.caption2)
                            .csForeground(CSColor.textTertiary)
                    }
                    .padding(.vertical, 3)
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
            do {
                try await CoreBridge.shared.call("open_file", params: ["path": path])
            } catch {
                await MainActor.run { actionError = "Could not open \((path as NSString).lastPathComponent): \(error.localizedDescription)" }
            }
        }
    }

    private var recommendationsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recommended")
                .font(.caption2)
                .csForeground(CSColor.textTertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            ForEach(recommendations.prefix(3)) { recommendation in
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        onRevealWorkspace(recommendation.workspaceId)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            PriorityPill(priority: recommendation.priority)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recommendation.title)
                                    .font(.callout.weight(.medium))
                                    .csForeground(CSColor.textPrimary)
                                    .multilineTextAlignment(.leading)
                                Text(recommendation.description)
                                    .font(.caption)
                                    .csForeground(CSColor.textSecondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        Task { await loadExplanation(for: recommendation) }
                    } label: {
                        if explainingId == recommendation.id {
                            ProgressView().controlSize(.mini)
                        } else {
                            Label("Why", systemImage: "questionmark.circle")
                                .labelStyle(.titleAndIcon)
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Explain why this is recommended")
                    .accessibilityLabel("Explain recommendation: \(recommendation.title)")
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(recommendation.priority) priority: \(recommendation.title). \(recommendation.description)")
                if explainError != nil && explainingId == recommendation.id {
                    Text(explainError!)
                        .font(.caption2)
                        .csForeground(CSColor.warning)
                }
            }
        }
    }

    private var recentContextPanel: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Recent Context",
                              subtitle: "What changed?",
                              symbol: "clock.arrow.circlepath")

                if activity.isEmpty {
                    Text("No activity recorded yet in \(currentWorkspace?.name ?? "this workspace").")
                        .font(.callout)
                        .csForeground(CSColor.textSecondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(activity.prefix(6).enumerated()), id: \.element.id) { index, event in
                            DashboardActivityRow(event: event)
                            if index < min(activity.count, 6) - 1 {
                                Hairline()
                            }
                        }
                    }
                }

                if let resume, !resume.openFiles.isEmpty {
                    Hairline()
                    Label("\(resume.openFiles.count) files open",
                          systemImage: "doc.on.doc")
                        .font(.caption)
                        .csForeground(CSColor.textSecondary)
                }
            }
        }
    }

    // MARK: - System health

    private func systemHealth(width: CGFloat) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "System Health",
                              subtitle: "Status at a glance",
                              symbol: "waveform.path.ecg")

                if let health {
                    let columns: Int = width < 900 ? 2 : 4
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16),
                                             count: columns), alignment: .leading, spacing: 12) {
                        HealthFact(title: "System",
                                   value: health.isHealthy ? "Healthy" : health.status.capitalized,
                                   symbol: "checkmark.circle.fill",
                                   color: health.isHealthy ? Color.cs(CSColor.success) : Color.cs(CSColor.warning))
                        HealthFact(title: "Uptime",
                                   value: Duration.seconds(Double(health.uptimeSeconds)).formatted(.units(allowed: [.hours, .minutes])),
                                   symbol: "clock",
                                   color: Color.cs(CSColor.textSecondary))
                        HealthFact(title: "Workers",
                                   value: "\(health.workersActive)",
                                   symbol: "person.2",
                                   color: Color.cs(CSColor.textSecondary))
                        HealthFact(title: "Cache hits",
                                   value: health.cacheHitRate.percentString,
                                   symbol: "bolt.horizontal.circle",
                                   color: Color.cs(CSColor.textSecondary))
                    }
                    if let version = CoreBridge.shared.backendVersion {
                        HStack {
                            Spacer()
                            Text("v\(version)")
                                .font(.caption.monospacedDigit())
                                .csForeground(CSColor.textTertiary)
                        }
                    }
                } else {
                    Text("Runtime health unavailable.")
                        .font(.callout)
                        .csForeground(CSColor.textSecondary)
                }
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        defer { loading = false }
        loadErrors = []

        let workspace = workspaces.first

        async let activityResult: [TimelineEvent]? = loadActivity(workspace)
        async let healthResult: RuntimeHealth? = loadHealth()
        async let predictionsResult: PredictionsSummary? = loadPredictions()
        async let recommendationsResult: [Recommendation]? = loadRecommendations(workspace)
        async let resumeResult: ResumeContext? = loadResume(workspace)
        async let sessionResult: SessionSummary? = loadLastSession()
        async let briefingResult: DailyBriefing? = loadBriefing()

        let (act, heal, pred, rec, res, sess, brief) = await (
            activityResult, healthResult, predictionsResult, recommendationsResult, resumeResult,
            sessionResult, briefingResult)

        activity = act ?? []
        health = heal
        predictions = pred
        recommendations = rec ?? []
        resume = res
        lastSession = sess
        briefing = brief
    }

    private func recordLoadError(_ panel: String, _ error: Error) {
        loadErrors.append("\(panel): \(error.localizedDescription)")
    }

    private func loadActivity(_ workspace: Workspace?) async -> [TimelineEvent]? {
        guard let workspace else { return [] }
        do {
            return try await CoreBridge.shared.request(
                "get_recent_activity",
                params: ["workspace_id": workspace.id],
                as: [TimelineEvent].self)
        } catch {
            recordLoadError("Recent activity", error)
            return nil
        }
    }

    private func loadHealth() async -> RuntimeHealth? {
        do {
            return try await CoreBridge.shared.request("get_runtime_health", as: RuntimeHealth.self)
        } catch {
            recordLoadError("System health", error)
            return nil
        }
    }

    private func loadPredictions() async -> PredictionsSummary? {
        do {
            return try await CoreBridge.shared.request("get_predictions_summary", as: PredictionsSummary.self)
        } catch {
            recordLoadError("Predictions", error)
            return nil
        }
    }

    private func loadRecommendations(_ workspace: Workspace?) async -> [Recommendation]? {
        guard let workspace else { return [] }
        do {
            return try await CoreBridge.shared.request(
                "get_workspace_recommendations",
                params: ["workspace_id": workspace.id],
                as: [Recommendation].self)
        } catch {
            recordLoadError("Recommendations", error)
            return nil
        }
    }

    private func loadResume(_ workspace: Workspace?) async -> ResumeContext? {
        guard let workspace else { return nil }
        do {
            return try await CoreBridge.shared.request(
                "copilot_get_resume_context",
                params: ["workspace_id": workspace.id],
                as: ResumeContext.self)
        } catch {
            recordLoadError("Resume context", error)
            return nil
        }
    }

    private func loadLastSession() async -> SessionSummary? {
        do {
            return try await CoreBridge.shared.request(
                "get_smart_resume_session",
                as: SessionSummary?.self)
        } catch {
            recordLoadError("Smart resume", error)
            return nil
        }
    }

    private func loadExplanation(for recommendation: Recommendation) async {
        explainingId = recommendation.id
        explainError = nil
        do {
            let result: ExplainablePrediction = try await CoreBridge.shared.request(
                "explain_recommendation",
                params: [
                    "workspace_id": recommendation.workspaceId,
                    "recommendation_id": recommendation.id,
                ],
                as: ExplainablePrediction.self)
            explanation = result
            if explainError?.isEmpty != false { explainError = nil }
        } catch {
            explainError = error.localizedDescription
        }
        explainingId = nil
    }

    private func refreshIntelligence() async {
        loadErrors.removeAll { $0.hasPrefix("Predictions")
            || $0.hasPrefix("Recommendations")
            || $0.hasPrefix("Daily briefing") }
        async let pred: PredictionsSummary? = loadPredictions()
        async let recs: [Recommendation]? = loadRecommendations(currentWorkspace)
        async let brief: DailyBriefing? = loadBriefing()
        let (p, r, b) = await (pred, recs, brief)
        if Task.isCancelled { return }
        predictions = p
        recommendations = r ?? []
        briefing = b
    }

    private func loadBriefing() async -> DailyBriefing? {
        do {
            return try await CoreBridge.shared.request("get_daily_briefing", as: DailyBriefing.self)
        } catch {
            recordLoadError("Daily briefing", error)
            return nil
        }
    }

    // MARK: - Workspace switching

    private func switchToWorkspace(id: String, name: String) async {
        isSwitching = true
        defer { isSwitching = false }
        do {
            try await CoreBridge.shared.call("switch_workspace", params: ["id": id])
            actionError = nil
            NotificationCenter.default.post(name: .workspacesDidChange, object: nil)
        } catch {
            actionError = "Could not resume \(name): \(error.localizedDescription)"
        }
    }

    private func lastSessionRow(_ session: SessionSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Resume last session in \(session.workspaceName)")
                    .font(.callout.weight(.medium))
                    .csForeground(CSColor.textPrimary)
                Text(Self.lastSessionDetail(session))
                    .font(.caption)
                    .csForeground(CSColor.textSecondary)
            }
            Spacer()
            Button("Switch") {
                Task { await switchToWorkspace(id: session.workspaceId,
                                               name: session.workspaceName) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isSwitching)
            .accessibilityLabel("Switch to \(session.workspaceName) to resume your last session")
        }
        .accessibilityElement(children: .contain)
    }

    private static func lastSessionDetail(_ session: SessionSummary) -> String {
        let minutes = max(session.durationSeconds / 60, 0)
        let duration = minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
        var parts = ["\(duration)", "\(session.fileCount) file\(session.fileCount == 1 ? "" : "s")"]
        if !session.languages.isEmpty {
            parts.append(session.languages.prefix(3).joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Supporting views

struct ExplanationSheet: View {
    let explanation: ExplainablePrediction
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label("Why this recommendation", systemImage: "questionmark.circle")
                    .font(.headline)
                    .csForeground(CSColor.textPrimary)
                Spacer()
                Text("confidence \(Int((explanation.confidence * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .csForeground(CSColor.textSecondary)
            }
            Text(explanation.explanation)
                .font(.callout)
                .csForeground(CSColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if !explanation.supportingEvidence.isEmpty {
                Hairline()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Supporting evidence")
                        .font(.caption.weight(.semibold))
                        .csForeground(CSColor.textSecondary)
                    ForEach(explanation.supportingEvidence.prefix(6)) { evidence in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.seal")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                                .padding(.top, 2)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(evidence.description)
                                    .font(.callout)
                                    .csForeground(CSColor.textPrimary)
                                Text("\(evidence.source) · \(Int((evidence.confidence * 100).rounded()))%")
                                    .font(.caption2)
                                    .csForeground(CSColor.textTertiary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if !explanation.sourceEngines.isEmpty {
                Text("Sources: \(explanation.sourceEngines.joined(separator: ", "))")
                    .font(.caption2)
                    .csForeground(CSColor.textTertiary)
            }

            HStack {
                Spacer()
                Button("Done") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, alignment: .leading)
    }
}

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
                    .csForeground(CSColor.textPrimary)
                    .lineLimit(1)
                if let artifact = event.artifactName {
                    Text(artifact)
                        .font(.caption)
                        .csForeground(CSColor.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(event.occurredAt.relativeTime)
                .font(.caption2)
                .csForeground(CSColor.textTertiary)
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
                    .font(.caption2)
                    .csForeground(CSColor.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Text(value)
                    .font(.callout.weight(.medium))
                    .csForeground(CSColor.textPrimary)
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
            .csForeground(token)
            .accessibilityLabel("\(priority) priority")
    }

    private var color: Color {
        switch priority.lowercased() {
        case "critical": Color.cs(CSColor.error)
        case "high":     Color.cs(CSColor.warning)
        case "medium":   Color.cs(CSColor.warning)
        default:         Color.cs(CSColor.textSecondary)
        }
    }

    private var token: String {
        switch priority.lowercased() {
        case "critical": CSColor.error
        case "high":     CSColor.warning
        case "medium":   CSColor.warning
        default:         CSColor.textSecondary
        }
    }
}
