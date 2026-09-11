import SwiftUI
import AppKit

/// Redesigned Dashboard — information hierarchy:
/// PRIMARY:   What am I working on?      → current workspace identity
/// SECONDARY: How confident / can I resume? → Resume Context + Intelligence
/// TERTIARY:  Why does it think this?    → Signals & evidence (progressive disclosure)
/// SUPPORTING: Activity & recent context → metrics, timeline, memory
///
/// All data is live via ActivityViewModel. No fake numbers — empty states are honest.
@MainActor
struct DashboardView: View {
    let workspaces: [Workspace]
    let onRevealWorkspace: (String) -> Void
    @ObservedObject var activity: ActivityViewModel
    @ObservedObject var intelligence: WorkspaceIntelligenceViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var containerWidth: CGFloat = 1024

    init(workspaces: [Workspace], onRevealWorkspace: @escaping (String) -> Void = { _ in }, activity: ActivityViewModel, intelligence: WorkspaceIntelligenceViewModel) {
        self.workspaces = workspaces
        self.onRevealWorkspace = onRevealWorkspace
        self.activity = activity
        self.intelligence = intelligence
    }

    // Convenience for preview / test
    init(workspaces: [Workspace], onRevealWorkspace: @escaping (String) -> Void = { _ in }) {
        self.workspaces = workspaces
        self.onRevealWorkspace = onRevealWorkspace
        self.activity = ActivityViewModel()
        self.intelligence = WorkspaceIntelligenceViewModel()
    }

    private var currentWorkspace: Workspace? {
        workspaces.first { $0.status == .active } ?? workspaces.first
    }

    /// Usable width for dashboard content within the scroll view.
    private var usableContentWidth: CGFloat {
        let hPadding = dashboardPadding(for: containerWidth) * 2
        let available = containerWidth - hPadding
        return min(max(0, available), Theme.dashboardContentMaxWidth)
    }

    /// Minimum width required for each card to be comfortably readable (~360pt).
    private static let minIntelligenceCardWidth: CGFloat = 360
    private static let intelligenceCardSpacing: CGFloat = 14
    /// Total width required to display both cards side-by-side: (360 * 2) + 14 = 734pt.
    private static let minTwoColumnWidth: CGFloat = (minIntelligenceCardWidth * 2) + intelligenceCardSpacing

    /// Two-column layout is active only when available content width can provide >= 360pt to each column.
    private var useTwoColumnIntelligence: Bool {
        usableContentWidth >= Self.minTwoColumnWidth
    }

    /// Today's timeline only earns the half-width column when it has sessions.
    private var hasTimelineSessions: Bool {
        if let ov = activity.overview { return !ov.sessions.isEmpty }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            dashboardHeader
                .padding(.horizontal, dashboardPadding(for: containerWidth))
                .padding(.vertical, Theme.pageHeaderVerticalPadding)
            Hairline(opacity: Theme.pageHeaderDividerOpacity)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if workspaces.isEmpty {
                        emptyWorkspaces
                    } else {
                        // PRIMARY: Current workspace identity (compact)
                        workspaceIdentityRow

                        // SECONDARY: Resume Context + Workspace Intelligence
                        intelligenceSection

                        // SUPPORTING: Activity metrics
                        activityOverview(width: containerWidth)

                        // DETAIL: What happened + Timeline
                        if containerWidth >= 980, hasTimelineSessions {
                            HStack(alignment: .top, spacing: 14) {
                                whatHappenedColumn.frame(maxWidth: .infinity)
                                timelineHeatColumn.frame(maxWidth: .infinity)
                            }
                        } else {
                            VStack(spacing: 14) {
                                whatHappenedColumn
                                timelineHeatColumn
                            }
                        }

                        // SUPPORTING: Recent workspaces + memory
                        if containerWidth >= 980 {
                            HStack(alignment: .top, spacing: 14) {
                                recentWorkspacesCard.frame(maxWidth: .infinity)
                                recentMemoryCard.frame(maxWidth: .infinity)
                            }
                        } else {
                            VStack(spacing: 14) {
                                recentWorkspacesCard
                                recentMemoryCard
                            }
                        }
                    }
                }
                .frame(maxWidth: Theme.dashboardContentMaxWidth)
                .padding(.horizontal, dashboardPadding(for: containerWidth))
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(.automatic)
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .defaultScrollAnchor(.top)
        }
        .overlay {
            GeometryReader { geo in
                Color.clear
                    .onAppear { containerWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in
                        let delta = abs(new - containerWidth)
                        if delta > 1 { containerWidth = new }
                    }
            }
            .frame(height: 0)
        }
        .task { activity.setWorkspaces(workspaces); activity.refresh() }
        .onChange(of: workspaces) { _, new in activity.setWorkspaces(new) }
    }

    private var dashboardHeader: some View {
        StandardPageHeader(
            section: .dashboard,
            activeWorkspace: currentWorkspace,
            title: "Dashboard",
            subtitle: "Here's what ContextSphere remembers about your work.",
            symbol: AppSection.dashboard.symbol,
            eyebrow: NavGroup.workspace.title.uppercased()
        ) {
            dashboardSwitchControl
        }
    }

    private var dashboardSwitchControl: some View {
        Menu {
            if !workspaces.isEmpty {
                ForEach(workspaces.prefix(8)) { workspace in
                    Button {
                        Task { await switchTo(workspace) }
                    } label: {
                        Label(workspace.name,
                              systemImage: workspace.status == .active
                                ? "checkmark.circle.fill"
                                : "folder")
                    }
                }
                Divider()
                Button("All Workspaces…") {
                    AppRouter.shared.selection = .workspaces
                }
            } else {
                Button("Create your first workspace") {
                    AppRouter.shared.selection = .workspaces
                    AppRouter.shared.newWorkspaceRequest = true
                }
            }
        } label: {
            Label("Switch Workspace", systemImage: "rectangle.2.swap")
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Switch Workspace")
        .accessibilityHint("Opens workspace switcher")
        .help("Switch active workspace")
    }

    private func switchTo(_ workspace: Workspace) async {
        do {
            try await CoreBridge.shared.call("switch_workspace", params: ["id": workspace.id])
            await MainActor.run {
                AppRouter.shared.reloadRequest = true
            }
        } catch {
        }
    }

    private func dashboardPadding(for width: CGFloat) -> CGFloat {
        Theme.horizontalPadding(for: width)
    }

    // MARK: - Workspace Identity (compact hero replacement)

    private var workspaceIdentityRow: some View {
        HStack(alignment: .center, spacing: 12) {
            // Workspace icon
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.5)
                    )
                Image(systemName: "folder.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)

            // Workspace name + status
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(currentWorkspace?.name ?? "No workspace")
                        .font(.csSectionTitle)
                        .csForeground(CSColor.textPrimary)
                    if currentWorkspace?.status == .active {
                        CSStatusBadge(text: "Active", kind: .success)
                    }
                }
                HStack(spacing: 8) {
                    if let ov = activity.overview, !ov.isEmpty {
                        Label(formatDuration(ov.day.activeSeconds), systemImage: "clock")
                            .font(.csTiny)
                            .csForeground(CSColor.textSecondary)
                        Text("·")
                            .csForeground(CSColor.textTertiary)
                        Label("\(ov.day.focusSessions) sessions today", systemImage: "rectangle.stack")
                            .font(.csTiny)
                            .csForeground(CSColor.textSecondary)
                    } else {
                        Label("No activity yet", systemImage: "clock")
                            .font(.csTiny)
                            .csForeground(CSColor.textSecondary)
                    }
                }
            }

            Spacer(minLength: 8)

            // Activity button
            Button { AppRouter.shared.selection = .activity } label: {
                HStack(spacing: 5) {
                    Image(systemName: "waveform.path.ecg")
                    Text("Activity")
                }
                .font(.csTiny.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("View activity")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            Color.cs(CSColor.surface).opacity(0.90),
            in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                .strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.04), radius: 10, y: 3)
    }

    // MARK: - Intelligence Section (Resume + Signals)

    @ViewBuilder
    private var intelligenceSection: some View {
        let hasResume = intelligence.smartResumeContext.map { $0.isResumable } ?? false
        let hasIntel = intelligence.activeInference?.active != nil
            || intelligence.allWorkspacesIntelligence.first(where: { $0.workspaceId == currentWorkspace?.id }) != nil

        if hasResume || hasIntel {
            if useTwoColumnIntelligence, hasResume, hasIntel {
                // Side by side: equal-width columns (>= 360pt each), robust 50/50 balance
                HStack(alignment: .top, spacing: Self.intelligenceCardSpacing) {
                    if let resumeContext = intelligence.smartResumeContext, resumeContext.isResumable {
                        ContextContinuityCard(
                            context: resumeContext,
                            onResume: { action in
                                Task { await intelligence.executeResumeAction(action) }
                            },
                            onSnapshot: {
                                Task { await intelligence.snapshotEpisode(for: resumeContext.workspaceId) }
                            }
                        )
                        .frame(minWidth: Self.minIntelligenceCardWidth, maxWidth: .infinity)
                    }
                    if let activeIntel = intelligence.activeInference?.active ?? intelligence.allWorkspacesIntelligence.first(where: { $0.workspaceId == currentWorkspace?.id }) {
                        WorkspaceIntelligenceCard(
                            intelligence: activeIntel,
                            onResumeEpisode: {
                                Task { await intelligence.resumeEpisode(workspaceId: activeIntel.workspaceId) }
                            },
                            onExecuteSuggestion: { suggestion in
                                Task { await intelligence.executeSuggestion(suggestion) }
                            }
                        )
                        .frame(minWidth: Self.minIntelligenceCardWidth, maxWidth: .infinity)
                    }
                }
            } else {
                // Stacked: each card receives full available width
                VStack(spacing: 14) {
                    if let resumeContext = intelligence.smartResumeContext, resumeContext.isResumable {
                        ContextContinuityCard(
                            context: resumeContext,
                            onResume: { action in
                                Task { await intelligence.executeResumeAction(action) }
                            },
                            onSnapshot: {
                                Task { await intelligence.snapshotEpisode(for: resumeContext.workspaceId) }
                            }
                        )
                        .frame(maxWidth: .infinity)
                    }
                    if let activeIntel = intelligence.activeInference?.active ?? intelligence.allWorkspacesIntelligence.first(where: { $0.workspaceId == currentWorkspace?.id }) {
                        WorkspaceIntelligenceCard(
                            intelligence: activeIntel,
                            onResumeEpisode: {
                                Task { await intelligence.resumeEpisode(workspaceId: activeIntel.workspaceId) }
                            },
                            onExecuteSuggestion: { suggestion in
                                Task { await intelligence.executeSuggestion(suggestion) }
                            }
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    // MARK: - Activity Overview

    private func activityOverview(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Activity overview", symbol: "waveform.path.ecg")
                Spacer()
                Button("View details →") { AppRouter.shared.selection = .activity }
                    .font(.csTiny.weight(.medium)).buttonStyle(.plain).csForeground(CSColor.info)
                    .accessibilityLabel("View activity details")
            }
            if let ov = activity.overview, !ov.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        dashboardMetricTile(label: "ACTIVE TIME", value: formatDuration(ov.day.activeSeconds), symbol: "clock.fill")
                        dashboardMetricTile(label: "SESSIONS", value: "\(ov.day.focusSessions)", symbol: "rectangle.stack.fill")
                        dashboardMetricTile(label: "APPS", value: "\(ov.day.applications)", symbol: "app.fill")
                        dashboardMetricTile(label: "WEBSITES", value: "\(ov.day.websites)", symbol: "globe")
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        dashboardMetricTile(label: "ACTIVE TIME", value: formatDuration(ov.day.activeSeconds), symbol: "clock.fill")
                        dashboardMetricTile(label: "SESSIONS", value: "\(ov.day.focusSessions)", symbol: "rectangle.stack.fill")
                        dashboardMetricTile(label: "APPS", value: "\(ov.day.applications)", symbol: "app.fill")
                        dashboardMetricTile(label: "WEBSITES", value: "\(ov.day.websites)", symbol: "globe")
                    }
                }
                ActivityMiniHeat(hourlyActivity: ov.hourlyActivity)
            } else if activity.isLoading {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.cs(CSColor.surface).opacity(0.6))
                                .frame(height: 62)
                                .redacted(reason: .placeholder)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.cs(CSColor.surface).opacity(0.6))
                                .frame(height: 62)
                                .redacted(reason: .placeholder)
                        }
                    }
                }
            } else {
                ContentCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Not enough activity yet")
                            .font(.csCardTitle)
                            .csForeground(CSColor.textPrimary)
                        Text("Active time, sessions, apps and websites will appear here once ContextSphere observes real work.")
                            .font(.csMetadata)
                            .csForeground(CSColor.textSecondary)
                        Button("Go to Activity") { AppRouter.shared.selection = .activity }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func dashboardMetricTile(label: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .csForeground(CSColor.textTertiary)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.5)
                    .csForeground(CSColor.textTertiary)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(value)
                .font(.csMetric(size: 22))
                .csForeground(CSColor.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Color.cs(CSColor.surface).opacity(0.90),
            in: RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous)
                .strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds <= 0 { return "—" }
        if seconds < 60 { return "\(seconds)s" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    // MARK: - What Happened

    private var whatHappenedColumn: some View {
        Group {
            if let ov = activity.overview, let wh = ov.whatHappened {
                ContentCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                            Text("WHAT HAPPENED?")
                                .font(.csEyebrow(size: 12))
                                .tracking(0.6)
                                .csForeground(CSColor.textPrimary)
                                .textCase(.uppercase)
                            Spacer()
                            Text(wh.dateLabel)
                                .font(.csTiny.weight(.medium))
                                .csForeground(CSColor.textSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.cs(CSColor.textTertiary).opacity(0.10)))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(wh.title)
                                .font(.system(size: 15, weight: .semibold))
                                .tracking(-0.2)
                                .csForeground(CSColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(wh.summary)
                                .font(.csMetadata)
                                .csForeground(CSColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("APPS")
                                    .font(.csSmallLabel)
                                    .tracking(0.5)
                                    .csForeground(CSColor.textTertiary)
                                    .textCase(.uppercase)
                                Text(wh.apps.map { $0.joined(separator: " ") }.joined(separator: " · "))
                                    .font(.csTiny)
                                    .csForeground(CSColor.textSecondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            VStack(alignment: .leading, spacing: 3) {
                                Text("FILES")
                                    .font(.csSmallLabel)
                                    .tracking(0.5)
                                    .csForeground(CSColor.textTertiary)
                                    .textCase(.uppercase)
                                Text("\(wh.files)")
                                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                                    .csForeground(CSColor.textPrimary)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("SESSIONS")
                                    .font(.csSmallLabel)
                                    .tracking(0.5)
                                    .csForeground(CSColor.textTertiary)
                                    .textCase(.uppercase)
                                Text("\(wh.sessions)")
                                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                                    .csForeground(CSColor.textPrimary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous)
                                .fill(Color.cs(CSColor.surfaceElevated).opacity(0.7))
                        )
                        if let outcome = wh.outcome {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 5) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.cs(CSColor.success))
                                        .accessibilityHidden(true)
                                    Text("Outcome")
                                        .font(.csSmallLabel)
                                        .csForeground(CSColor.textSecondary)
                                        .textCase(.uppercase)
                                        .tracking(0.5)
                                }
                                Text(outcome)
                                    .font(.csMetadata)
                                    .csForeground(CSColor.textPrimary)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 5) {
                                    Image(systemName: "info.circle")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.cs(CSColor.textSecondary))
                                        .accessibilityHidden(true)
                                    Text("Note")
                                        .font(.csSmallLabel)
                                        .csForeground(CSColor.textSecondary)
                                        .textCase(.uppercase)
                                        .tracking(0.5)
                                }
                                Text("ContextSphere found activity related to \(wh.workspace), but there is not enough evidence to determine what was completed.")
                                    .font(.csMetadata)
                                    .csForeground(CSColor.textSecondary)
                            }
                        }
                        Button { AppRouter.shared.selection = .activity } label: {
                            Label("View activity", systemImage: "waveform.path.ecg")
                                .font(.csTiny.weight(.medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityLabel("View activity")
                    }
                }
            } else {
                ContentCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "What Happened?", symbol: "clock.arrow.circlepath")
                        Text("Not enough activity to reconstruct a session yet.")
                            .font(.csMetadata)
                            .csForeground(CSColor.textSecondary)
                        Text("Work for a while in a workspace — ContextSphere will build a What Happened card here.")
                            .font(.csTiny)
                            .csForeground(CSColor.textTertiary)
                    }
                }
            }
        }
    }

    private var timelineHeatColumn: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(
                    title: "Today's timeline",
                    subtitle: activity.overview.map { "\($0.sessions.count) sessions" } ?? "—",
                    symbol: "clock"
                )
                if let ov = activity.overview, !ov.sessions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(ov.sessions.prefix(3)) { session in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 5, height: 5)
                                        .accessibilityHidden(true)
                                    Text(session.timeRange)
                                        .font(.csTiny.weight(.semibold).monospacedDigit())
                                        .csForeground(CSColor.textSecondary)
                                }
                                Text(session.title.capitalized)
                                    .font(.csTiny)
                                    .csForeground(CSColor.textPrimary)
                                    .lineLimit(1)
                                Text("\(session.events.count) events")
                                    .font(.csTiny)
                                    .csForeground(CSColor.textTertiary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.cs(CSColor.surfaceElevated).opacity(0.8))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5)
                            )
                        }
                        Spacer()
                    }
                    Hairline()
                    VStack(spacing: 0) {
                        ForEach(ov.sessions.first?.events.prefix(4) ?? []) { event in
                            HStack(spacing: 6) {
                                Text(event.time)
                                    .font(.csTiny.monospacedDigit())
                                    .csForeground(CSColor.textTertiary)
                                    .frame(width: 36, alignment: .trailing)
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 5, height: 5)
                                    .overlay(Circle().stroke(Color.cs(CSColor.surface), lineWidth: 1))
                                    .accessibilityHidden(true)
                                Text(event.title)
                                    .font(.csTiny.weight(.medium))
                                    .csForeground(CSColor.textPrimary)
                                Text("·")
                                    .csForeground(CSColor.textTertiary)
                                Text(event.subtitle)
                                    .font(.csTiny)
                                    .csForeground(CSColor.textSecondary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    Button("View full timeline →") { AppRouter.shared.selection = .activity }
                        .font(.csTiny.weight(.medium))
                        .buttonStyle(.plain)
                        .csForeground(CSColor.info)
                } else {
                    Text("No sessions today. Timeline will appear here.")
                        .font(.csMetadata)
                        .csForeground(CSColor.textSecondary)
                }
            }
        }
    }

    // MARK: - Recent

    private var recentWorkspacesCard: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Recent workspaces", symbol: "folder")
                VStack(spacing: 4) {
                    ForEach(workspaces.prefix(3)) { ws in
                        HStack(spacing: 8) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(ws.status == .active ? Color.accentColor.opacity(0.14) : Color.cs(CSColor.textTertiary).opacity(0.10))
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(ws.status == .active ? Color.accentColor : Color.cs(CSColor.textSecondary))
                            }
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(ws.name)
                                        .font(.csMetadata.weight(.medium))
                                        .csForeground(CSColor.textPrimary)
                                    if ws.status == .active {
                                        CSStatusBadge(text: "Active", kind: .success)
                                    }
                                }
                                Text(ws.lastActiveAt)
                                    .font(.csTiny)
                                    .csForeground(CSColor.textTertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text("\(Int(ws.healthScore))")
                                .font(.csTiny.weight(.semibold).monospacedDigit())
                                .csForeground(CSColor.textSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.cs(CSColor.textTertiary).opacity(0.08)))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.cs(CSColor.surfaceElevated).opacity(0.6))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5)
                        )
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var recentMemoryCard: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Recent memory", subtitle: "What you worked on", symbol: "brain.head.profile")
                if let ov = activity.overview, !ov.recentMemory.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(ov.recentMemory) { item in
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.cs(CSColor.textTertiary).opacity(0.10))
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.cs(CSColor.textSecondary))
                                }
                                .frame(width: 24, height: 24)
                                .accessibilityHidden(true)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                        .font(.csMetadata.weight(.medium))
                                        .csForeground(CSColor.textPrimary)
                                        .lineLimit(1)
                                    Text(item.subtitle)
                                        .font(.csTiny)
                                        .csForeground(CSColor.textSecondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Text(item.dateLabel)
                                    .font(.csTiny.weight(.medium))
                                    .csForeground(CSColor.textTertiary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    Button("View all memory →") { AppRouter.shared.selection = .memory }
                        .font(.csTiny.weight(.medium))
                        .buttonStyle(.plain)
                        .csForeground(CSColor.info)
                        .padding(.top, 2)
                } else {
                    Text("No recent memory yet.")
                        .font(.csMetadata)
                        .csForeground(CSColor.textSecondary)
                }
            }
        }
    }

    // MARK: - Empty workspaces

    private var emptyWorkspaces: some View {
        EmptyStateView(
            title: "Create your first workspace",
            message: "ContextSphere learns from the work you do inside a workspace. Create one and it will begin tracking context here.",
            symbol: "folder.badge.plus",
            primaryAction: ("Create Workspace", { AppRouter.shared.newWorkspaceRequest = true; AppRouter.shared.selection = .workspaces })
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
