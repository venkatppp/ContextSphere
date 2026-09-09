import SwiftUI
import AppKit
import Charts

/// Production Activity view — real data from ActivityService via CoreBridge.
/// Visual direction from macos/ContextSphereDemo demo, but driven by live
/// ActivityOverviewDto. Empty states are honest: "Not enough activity yet."
struct ActivityView: View {
    @ObservedObject var viewModel: ActivityViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedSessions: Set<String> = []
    @State private var selectedAppID: String?
    @State private var selectedWebID: String?
    @State private var whatExpanded = false
    @State private var selectedMemoryID: String?
    @State private var hoveredDonutID: String?
    @State private var selectedDonutID: String?
    @State private var containerWidth: CGFloat = 1024

    private var workspaces: [Workspace] { viewModel.workspaces }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                StandardPageHeader(
                    section: .activity,
                    activeWorkspace: workspaces.first { $0.status == .active } ?? workspaces.first,
                    title: "Activity",
                    subtitle: "ContextSphere reconstructs how you spent your time.",
                    symbol: AppSection.activity.symbol,
                    eyebrow: NavGroup.workspace.title.uppercased()
                ) {
                    Button { viewModel.refresh() } label: {
                        if viewModel.isLoading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .medium)) }
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh activity").accessibilityLabel("Refresh activity")
                }
                .padding(.horizontal, layoutPadding(for: containerWidth))
                .padding(.vertical, Theme.pageHeaderVerticalPadding)
                Hairline(opacity: Theme.pageHeaderDividerOpacity)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        controls
                        if viewModel.isLoading && viewModel.overview == nil {
                            LoadingView(label: "Loading activity…")
                                .frame(maxWidth: .infinity, minHeight: 200)
                        } else if let error = viewModel.error, viewModel.overview == nil {
                            EmptyStateView(title: "Activity unavailable", message: error, symbol: "exclamationmark.triangle", primaryAction: ("Retry", { viewModel.refresh() }))
                                .frame(maxWidth: .infinity, minHeight: 240)
                        } else if let ov = viewModel.overview, ov.isEmpty {
                            emptyState(reason: ov.emptyReason)
                        } else if let ov = viewModel.overview {
                            heroMetrics(ov)
                            mainGrid(width: containerWidth, overview: ov).id("grid")
                            whatHappenedSection(ov).id("what")
                            recentMemorySection(ov).id("memory")
                        } else {
                            emptyState(reason: nil)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, layoutPadding(for: containerWidth))
                    .padding(.vertical, 16)
                }
                .scrollIndicators(.automatic)
                .scrollEdgeEffectStyle(.soft, for: .vertical)
                .defaultScrollAnchor(.top)
            }

            if let app = selectedApp(from: viewModel.overview) {
                ActivityAppDetailPanel(usage: app) { withAnimation(Theme.spring(reduceMotion, response: 0.32)) { selectedAppID = nil } }
                    .padding(.trailing, 16).padding(.top, 12)
                    .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
                    .zIndex(10)
                    .allowsHitTesting(true)
            } else if let web = selectedWeb(from: viewModel.overview) {
                ActivityWebDetailPanel(usage: web) { withAnimation(Theme.spring(reduceMotion, response: 0.32)) { selectedWebID = nil } }
                    .padding(.trailing, 16).padding(.top, 12)
                    .zIndex(10)
                    .allowsHitTesting(true)
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
        .background {
            Button("") { handleEscape() }.keyboardShortcut(.escape, modifiers: []).hidden().accessibilityHidden(true)
        }
        .task { viewModel.initialLoadIfNeeded() }
        .onChange(of: viewModel.overview?.day.date) { _, _ in
            // Preserve user collapsed state; only expand new sessions, don't collapse existing
            if let ov = viewModel.overview {
                let newIDs = Set(ov.sessions.map(\.id))
                if expandedSessions.isEmpty {
                    expandedSessions = newIDs
                } else {
                    // Insert any new sessions that appeared (e.g., live update) without wiping user choice
                    expandedSessions.formUnion(newIDs)
                    // Remove IDs that no longer exist (e.g., filter change)
                    expandedSessions = expandedSessions.intersection(newIDs)
                }
            }
        }
    }

    private func selectedApp(from ov: ActivityOverview?) -> ActivityAppUsage? {
        guard let id = selectedAppID else { return nil }
        return ov?.appUsages.first { $0.id == id }
    }
    private func selectedWeb(from ov: ActivityOverview?) -> ActivityWebUsage? {
        guard let id = selectedWebID else { return nil }
        return ov?.webUsages.first { $0.id == id }
    }
    private func handleEscape() {
        if selectedAppID != nil { selectedAppID = nil; return }
        if selectedWebID != nil { selectedWebID = nil; return }
        if !viewModel.searchQuery.isEmpty { viewModel.searchQuery = "" }
    }
    private func layoutPadding(for width: CGFloat) -> CGFloat {
        Theme.horizontalPadding(for: width)
    }

    // MARK: - Header (now via safeAreaInset StandardPageHeader)

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                dateSelector
                Spacer(minLength: 8)
                workspaceAndDeviceFilters
                searchFieldCapsule
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    dateSelector
                    Spacer()
                    workspaceAndDeviceFilters
                }
                searchFieldCapsule
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var dateSelector: some View {
        HStack(spacing: 4) {
            Button { cycleDate(-1) } label: { Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).frame(width: 22, height: 22) }
                .buttonStyle(.plain).csForeground(CSColor.textSecondary).help("Previous day").accessibilityLabel("Previous day")
            Menu {
                ForEach(["Today","Yesterday","This Week","Last 7 Days"], id: \.self) { opt in
                    Button(opt) { viewModel.dateFilter = opt }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "calendar").font(.system(size: 13, weight: .medium)).csForeground(CSColor.textSecondary)
                    Text(viewModel.dateFilter).font(.system(size: 14.5, weight: .medium)).csForeground(CSColor.textPrimary)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).csForeground(CSColor.textTertiary)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.cs(CSColor.surface).opacity(0.9)))
                .overlay(Capsule().strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5))
            }.menuIndicator(.hidden).fixedSize()
            Button { cycleDate(1) } label: { Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).frame(width: 22, height: 22) }
                .buttonStyle(.plain).csForeground(CSColor.textSecondary).help("Next day").accessibilityLabel("Next day")
        }
    }

    private var workspaceAndDeviceFilters: some View {
        HStack(spacing: 8) {
            Menu {
                Button("All Workspaces") { viewModel.selectedWorkspaceId = nil }
                ForEach(workspaces) { ws in Button(ws.name) { viewModel.selectedWorkspaceId = ws.id } }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder").font(.system(size: 13, weight: .medium)).csForeground(CSColor.textSecondary).accessibilityHidden(true)
                    Text(selectedWorkspaceName).font(.system(size: 14)).csForeground(CSColor.textPrimary).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).csForeground(CSColor.textTertiary)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.cs(CSColor.surface).opacity(0.9)))
                .overlay(Capsule().strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5))
            }.menuIndicator(.hidden).fixedSize()
            Menu {
                ForEach(["This Mac", "All Devices"], id: \.self) { opt in Button(opt) {} }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "desktopcomputer").font(.system(size: 13, weight: .medium)).csForeground(CSColor.textSecondary).accessibilityHidden(true)
                    Text("This Mac").font(.system(size: 14)).csForeground(CSColor.textPrimary).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).csForeground(CSColor.textTertiary)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.cs(CSColor.surface).opacity(0.9)))
                .overlay(Capsule().strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5))
            }.menuIndicator(.hidden).fixedSize()
        }
    }

    private var searchFieldCapsule: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).csForeground(CSColor.textTertiary).accessibilityHidden(true)
            TextField("Search", text: $viewModel.searchQuery).textFieldStyle(.plain).font(.system(size: 14.5)).frame(minWidth: 90, idealWidth: 140, maxWidth: 180)
                .accessibilityLabel("Search activity")
            if !viewModel.searchQuery.isEmpty {
                Button { viewModel.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 13)).csForeground(CSColor.textTertiary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color.cs(CSColor.surface).opacity(0.9)))
        .overlay(Capsule().strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5))
    }

    private var selectedWorkspaceName: String {
        if let id = viewModel.selectedWorkspaceId, let ws = workspaces.first(where: { $0.id == id }) { return ws.name }
        return "All Workspaces"
    }

    private func cycleDate(_ dir: Int) {
        let opts = ["Today","Yesterday","This Week","Last 7 Days"]
        guard let idx = opts.firstIndex(of: viewModel.dateFilter) else { return }
        let next = (idx + dir + opts.count) % opts.count
        withAnimation(Theme.spring(reduceMotion, response: 0.28)) { viewModel.dateFilter = opts[next] }
    }

    // MARK: - Hero metrics

    private func heroMetrics(_ ov: ActivityOverview) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                metricTile(label: "ACTIVE TIME", value: formatDuration(ov.day.activeSeconds), symbol: "clock.fill")
                metricTile(label: "FOCUS SESSIONS", value: "\(ov.day.focusSessions)", symbol: "rectangle.stack.fill")
                metricTile(label: "APPLICATIONS", value: "\(ov.day.applications)", symbol: "app.fill")
                metricTile(label: "WEBSITES", value: "\(ov.day.websites)", symbol: "globe")
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                metricTile(label: "ACTIVE TIME", value: formatDuration(ov.day.activeSeconds), symbol: "clock.fill")
                metricTile(label: "FOCUS SESSIONS", value: "\(ov.day.focusSessions)", symbol: "rectangle.stack.fill")
                metricTile(label: "APPLICATIONS", value: "\(ov.day.applications)", symbol: "app.fill")
                metricTile(label: "WEBSITES", value: "\(ov.day.websites)", symbol: "globe")
            }
        }
    }

    private func metricTile(label: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).csForeground(CSColor.textTertiary).opacity(0.9).accessibilityHidden(true)
                Text(label).font(.system(size: 12, weight: .semibold)).tracking(0.6).csForeground(CSColor.textTertiary).textCase(.uppercase).lineLimit(1).minimumScaleFactor(0.8)
            }
            Text(value).font(.csMetric(size: 28)).csForeground(CSColor.textPrimary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
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

    private func formatMinutes(_ minutes: Int, percent: Double) -> String {
        if minutes == 0 && percent > 0 { return "<1m" }
        if minutes >= 60 { return "\(minutes/60)h \(minutes%60)m" }
        return "\(minutes)m"
    }

    // MARK: - Main grid

    private func mainGrid(width: CGFloat, overview: ActivityOverview) -> some View {
        let isWide = width >= 1100
        let isMedium = width >= 880
        return Group {
            if isWide {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        timelineCard(overview)
                        applicationsCard(overview).id("applications")
                        webActivityCard(overview).id("web")
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 16) {
                        usageBreakdownCard(overview).id("usage")
                        workspaceCorrelationCard(overview).id("correlation")
                    }
                    .frame(width: 360)
                }
            } else if isMedium {
                VStack(spacing: 16) {
                    timelineCard(overview)
                    HStack(alignment: .top, spacing: 16) {
                        applicationsCard(overview).frame(maxWidth: .infinity).id("applications")
                        webActivityCard(overview).frame(maxWidth: .infinity).id("web")
                    }
                    HStack(alignment: .top, spacing: 16) {
                        usageBreakdownCard(overview).frame(maxWidth: .infinity).id("usage")
                        workspaceCorrelationCard(overview).frame(maxWidth: .infinity).id("correlation")
                    }
                }
            } else {
                VStack(spacing: 16) {
                    timelineCard(overview)
                    applicationsCard(overview).id("applications")
                    webActivityCard(overview).id("web")
                    usageBreakdownCard(overview).id("usage")
                    workspaceCorrelationCard(overview).id("correlation")
                }
            }
        }
    }

    private func timelineCard(_ ov: ActivityOverview) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    SectionHeader(title: "Activity Timeline", subtitle: ov.sessions.isEmpty ? "No sessions" : "\(ov.sessions.count) sessions", symbol: "clock")
                    Spacer()
                    Button(expandedSessions.count == ov.sessions.count && !ov.sessions.isEmpty ? "Collapse all" : "Expand all") {
                        withAnimation(Theme.spring(reduceMotion, response: 0.32)) {
                            if expandedSessions.count == ov.sessions.count { expandedSessions = [] }
                            else { expandedSessions = Set(ov.sessions.map(\.id)) }
                        }
                    }
                    .font(.caption.weight(.medium)).buttonStyle(.plain).csForeground(CSColor.info)
                }
                if ov.sessions.isEmpty {
                    Text(ov.isEmpty ? "No activity in this period." : "No sessions matched your search.")
                        .font(.callout).csForeground(CSColor.textSecondary).padding(.vertical, 8)
                } else {
                    VStack(spacing: 12) {
                        ForEach(ov.sessions) { session in
                            ActivitySessionBlockProduction(
                                session: session,
                                isExpanded: expandedSessions.contains(session.id),
                                onToggle: {
                                    withAnimation(Theme.spring(reduceMotion, response: 0.30)) {
                                        if expandedSessions.contains(session.id) { expandedSessions.remove(session.id) }
                                        else { expandedSessions.insert(session.id) }
                                    }
                                }
                            )
                        }
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 12, weight: .semibold)).csForeground(CSColor.textTertiary).accessibilityHidden(true)
                    Text("Grouped by ContextSphere · 30m inactivity threshold")
                        .font(.system(size: 12, weight: .medium)).tracking(0.3).csForeground(CSColor.textTertiary).textCase(.uppercase).lineLimit(1).minimumScaleFactor(0.7)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Capsule().fill(Color.cs(CSColor.textTertiary).opacity(0.07)))
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func applicationsCard(_ ov: ActivityOverview) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Applications", subtitle: ov.appUsages.isEmpty ? "No data" : "\(ov.appUsages.count) apps", symbol: "app.fill")
                if ov.appUsages.isEmpty {
                    VStack(spacing: 6) {
                        Text("Not enough application activity yet.").font(.callout).csForeground(CSColor.textSecondary)
                        Text("Grant permission and work for a bit — ContextSphere will show Xcode, Safari etc. here with real durations.").font(.caption).csForeground(CSColor.textTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    .accessibilityElement(children: .combine).accessibilityLabel("No application data yet")
                } else {
                    let maxM = ov.appUsages.map(\.minutes).max() ?? 1
                    VStack(spacing: 2) {
                        ForEach(ov.appUsages) { usage in
                            Button {
                                withAnimation(Theme.spring(reduceMotion, response: 0.30)) {
                                    if selectedAppID == usage.id { selectedAppID = nil } else { selectedAppID = usage.id; selectedWebID = nil }
                                }
                            } label: {
                                ProductionAppRow(usage: usage, maxMinutes: maxM, isSelected: selectedAppID == usage.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !ov.appUsages.isEmpty {
                    Text("Click an app to see files and sessions →").font(.caption2).csForeground(CSColor.textTertiary).frame(maxWidth: .infinity, alignment: .center).padding(.top, 2)
                }
            }
        }
    }

    private func webActivityCard(_ ov: ActivityOverview) -> some View {
        let webPermissionDenied = UserDefaults.standard.bool(forKey: "activity.webPermissionDenied")
        return ContentCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Web Activity", subtitle: ov.webUsages.isEmpty ? (webPermissionDenied ? "Unavailable" : "No data") : "\(ov.webUsages.count) domains", symbol: "globe")
                Text("ContextSphere remembers where you researched something — domain and title only.").font(.caption).csForeground(CSColor.textTertiary).fixedSize(horizontal: false, vertical: true)
                if ov.webUsages.isEmpty {
                    if webPermissionDenied {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Web activity unavailable — permission not granted", systemImage: "eye.slash").font(.callout.weight(.medium)).csForeground(CSColor.warning)
                            Text("To enable privacy-first web activity (domain + title only, no URL parameters or content), allow Automation for your browser.").font(.caption).csForeground(CSColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                            Text("System Settings → Privacy & Security → Automation → ContextSphere → Safari / Chrome").font(.caption2.monospaced()).csForeground(CSColor.textTertiary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Button("Open System Settings") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }.buttonStyle(.bordered).controlSize(.small)
                                Button("Dismiss") { UserDefaults.standard.removeObject(forKey: "activity.webPermissionDenied") }.buttonStyle(.plain).font(.caption).csForeground(CSColor.textSecondary)
                            }
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine).accessibilityLabel("Web activity unavailable — permission not granted")
                    } else {
                        Text("No web activity in this period.").font(.callout).csForeground(CSColor.textSecondary).padding(.vertical, 4)
                    }
                } else {
                    let maxM = ov.webUsages.map(\.minutes).max() ?? 1
                    VStack(spacing: 2) {
                        ForEach(ov.webUsages) { usage in
                            Button {
                                withAnimation(Theme.spring(reduceMotion, response: 0.30)) {
                                    if selectedWebID == usage.id { selectedWebID = nil } else { selectedWebID = usage.id; selectedAppID = nil }
                                }
                            } label: {
                                ProductionWebRow(usage: usage, maxMinutes: maxM, isSelected: selectedWebID == usage.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func usageBreakdownCard(_ ov: ActivityOverview) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Usage Breakdown", symbol: "chart.pie.fill")
                if ov.donut.isEmpty {
                    Text("No application distribution to show yet.").font(.callout).csForeground(CSColor.textSecondary)
                } else {
                    let display = AppColorProvider.displayDonut(ov.donut)
                    // Side-by-side while the legend fits; stacked with a
                    // full-width legend in narrow columns so app names never
                    // truncate. Donut stays 128pt per the approved reference.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 18) {
                            ProductionDonut(
                                segments: display,
                                size: 128,
                                hoveredSegmentID: $hoveredDonutID,
                                selectedSegmentID: $selectedDonutID
                            )
                            usageLegend(display)
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            ProductionDonut(
                                segments: display,
                                size: 128,
                                hoveredSegmentID: $hoveredDonutID,
                                selectedSegmentID: $selectedDonutID
                            )
                            usageLegend(display)
                        }
                    }
                }
            }
        }
    }

    private func usageLegend(_ segments: [ActivityDonutSegment]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(segments) { seg in
                Button {
                    withAnimation(Theme.spring(reduceMotion, response: 0.18)) {
                        selectedDonutID = (selectedDonutID == seg.id) ? nil : seg.id
                    }
                } label: {
                    HStack(spacing: 7) {
                        Circle().fill(AppColorProvider.color(for: seg)).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text(seg.label).font(.system(size: 13.5, weight: .medium)).csForeground(CSColor.textPrimary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(Int((seg.percent*100).rounded()))%").font(.system(size: 13).monospacedDigit()).csForeground(CSColor.textSecondary)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selectedDonutID == seg.id
                                  ? Color.cs(CSColor.selectionFill)
                                  : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(seg.label), \(Int((seg.percent*100).rounded())) percent")
                .accessibilityAddTraits(selectedDonutID == seg.id ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    private func workspaceCorrelationCard(_ ov: ActivityOverview) -> some View {
        ContentCard {
            let corr = ov.correlation
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                    Text("CURRENT CONTEXT").font(.csEyebrow(size: 12)).tracking(0.7).csForeground(CSColor.textSecondary).textCase(.uppercase)
                    Spacer()
                    Circle().fill(Color.cs(corr.hasData ? CSColor.success : CSColor.textTertiary)).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(corr.hasData ? "Active" : "Idle").font(.caption2.weight(.semibold)).csForeground(corr.hasData ? CSColor.success : CSColor.textTertiary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(corr.workspaceName).font(.system(size: 18, weight: .semibold)).tracking(-0.2).csForeground(CSColor.textPrimary)
                    Text(corr.project).font(.system(size: 14.5)).csForeground(CSColor.textSecondary)
                    Text(corr.hasData ? "\(corr.activeMinutes / 60)h \(corr.activeMinutes % 60)m active" : "No activity in this period").font(.system(size: 13, weight: .medium).monospacedDigit()).csForeground(CSColor.textTertiary).padding(.top, 2)
                }
                Hairline()
                if corr.apps.isEmpty && corr.hasData {
                    Text("Application breakdown will appear once app observation is active.").font(.caption).csForeground(CSColor.textSecondary)
                } else if !corr.apps.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(corr.appPairs.enumerated()), id: \.offset) { _, pair in
                            HStack(spacing: 8) {
                                Text(pair.0).font(.system(size: 13.5)).csForeground(CSColor.textPrimary).frame(width: 64, alignment: .leading)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .minimumScaleFactor(0.85)
                                .accessibilityHidden(true)
                                GeometryReader { geo in
                                    let maxM = corr.appPairs.map(\.1).max() ?? 1
                                    let frac = maxM > 0 ? CGFloat(pair.1) / CGFloat(maxM) : 0
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.cs(CSColor.textTertiary).opacity(0.10)).frame(height: 4)
                                        Capsule().fill(AppColorProvider.color(for: pair.0).opacity(0.9)).frame(width: geo.size.width * frac, height: 4)
                                    }
                                }.frame(height: 4)
                                Text("\(pair.1)m").font(.system(size: 12.5).monospacedDigit()).csForeground(CSColor.textSecondary).frame(width: 42, alignment: .trailing)
                            }
                        }
                    }
                }
                Hairline()
                HStack(spacing: 16) {
                    Label("\(corr.filesModified) modified", systemImage: "doc.badge.ellipsis").font(.caption2).csForeground(CSColor.textSecondary)
                    Label("\(corr.filesOpened) opened", systemImage: "doc").font(.caption2).csForeground(CSColor.textSecondary)
                    Label("\(corr.webPages) related pages", systemImage: "globe").font(.caption2).csForeground(CSColor.textSecondary)
                }
                .labelStyle(.titleAndIcon)
                HStack(spacing: 3) {
                    ForEach(["App","Web","File","Workspace","Timeline"], id: \.self) { part in
                        Text(part).font(.system(size: 10.5, weight: .medium)).csForeground(CSColor.textTertiary)
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .background(Capsule().fill(Color.cs(CSColor.textTertiary).opacity(0.08)))
                    }
                    Text("=").font(.system(size: 10, weight: .semibold)).csForeground(CSColor.textTertiary)
                    Text("Context").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                }
                .accessibilityHidden(true)
            }
        }
    }

    private func whatHappenedSection(_ ov: ActivityOverview) -> some View {
        Group {
            if let wh = ov.whatHappened {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        HStack(spacing: 6) {
                            ZStack { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor.opacity(0.14))
                                Image(systemName: "clock.arrow.circlepath").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentColor)
                            }.frame(width: 24, height: 24).accessibilityHidden(true)
                            Text("WHAT HAPPENED?").font(.csEyebrow(size: 13)).tracking(0.6).csForeground(CSColor.textPrimary).textCase(.uppercase)
                        }
                        Spacer()
                        Text(wh.dateLabel).font(.caption2.weight(.medium)).csForeground(CSColor.textSecondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.cs(CSColor.textTertiary).opacity(0.10)))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(wh.title).font(.system(size: 17, weight: .semibold)).tracking(-0.2).csForeground(CSColor.textPrimary).fixedSize(horizontal: false, vertical: true)
                        Text(wh.summary).font(.callout).csForeground(CSColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("APPS").font(.system(size: 11, weight: .semibold)).tracking(0.5).csForeground(CSColor.textTertiary).textCase(.uppercase)
                            Text(wh.apps.map { $0.joined(separator: " ") }.joined(separator: " · ")).font(.caption).csForeground(CSColor.textSecondary).lineLimit(2)
                        }
                        Spacer()
                        VStack(alignment: .leading, spacing: 4) { Text("FILES").font(.system(size: 11, weight: .semibold)).tracking(0.5).csForeground(CSColor.textTertiary).textCase(.uppercase); Text("\(wh.files)").font(.system(size: 17, weight: .semibold).monospacedDigit()).csForeground(CSColor.textPrimary) }
                        VStack(alignment: .leading, spacing: 4) { Text("SESSIONS").font(.system(size: 11, weight: .semibold)).tracking(0.5).csForeground(CSColor.textTertiary).textCase(.uppercase); Text("\(wh.sessions)").font(.system(size: 17, weight: .semibold).monospacedDigit()).csForeground(CSColor.textPrimary) }
                        VStack(alignment: .leading, spacing: 4) { Text("WEB").font(.system(size: 11, weight: .semibold)).tracking(0.5).csForeground(CSColor.textTertiary).textCase(.uppercase); Text("\(wh.webPages) pages").font(.caption.weight(.medium)).csForeground(CSColor.textSecondary) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.cs(CSColor.surfaceElevated).opacity(0.7)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: wh.hasSufficientEvidence ? "checkmark.seal.fill" : "info.circle").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.cs(wh.hasSufficientEvidence ? CSColor.success : CSColor.textSecondary)).accessibilityHidden(true)
                            Text(wh.hasSufficientEvidence ? "Outcome" : "Note").font(.caption.weight(.semibold)).csForeground(CSColor.textSecondary).textCase(.uppercase).tracking(0.5)
                        }
                        Text(wh.outcome ?? "ContextSphere found activity related to \(wh.workspace), but there is not enough evidence to determine what was completed.").font(.callout).csForeground(CSColor.textPrimary)
                    }
                    HStack(spacing: 8) {
                        Button { selectedAppID = viewModel.overview?.appUsages.first?.id } label: { Label("View activity", systemImage: "waveform.path.ecg").font(.caption.weight(.medium)) }.buttonStyle(.borderedProminent).controlSize(.small)
                        Button { } label: { Label("View files", systemImage: "doc.on.doc").font(.caption.weight(.medium)) }.buttonStyle(.bordered).controlSize(.small)
                        Button { withAnimation { expandedSessions = Set(ov.sessions.map(\.id)) } } label: { Label("View timeline", systemImage: "clock").font(.caption.weight(.medium)) }.buttonStyle(.bordered).controlSize(.small)
                        Spacer()
                        Button { withAnimation(Theme.spring(reduceMotion)) { whatExpanded.toggle() } } label: { Image(systemName: whatExpanded ? "chevron.up" : "chevron.down").font(.system(size: 13, weight: .semibold)) }.buttonStyle(.plain).csForeground(CSColor.textTertiary)
                    }
                    if whatExpanded {
                        VStack(alignment: .leading, spacing: 8) {
                            Hairline()
                            Text("ContextSphere reconstructs — it does not hallucinate. Outcome is shown only when there is deterministic evidence (e.g. a commit).").font(.caption).csForeground(CSColor.textSecondary)
                        }.transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.cs(CSColor.surface).opacity(0.94)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.7))
                .shadow(color: Color.accentColor.opacity(0.07), radius: 16, y: 6)
                .shadow(color: .black.opacity(0.04), radius: 10, y: 3)
                .animation(Theme.spring(reduceMotion), value: whatExpanded)
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

    private func recentMemorySection(_ ov: ActivityOverview) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Recent Memory", subtitle: "Historical reconstruction", symbol: "brain.head.profile")
                Text("“You forgot what you did three days ago? ContextSphere remembers.”").font(.callout.italic()).csForeground(CSColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                if ov.recentMemory.isEmpty {
                    Text("No recent memory yet — sessions will appear after you work.").font(.callout).csForeground(CSColor.textSecondary)
                } else {
                    VStack(spacing: 2) {
                        ForEach(ov.recentMemory) { item in
                            Button {
                                withAnimation(Theme.spring(reduceMotion)) {
                                    if selectedMemoryID == item.id { selectedMemoryID = nil } else { selectedMemoryID = item.id }
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selectedMemoryID == item.id ? Color.accentColor.opacity(0.14) : Color.cs(CSColor.textTertiary).opacity(0.10))
                                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 13, weight: .semibold)).foregroundStyle(selectedMemoryID == item.id ? Color.accentColor : Color.cs(CSColor.textSecondary))
                                    }.frame(width: 28, height: 28).accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title).font(.system(size: 14.5, weight: .medium)).csForeground(CSColor.textPrimary).lineLimit(1)
                                        Text(item.subtitle).font(.caption2).csForeground(CSColor.textSecondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    VStack(alignment: .trailing, spacing: 1) {
                                        Text(item.dateLabel).font(.caption2.weight(.medium)).foregroundStyle(selectedMemoryID == item.id ? Color.accentColor : Color.cs(CSColor.textTertiary))
                                    }
                                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(selectedMemoryID == item.id ? Color.accentColor : Color.clear).accessibilityHidden(true)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selectedMemoryID == item.id ? Color.cs(CSColor.selectionFill) : Color.clear))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selectedMemoryID == item.id ? Color.cs(CSColor.selectionBorder) : Color.clear, lineWidth: 0.5))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if let mid = selectedMemoryID, let item = ov.recentMemory.first(where: { $0.id == mid }) {
                        VStack(alignment: .leading, spacing: 8) {
                            Hairline()
                            HStack(spacing: 8) {
                                Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                                Text("Reconstructed session").font(.caption.weight(.semibold)).csForeground(CSColor.textSecondary).textCase(.uppercase).tracking(0.5)
                                Spacer()
                                Button("Close") { withAnimation(Theme.spring(reduceMotion)) { selectedMemoryID = nil } }.font(.caption.weight(.medium)).buttonStyle(.plain).csForeground(CSColor.info)
                            }
                            Text(item.title).font(.callout.weight(.semibold)).csForeground(CSColor.textPrimary)
                            Text("ContextSphere reconstructed this work from \(item.subtitle.lowercased()).").font(.caption).csForeground(CSColor.textSecondary)
                        }.padding(.top, 4).transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .animation(Theme.spring(reduceMotion), value: selectedMemoryID)
        }
    }

    private func emptyState(reason: String?) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "No activity yet", symbol: "waveform.path.ecg")
                Text(reason ?? "Not enough activity yet — work in a workspace and ContextSphere will reconstruct your sessions here.")
                    .font(.callout).csForeground(CSColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                Text("Active time, focus sessions, applications and websites are calculated from real observations. Demo values like “4h 32m” are never shown unless backed by recorded events.").font(.caption).csForeground(CSColor.textTertiary)
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield").font(.caption2).csForeground(CSColor.textTertiary)
                    Text("Activity stays on this Mac. No cloud upload, no hidden telemetry.").font(.caption2).csForeground(CSColor.textTertiary)
                }
                Button("Refresh") { viewModel.refresh() }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine).accessibilityLabel("No activity yet")
    }
}

// MARK: - Production rows (reuse demo styling but honest)

private struct ActivitySessionBlockProduction: View {
    let session: ActivitySession
    var isExpanded: Bool = true
    var onToggle: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { onToggle?() } label: {
                HStack(alignment: .center, spacing: 12) {
                    ZStack { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.14)).overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.5))
                        Image(systemName: "sparkles").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
                    }.frame(width: 28, height: 28).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title).font(.system(size: 13, weight: .semibold)).tracking(0.5).csForeground(CSColor.textPrimary).textCase(.uppercase)
                        Text(session.timeRange + " · " + session.appsDescription).font(.caption2).csForeground(CSColor.textSecondary).lineLimit(1)
                        Text(session.detail).font(.system(size: 12.5)).csForeground(CSColor.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.system(size: 12, weight: .semibold)).csForeground(CSColor.textTertiary)
                    Text("\(session.events.count)").font(.system(size: 12, weight: .semibold).monospacedDigit()).csForeground(CSColor.textTertiary)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.cs(CSColor.textTertiary).opacity(0.10)))
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            .background(Color.cs(CSColor.surfaceElevated).opacity(0.9), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5))
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(session.events) { event in
                        HStack(spacing: 10) {
                            Text(event.time).font(.system(size: 13, weight: .medium).monospacedDigit()).csForeground(CSColor.textTertiary).frame(width: 42, alignment: .trailing)
                            ZStack { Rectangle().fill(Color.cs(CSColor.separator).opacity(0.6)).frame(width: 1); Circle().fill(Color(red: 0.18, green: 0.52, blue: 0.95)).frame(width: 7, height: 7).overlay(Circle().stroke(Color.cs(CSColor.surface), lineWidth: 1.5)) }.frame(width: 12)
                            ZStack { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor.opacity(0.12)); Image(systemName: event.appSymbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor) }.frame(width: 22, height: 22)
                            VStack(alignment: .leading, spacing: 1) { Text(event.title).font(.system(size: 14.5, weight: .medium)).csForeground(CSColor.textPrimary).lineLimit(1); Text(event.subtitle).font(.system(size: 13.5)).csForeground(CSColor.textSecondary).lineLimit(1) }
                            Spacer(minLength: 8)
                            if let mins = event.durationMinutes { Text("\(mins)m").font(.system(size: 13).monospacedDigit()).csForeground(CSColor.textTertiary) }
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.cs(CSColor.textTertiary).opacity(0.5))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .combine).accessibilityLabel("\(event.time), \(event.title), \(event.subtitle)")
                    }
                }
                .padding(.top, 8).padding(.leading, 14)
            }
        }
    }
}

private struct ProductionAppRow: View {
    let usage: ActivityAppUsage
    let maxMinutes: Int
    var isSelected: Bool = false
    private var appColor: Color { AppColorProvider.color(for: usage.displayName.isEmpty ? usage.app : usage.displayName) }
    var body: some View {
        HStack(spacing: 10) {
            ZStack { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(appColor.opacity(0.14)); Image(systemName: usage.app == "Xcode" ? "hammer.fill" : usage.app == "Safari" ? "safari.fill" : usage.app == "Terminal" ? "terminal.fill" : "app.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(appColor) }.frame(width: 26, height: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) { Text(usage.displayName).font(.system(size: 14.5, weight: .medium)).csForeground(CSColor.textPrimary).lineLimit(1); Spacer(minLength: 4); Text(displayMinutes).font(.system(size: 13, weight: .medium).monospacedDigit()).csForeground(CSColor.textSecondary) }
                GeometryReader { geo in let frac = maxMinutes>0 ? CGFloat(usage.minutes)/CGFloat(maxMinutes) : (usage.percent>0 ? 0.08 : 0); ZStack(alignment:.leading) { Capsule().fill(Color.cs(CSColor.textTertiary).opacity(0.10)).frame(height:5); Capsule().fill(appColor).frame(width: geo.size.width*frac, height:5) } }.frame(height:5).accessibilityHidden(true)
            }
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(isSelected ? appColor : Color.clear)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? Color.cs(CSColor.selectionFill) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isSelected ? Color.cs(CSColor.selectionBorder) : Color.clear, lineWidth: 0.5))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine).accessibilityLabel("\(usage.displayName), \(displayMinutes)")
    }
    private var displayMinutes: String {
        if usage.minutes == 0 && usage.percent > 0 { return "<1m" }
        if usage.minutes >= 60 { return "\(usage.minutes/60)h \(usage.minutes%60)m" }
        return "\(usage.minutes)m"
    }
}

private struct ProductionWebRow: View {
    let usage: ActivityWebUsage
    let maxMinutes: Int
    var isSelected: Bool = false
    var body: some View {
        HStack(spacing: 10) {
            ZStack { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.cs(CSColor.textTertiary).opacity(0.10)); Image(systemName: "globe").font(.system(size: 12, weight: .medium)).csForeground(CSColor.textSecondary) }.frame(width: 26, height: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) { Text(usage.title).font(.system(size: 14.5, weight: .medium)).csForeground(CSColor.textPrimary).lineLimit(1); Spacer(minLength: 4); Text("\(usage.minutes)m").font(.system(size: 13, weight: .medium).monospacedDigit()).csForeground(CSColor.textSecondary) }
                Text(usage.domain + " · \(usage.pages) pages").font(.system(size: 12.5)).csForeground(CSColor.textTertiary).lineLimit(1)
                GeometryReader { geo in let frac = maxMinutes>0 ? CGFloat(usage.minutes)/CGFloat(maxMinutes) : 0; ZStack(alignment:.leading) { Capsule().fill(Color.cs(CSColor.textTertiary).opacity(0.10)).frame(height:4); Capsule().fill(Color(red: 0.35, green: 0.55, blue: 0.85)).frame(width: geo.size.width*frac, height:4) } }.frame(height:4).accessibilityHidden(true)
            }
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(isSelected ? Color.accentColor : Color.clear)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? Color.cs(CSColor.selectionFill) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isSelected ? Color.cs(CSColor.selectionBorder) : Color.clear, lineWidth: 0.5))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(usage.title), \(usage.minutes) minutes, \(usage.domain), \(usage.pages) pages")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Interactive donut chart for the Usage Breakdown card.
///
/// Native Swift Charts (`SectorMark` + `chartAngleSelection`). On macOS the
/// default selection gesture is hover (Apple, WWDC23 session 10037). The
/// chart owns two independent concepts:
///
/// - `hoveredSegmentID` (transient, set ONLY by `chartAngleSelection` and
///   cleared by `.onHover` leaving the chart) tracks the sector under the
///   live pointer.
/// - `selectedSegmentID` (persistent, set ONLY by legend clicks) is the
///   keyboard/accessibility entry point and survives pointer exit.
///
/// The displayed sector — used by the highlight treatment and the in-center
/// label — is `hoveredSegmentID ?? selectedSegmentID`, so live pointer hover
/// always wins. Colors come from `AppColorProvider` so palette overrides
/// stay authoritative.
private struct ProductionDonut: View {
    let segments: [ActivityDonutSegment]
    var size: CGFloat = 128
    @Binding var hoveredSegmentID: String?
    @Binding var selectedSegmentID: String?

    /// Live-wins-over-persistent: pointer hover takes priority; legend
    /// selection re-emerges once the pointer leaves the chart.
    private var displayedID: String? { hoveredSegmentID ?? selectedSegmentID }

    var body: some View {
        let cumulative = cumulativeValues()
        let display = displayedID
        Chart {
            ForEach(Array(segments.enumerated()), id: \.element.id) { _, seg in
                let isDisplayed = (display == seg.id)
                SectorMark(
                    angle: .value("Active", max(0.005, seg.percent)),
                    innerRadius: .ratio(0.618),
                    outerRadius: isDisplayed ? .inset(2) : .inset(6),
                    angularInset: isDisplayed ? 2.0 : 1.5
                )
                .cornerRadius(5)
                .foregroundStyle(AppColorProvider.color(for: seg))
                .opacity(display == nil || isDisplayed ? 1.0 : 0.55)
                .accessibilityLabel(seg.label)
                .accessibilityValue("\(Int((seg.percent * 100).rounded())) percent")
            }
        }
        .chartLegend(.hidden)
        .chartAngleSelection(value: angleBinding(cumulative: cumulative))
        .chartBackground { proxy in
            GeometryReader { geo in
                if let frame = proxy.plotFrame.map({ geo[$0] }) {
                    donutCenterLabel(frame: frame)
                }
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onHover { hovering in
            if !hovering { hoveredSegmentID = nil }
        }
    }

    /// Renders the in-center label when a sector is hovered or selected,
    /// positioned at the geometric centre of the donut's plot area.
    /// The hole is `frame.width * 0.618` in diameter; long app names
    /// (e.g. "ContextSphere") would otherwise overflow beneath the ring.
    /// The label is therefore constrained to the hole width, scales down,
    /// and truncates before it can clip.
    @ViewBuilder
    private func donutCenterLabel(frame: CGRect) -> some View {
        if let id = displayedID, let seg = segments.first(where: { $0.id == id }) {
            let holeDiameter = frame.width * 0.618
            let maxLabelWidth = max(56, holeDiameter - 14)
            VStack(spacing: 1) {
                Text(seg.label)
                    .font(.system(size: 11, weight: .semibold))
                    .csForeground(CSColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.center)
                Text("\(Int((seg.percent * 100).rounded()))%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .csForeground(CSColor.textSecondary)
            }
            .frame(maxWidth: maxLabelWidth)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 4).padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.cs(CSColor.surface).opacity(0.001))
            )
            .position(x: frame.midX, y: frame.midY)
            .transition(.opacity)
            .accessibilityHidden(true)
        }
    }

    /// Cumulative end boundaries in the SAME data units passed to
    /// `SectorMark(angle:)` — i.e. `max(0.005, percent)` per segment, in
    /// render order. `chartAngleSelection` reports the pointer position as
    /// a raw cumulative data value in this domain (Charts converts the
    /// pointer angle internally; WWDC23 session 10037), so hit-testing is
    /// a plain cumulative-range lookup with no trigonometry and no
    /// wrap-around edge cases.
    private func cumulativeValues() -> [Double] {
        var result: [Double] = []
        var acc: Double = 0
        for seg in segments {
            acc += max(0.005, seg.percent)
            result.append(acc)
        }
        return result
    }

    /// Translates the raw `Double?` from `chartAngleSelection` into the
    /// donut's two independent id slots. The setter writes ONLY
    /// `hoveredSegmentID` (Charts is the sole authority for live pointer
    /// hover); `nil` (pointer in the hole or off the sectors) clears it.
    /// The getter derives the midpoint data value of
    /// `hoveredSegmentID ?? selectedSegmentID` so a legend-driven
    /// selection keeps Charts' internal selection state consistent after
    /// the pointer leaves.
    private func angleBinding(cumulative: [Double]) -> Binding<Double?> {
        Binding(
            get: {
                let id = hoveredSegmentID ?? selectedSegmentID
                guard let id, let idx = segments.firstIndex(where: { $0.id == id }) else { return nil }
                let prev = idx == 0 ? 0 : cumulative[idx - 1]
                return (prev + cumulative[idx]) / 2
            },
            set: { newValue in
                guard let newValue else { hoveredSegmentID = nil; return }
                if let idx = cumulative.firstIndex(where: { newValue <= $0 }) {
                    hoveredSegmentID = segments[idx].id
                } else {
                    hoveredSegmentID = segments.last?.id
                }
            }
        )
    }
}

private struct ActivityAppDetailPanel: View {
    let usage: ActivityAppUsage
    var onClose: () -> Void
    private var appColor: Color { AppColorProvider.color(for: usage.displayName.isEmpty ? usage.app : usage.displayName) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(appColor.opacity(0.14)); Image(systemName: "hammer.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(appColor) }.frame(width: 32, height: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) { Text(usage.displayName).font(.system(size: 17, weight: .semibold)).csForeground(CSColor.textPrimary); Text("\(usage.minutes)m").font(.system(size: 14, weight: .medium).monospacedDigit()).csForeground(CSColor.textSecondary) }
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 22, height: 22).background(Circle().fill(Color.cs(CSColor.textTertiary).opacity(0.10))) }.buttonStyle(.plain).csForeground(CSColor.textSecondary).keyboardShortcut(.escape, modifiers: []).accessibilityLabel("Close detail")
            }
            if !usage.files.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Files").font(.csEyebrow(size: 12)).tracking(0.6).csForeground(CSColor.textTertiary).textCase(.uppercase)
                    ForEach(usage.files) { f in HStack(spacing: 8) { Image(systemName: "doc").font(.system(size: 12, weight: .medium)).csForeground(CSColor.textTertiary).frame(width: 14); Text(f.name).font(.system(size: 14)).csForeground(CSColor.textPrimary).lineLimit(1); Spacer(); Text("\(f.minutes)m").font(.system(size: 13).monospacedDigit()).csForeground(CSColor.textSecondary) }.padding(.vertical, 3) }
                }
            } else {
                Text("No file-level breakdown available for this app in this period.").font(.caption).csForeground(CSColor.textTertiary)
            }
            if !usage.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 6) { Text("Sessions").font(.csEyebrow(size: 12)).tracking(0.6).csForeground(CSColor.textTertiary).textCase(.uppercase)
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) { ForEach(usage.sessions, id: \.self) { s in Text(s).font(.caption2.monospacedDigit()).csForeground(CSColor.textSecondary).padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Color.cs(CSColor.textTertiary).opacity(0.08))).overlay(Capsule().strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5)) } } } }
            }
        }.padding(16).frame(width: 320).lgInspector()
    }
}

private struct ActivityWebDetailPanel: View {
    let usage: ActivityWebUsage
    var onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.cs(CSColor.textTertiary).opacity(0.10)); Image(systemName: "globe").font(.system(size: 16, weight: .medium)).csForeground(CSColor.textSecondary) }.frame(width: 32, height: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) { Text(usage.title).font(.system(size: 15, weight: .semibold)).csForeground(CSColor.textPrimary).lineLimit(1); Text(usage.domain).font(.caption2).csForeground(CSColor.textTertiary).lineLimit(1) }
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 22, height: 22).background(Circle().fill(Color.cs(CSColor.textTertiary).opacity(0.10))) }.buttonStyle(.plain).csForeground(CSColor.textSecondary).keyboardShortcut(.escape, modifiers: []).accessibilityLabel("Close detail")
            }
            HStack(spacing: 16) { Label("\(usage.minutes)m active", systemImage: "clock").font(.caption).csForeground(CSColor.textSecondary); Label("\(usage.pages) pages", systemImage: "doc.on.doc").font(.caption).csForeground(CSColor.textSecondary) }
            Text("Browsing history stays local. Domain and visit count only — no private query strings are shown.").font(.caption).csForeground(CSColor.textTertiary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(width: 320).lgInspector()
    }
}
