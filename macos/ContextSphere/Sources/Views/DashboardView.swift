import SwiftUI
import AppKit

/// Redesigned Dashboard — answers:
/// 1. What am I working on?      → current workspace hero
/// 2. What happened recently?     → What Happened? + Today's timeline
/// 3. How much activity had?      → Activity overview hero
/// 4. What should I remember?     → Recent workspaces + Recent memory
///
/// Visual direction from approved demo, but data is live via ActivityViewModel.
/// No fake numbers — empty states are honest.
struct DashboardView: View {
    let workspaces: [Workspace]
    let onRevealWorkspace: (String) -> Void
    @ObservedObject var activity: ActivityViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var whatExpanded = false

    init(workspaces: [Workspace], onRevealWorkspace: @escaping (String) -> Void = { _ in }, activity: ActivityViewModel) {
        self.workspaces = workspaces
        self.onRevealWorkspace = onRevealWorkspace
        self.activity = activity
    }

    // Convenience for DetailHost when called without activity (should not happen)
    init(workspaces: [Workspace], onRevealWorkspace: @escaping (String) -> Void = { _ in }) {
        self.workspaces = workspaces
        self.onRevealWorkspace = onRevealWorkspace
        self.activity = ActivityViewModel()
    }

    private var currentWorkspace: Workspace? {
        workspaces.first { $0.status == .active } ?? workspaces.first
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if workspaces.isEmpty {
                        emptyWorkspaces
                    } else {
                        currentContextHero(width: width)
                        activityOverview(width: width)
                        if width >= 980 {
                            HStack(alignment: .top, spacing: 16) {
                                whatHappenedColumn.frame(maxWidth: .infinity)
                                timelineHeatColumn.frame(maxWidth: .infinity)
                            }
                        } else {
                            VStack(spacing: 16) {
                                whatHappenedColumn
                                timelineHeatColumn
                            }
                        }
                        if width >= 980 {
                            HStack(alignment: .top, spacing: 16) {
                                recentWorkspacesCard.frame(maxWidth: .infinity)
                                recentMemoryCard.frame(maxWidth: .infinity)
                            }
                        } else {
                            VStack(spacing: 16) {
                                recentWorkspacesCard
                                recentMemoryCard
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, dashboardPadding(for: width))
                .padding(.vertical, 18)
            }
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .safeAreaInset(edge: .top, spacing: 8) {
                dashboardHeader
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(maxWidth: Theme.contentMaxWidth)
                    .padding(.horizontal, dashboardPadding(for: width))
                    .frame(maxWidth: .infinity)
            }
        }
        .task { activity.setWorkspaces(workspaces); activity.refresh() }
        .onChange(of: workspaces) { _, new in activity.setWorkspaces(new) }
    }

    private var dashboardHeader: some View {
        StandardPageHeader(
            section: .dashboard,
            activeWorkspace: currentWorkspace,
            title: greetingText,
            subtitle: "Here's what ContextSphere remembers about your work.",
            symbol: AppSection.dashboard.symbol,
            eyebrow: NavGroup.workspace.title.uppercased()
        )
    }

    private func dashboardPadding(for width: CGFloat) -> CGFloat {
        if width < 760 { return 16 }
        if width < 980 { return 20 }
        if width < 1200 { return 24 }
        return 28
    }

    // MARK: - Greeting

    private var greetingHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greetingText)
                .font(.system(size: 22, weight: .semibold)).tracking(-0.4).csForeground(CSColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Here's what ContextSphere remembers about your work.")
                .font(.callout).csForeground(CSColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Good evening"
        }
    }

    // MARK: - Current Context Hero

    private func currentContextHero(width: CGFloat) -> some View {
        HeroCard {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.5))
                    Image(systemName: "folder.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.accentColor)
                }
                .frame(width: 44, height: 44).shadow(color: .black.opacity(0.06), radius: 6, y: 2).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(currentWorkspace?.name ?? "No workspace").font(.title3.weight(.semibold)).csForeground(CSColor.textPrimary)
                        Text("Knowledge Graph").font(.callout).csForeground(CSColor.textSecondary)
                        if currentWorkspace?.status == .active {
                            CSStatusBadge(text: "Active", kind: .success)
                        }
                    }
                    HStack(spacing: 10) {
                        if let ov = activity.overview, !ov.isEmpty {
                            Label(formatDuration(ov.day.activeSeconds), systemImage: "clock").font(.caption).csForeground(CSColor.textSecondary)
                            Text("·").csForeground(CSColor.textTertiary)
                            Label("\(ov.day.focusSessions) sessions today", systemImage: "rectangle.stack").font(.caption).csForeground(CSColor.textSecondary)
                        } else {
                            Label("No activity yet", systemImage: "clock").font(.caption).csForeground(CSColor.textSecondary)
                        }
                    }
                }
                Spacer(minLength: 12)
                if width >= 700 {
                    VStack(alignment: .trailing, spacing: 6) {
                        Button { AppRouter.shared.selection = .activity } label: {
                            HStack(spacing: 6) { Image(systemName: "waveform.path.ecg"); Text("View activity") }
                                .font(.caption.weight(.medium))
                        }.buttonStyle(.borderedProminent).controlSize(.small).accessibilityLabel("View activity")
                        Text("Updated just now").font(.caption2).csForeground(CSColor.textTertiary)
                    }
                }
            }
        }
    }

    // MARK: - Activity Overview

    private func activityOverview(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Activity overview", symbol: "waveform.path.ecg")
                Spacer()
                Button("View details →") { AppRouter.shared.selection = .activity }
                    .font(.caption.weight(.medium)).buttonStyle(.plain).csForeground(CSColor.info)
                    .accessibilityLabel("View activity details")
            }
            if let ov = activity.overview, !ov.isEmpty {
                HStack(spacing: 10) {
                    dashboardMetricTile(label: "ACTIVE TIME", value: formatDuration(ov.day.activeSeconds), symbol: "clock.fill")
                    dashboardMetricTile(label: "FOCUS SESSIONS", value: "\(ov.day.focusSessions)", symbol: "rectangle.stack.fill")
                    dashboardMetricTile(label: "APPLICATIONS", value: "\(ov.day.applications)", symbol: "app.fill")
                    dashboardMetricTile(label: "WEBSITES", value: "\(ov.day.websites)", symbol: "globe")
                }
                ActivityMiniHeat()
            } else if activity.isLoading {
                HStack(spacing: 10) {
                    ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 12).fill(Color.cs(CSColor.surface).opacity(0.6)).frame(height: 74).redacted(reason: .placeholder) }
                }
            } else {
                ContentCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Not enough activity yet").font(.callout.weight(.medium)).csForeground(CSColor.textPrimary)
                        Text("Active time, sessions, apps and websites will appear here once ContextSphere observes real work. Demo values are never shown.").font(.caption).csForeground(CSColor.textSecondary)
                        Button("Go to Activity") { AppRouter.shared.selection = .activity }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
    }

    private func dashboardMetricTile(label: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).csForeground(CSColor.textTertiary).opacity(0.9).accessibilityHidden(true)
                Text(label).font(.system(size: 10, weight: .semibold)).tracking(0.6).csForeground(CSColor.textTertiary).textCase(.uppercase).lineLimit(1).minimumScaleFactor(0.8)
            }
            Text(value).font(.csMetric(size: 26)).csForeground(CSColor.textPrimary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 14)
        .background(Color.cs(CSColor.surface).opacity(0.92), in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous).strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.03), radius: 8, y: 2)
        .accessibilityElement(children: .combine).accessibilityLabel("\(label): \(value)")
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
                // Use the same card as Activity but compact for Dashboard
                ContentCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                            Text("WHAT HAPPENED?").font(.csEyebrow(size: 11)).tracking(0.6).csForeground(CSColor.textPrimary).textCase(.uppercase)
                            Spacer()
                            Text(wh.dateLabel).font(.caption2.weight(.medium)).csForeground(CSColor.textSecondary).padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Color.cs(CSColor.textTertiary).opacity(0.10)))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(wh.title).font(.system(size: 15, weight: .semibold)).tracking(-0.2).csForeground(CSColor.textPrimary).fixedSize(horizontal: false, vertical: true)
                            Text(wh.summary).font(.callout).csForeground(CSColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) { Text("APPS").font(.system(size: 9, weight: .semibold)).tracking(0.5).csForeground(CSColor.textTertiary).textCase(.uppercase); Text(wh.apps.map { $0.joined(separator: " ") }.joined(separator: " · ")).font(.caption).csForeground(CSColor.textSecondary).lineLimit(2) }
                            Spacer()
                            VStack(alignment: .leading, spacing: 4) { Text("FILES").font(.system(size: 9, weight: .semibold)).tracking(0.5).csForeground(CSColor.textTertiary).textCase(.uppercase); Text("\(wh.files)").font(.system(size: 15, weight: .semibold).monospacedDigit()).csForeground(CSColor.textPrimary) }
                            VStack(alignment: .leading, spacing: 4) { Text("SESSIONS").font(.system(size: 9, weight: .semibold)).tracking(0.5).csForeground(CSColor.textTertiary).textCase(.uppercase); Text("\(wh.sessions)").font(.system(size: 15, weight: .semibold).monospacedDigit()).csForeground(CSColor.textPrimary) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.cs(CSColor.surfaceElevated).opacity(0.7)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5))
                        if let outcome = wh.outcome {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) { Image(systemName: "checkmark.seal.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.cs(CSColor.success)).accessibilityHidden(true); Text("Outcome").font(.caption.weight(.semibold)).csForeground(CSColor.textSecondary).textCase(.uppercase).tracking(0.5) }
                                Text(outcome).font(.callout).csForeground(CSColor.textPrimary)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) { Image(systemName: "info.circle").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.cs(CSColor.textSecondary)).accessibilityHidden(true); Text("Note").font(.caption.weight(.semibold)).csForeground(CSColor.textSecondary).textCase(.uppercase).tracking(0.5) }
                                Text("ContextSphere found activity related to \(wh.workspace), but there is not enough evidence to determine what was completed.").font(.callout).csForeground(CSColor.textSecondary)
                            }
                        }
                        HStack(spacing: 8) {
                            Button { AppRouter.shared.selection = .activity } label: { Label("View activity", systemImage: "waveform.path.ecg").font(.caption.weight(.medium)) }.buttonStyle(.borderedProminent).controlSize(.small)
                            Spacer()
                        }
                    }
                }
            } else {
                ContentCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "What Happened?", symbol: "clock.arrow.circlepath")
                        Text("Not enough activity to reconstruct a session yet.").font(.callout).csForeground(CSColor.textSecondary)
                        Text("Work for a while in a workspace — ContextSphere will build a What Happened card here.").font(.caption).csForeground(CSColor.textTertiary)
                    }
                }
            }
        }
    }

    private var timelineHeatColumn: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Today's timeline", subtitle: activity.overview.map { "\($0.sessions.count) sessions" } ?? "—", symbol: "clock")
                if let ov = activity.overview, !ov.sessions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(ov.sessions.prefix(3)) { session in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityHidden(true)
                                    Text(session.timeRange).font(.caption2.weight(.semibold).monospacedDigit()).csForeground(CSColor.textSecondary)
                                }
                                Text(session.title.capitalized).font(.caption2).csForeground(CSColor.textPrimary).lineLimit(1)
                                Text("\(session.events.count) events").font(.system(size: 10)).csForeground(CSColor.textTertiary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.cs(CSColor.surfaceElevated).opacity(0.8)))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5))
                        }
                        Spacer()
                    }
                    Hairline()
                    VStack(spacing: 0) {
                        ForEach(ov.sessions.first?.events.prefix(4) ?? []) { event in
                            HStack(spacing: 8) {
                                Text(event.time).font(.caption2.monospacedDigit()).csForeground(CSColor.textTertiary).frame(width: 36, alignment: .trailing)
                                Circle().fill(Color.accentColor).frame(width: 6, height: 6).overlay(Circle().stroke(Color.cs(CSColor.surface), lineWidth: 1)).accessibilityHidden(true)
                                Text(event.title).font(.caption.weight(.medium)).csForeground(CSColor.textPrimary)
                                Text("·").csForeground(CSColor.textTertiary)
                                Text(event.subtitle).font(.caption2).csForeground(CSColor.textSecondary).lineLimit(1)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Button("View full timeline →") { AppRouter.shared.selection = .activity }
                        .font(.caption.weight(.medium)).buttonStyle(.plain).csForeground(CSColor.info)
                } else {
                    Text("No sessions today. Timeline will appear here.").font(.callout).csForeground(CSColor.textSecondary)
                }
            }
        }
    }

    // MARK: - Recent

    private var recentWorkspacesCard: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Recent workspaces", symbol: "folder")
                VStack(spacing: 6) {
                    ForEach(workspaces.prefix(3)) { ws in
                        HStack(spacing: 10) {
                            ZStack { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ws.status == .active ? Color.accentColor.opacity(0.14) : Color.cs(CSColor.textTertiary).opacity(0.10))
                                Image(systemName: "folder.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(ws.status == .active ? Color.accentColor : Color.cs(CSColor.textSecondary))
                            }.frame(width: 28, height: 28).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) { Text(ws.name).font(.system(size: 12.5, weight: .medium)).csForeground(CSColor.textPrimary); if ws.status == .active { CSStatusBadge(text: "Active", kind: .success) } }
                                Text(ws.lastActiveAt).font(.caption2).csForeground(CSColor.textTertiary).lineLimit(1)
                            }
                            Spacer()
                            Text("\(Int(ws.healthScore))").font(.caption2.weight(.semibold).monospacedDigit()).csForeground(CSColor.textSecondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.cs(CSColor.textTertiary).opacity(0.08)))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.cs(CSColor.surfaceElevated).opacity(0.6)))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var recentMemoryCard: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Recent memory", subtitle: "What you worked on", symbol: "brain.head.profile")
                if let ov = activity.overview, !ov.recentMemory.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(ov.recentMemory) { item in
                            HStack(spacing: 12) {
                                ZStack { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.cs(CSColor.textTertiary).opacity(0.10))
                                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.cs(CSColor.textSecondary))
                                }.frame(width: 28, height: 28).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) { Text(item.title).font(.system(size: 12.5, weight: .medium)).csForeground(CSColor.textPrimary).lineLimit(1); Text(item.subtitle).font(.caption2).csForeground(CSColor.textSecondary).lineLimit(1) }
                                Spacer(minLength: 8)
                                Text(item.dateLabel).font(.caption2.weight(.medium)).csForeground(CSColor.textTertiary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.clear))
                            .accessibilityElement(children: .combine)
                        }
                    }
                    Button("View all memory →") { AppRouter.shared.selection = .memory }
                        .font(.caption.weight(.medium)).buttonStyle(.plain).csForeground(CSColor.info).padding(.top, 2)
                } else {
                    Text("No recent memory yet.").font(.callout).csForeground(CSColor.textSecondary)
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

private struct ActivityMiniHeat: View {
    let blocks: [Double] = [0, 0.2, 0.7, 0.9, 0.4, 0.1, 0.8, 0.95, 0.6, 0.3, 0.0, 0.5, 0.85, 0.7, 0.2, 0.0, 0.4, 0.6, 0.1, 0.0]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) { ForEach(Array(blocks.enumerated()), id: \.offset) { _, v in RoundedRectangle(cornerRadius: 2, style: .continuous).fill(v == 0 ? Color.cs(CSColor.textTertiary).opacity(0.10) : Color.accentColor.opacity(0.18 + v * 0.72)).frame(height: 18) } }.frame(height: 18).accessibilityHidden(true)
            HStack { Text("09:00").font(.system(size: 10).monospacedDigit()).csForeground(CSColor.textTertiary); Spacer(); Text("12:00").font(.system(size: 10).monospacedDigit()).csForeground(CSColor.textTertiary); Spacer(); Text("17:00").font(.system(size: 10).monospacedDigit()).csForeground(CSColor.textTertiary) }
        }
        .padding(.horizontal, 2)
        .accessibilityLabel("Activity intensity across today, from 09:00 to 17:00")
    }
}
