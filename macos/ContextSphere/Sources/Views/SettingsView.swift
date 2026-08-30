import SwiftUI
import AppKit

/// Native macOS preferences experience for ContextSphere. Organized as a
/// real settings window: a sidebar of categories, a detail pane for each,
/// every control binds to `SettingsViewModel`, which speaks JSON-RPC — the
/// UI never touches the database directly.
///
/// LLM & Copilot have been removed entirely (RC-9 §2). Watched Paths
/// is merged into General (RC-9 §19). Appearance (theme) lives in General.
struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @ObservedObject private var appearance = AppearanceController.shared
    @State private var category: Category = .general
    @State private var detailWidth: CGFloat = 600

    enum Category: String, CaseIterable, Identifiable, Hashable {
        case general, security

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .security: "Security"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .security: "lock.shield"
            }
        }

        var summary: String {
            switch self {
            case .general: "Sessions, watched paths, and appearance."
            case .security: "Background monitoring and audit retention."
            }
        }
    }

    var body: some View {
        Group {
            switch viewModel.phase {
            case .loading:
                LoadingView(label: "Loading settings…")
            case .failed:
                errorState
            case .loaded:
                content
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .task { await viewModel.refresh() }
    }

    // MARK: - Content (split layout)

    private var content: some View {
        HStack(spacing: 0) {
            categoryList
                .frame(width: 220)
            Divider().opacity(0.4)
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.cs(CSColor.surface))
        }
    }

    private var categoryList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                    .csForeground(CSColor.textTertiary)
                Text("Categories")
                    .font(.csEyebrow(size: 10))
                    .tracking(0.7)
                    .csForeground(CSColor.textTertiary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 8)

            VStack(spacing: 4) {
                ForEach(Category.allCases) { cat in
                    categoryRow(cat)
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            VStack(alignment: .leading, spacing: 4) {
                Hairline()
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10, weight: .medium))
                        .csForeground(CSColor.textTertiary)
                    Text("ContextSphere v\(CoreBridge.shared.backendVersion ?? "—")")
                        .font(.caption2.monospacedDigit())
                        .csForeground(CSColor.textTertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .lgSidebarBackground()
    }

    private func categoryRow(_ cat: Category) -> some View {
        let isSelected = cat == category
        return Button {
            category = cat
        } label: {
            HStack(spacing: 8) {
                Image(systemName: cat.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                    .csForeground(isSelected
                                  ? CSColor.sidebarSelectedTint
                                  : CSColor.textSecondary)
                Text(cat.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .csForeground(isSelected
                                  ? CSColor.textPrimary
                                  : CSColor.textPrimary)
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.cs(CSColor.sidebarSelectedFill) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cat.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Detail

    private var detailColumn: some View {
        VStack(spacing: 0) {
            detailHeader
                .padding(.horizontal, Theme.horizontalPadding(for: detailWidth))
                .padding(.vertical, Theme.pageHeaderVerticalPadding)
            Hairline(opacity: Theme.pageHeaderDividerOpacity)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detailContent
                }
                .padding(.horizontal, Theme.horizontalPadding(for: detailWidth))
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
            .defaultScrollAnchor(.top)
        }
        .background(Color.cs(CSColor.surface))
        .overlay {
            GeometryReader { geo in
                Color.clear
                    .onAppear { detailWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in detailWidth = new }
            }
        }
    }

    private var detailHeader: some View {
        ScreenHeader(category.title,
                     subtitle: category.summary,
                     symbol: category.symbol,
                     eyebrow: NavGroup.system.title.uppercased())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch category {
        case .general: generalSection
        case .security: securitySection
        }
    }

    private var errorState: some View {
        EmptyStateView(
            title: "Could not load settings",
            message: viewModel.lastErrorMessage ?? "Unknown error.",
            symbol: "exclamationmark.triangle",
            primaryAction: ("Retry", { Task { await viewModel.refresh() } })
        )
    }

    // MARK: - General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Sessions
            SettingsCard(title: "Sessions",
                         subtitle: "When a work session ends",
                         symbol: "clock.arrow.circlepath") {
                LabeledContent("Session inactivity threshold") {
                    Stepper(value: $viewModel.thresholdSeconds,
                            in: SettingsViewModel.thresholdRange, step: 60) {
                        Text(formattedDuration(viewModel.thresholdSeconds))
                            .monospacedDigit()
                    }
                    .accessibilityLabel("Session inactivity threshold")
                    .help("A session ends after this long without activity")
                }
                if case .failed(let message) = viewModel.thresholdSave {
                    Text(message).font(.caption).csForeground(CSColor.error)
                }
                HStack {
                    if viewModel.thresholdDirty {
                        Button("Revert") { viewModel.revertThreshold() }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Revert session threshold changes")
                    }
                    Spacer()
                    statusBadge(viewModel.thresholdSave)
                }
            }
            .onChange(of: viewModel.thresholdSeconds) { _, _ in
                viewModel.scheduleThresholdSave()
            }

            // Watched Paths (merged from old Watched Paths section)
            SettingsCard(title: "Watched directories",
                         subtitle: "Folders ContextSphere observes for activity",
                         symbol: "folder.badge.gearshape") {
                if viewModel.watchedPaths.isEmpty {
                    Text("No watched directories. Add one below to start tracking activity.")
                        .font(.callout)
                        .csForeground(CSColor.textSecondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(viewModel.watchedPaths, id: \.self) { path in
                            watchedPathRow(path)
                            if path != viewModel.watchedPaths.last {
                                Divider().opacity(0.25)
                            }
                        }
                    }
                }
            }

            SettingsCard(title: "Add a directory",
                         subtitle: "The path is validated before watching",
                         symbol: "plus.circle") {
                HStack(spacing: 8) {
                    TextField("/path/to/folder", text: $viewModel.watchPathInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Directory path to watch")
                        .onSubmit {
                            Task { await viewModel.addWatchPath() }
                        }
                    Button("Choose…") { viewModel.chooseWatchPath() }
                        .accessibilityLabel("Choose a directory to watch")
                    Button("Add") {
                        Task { await viewModel.addWatchPath() }
                    }
                    .disabled(viewModel.watchPathInput
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Add directory to watched paths")
                }
                if case .failed(let message) = viewModel.watchAddState {
                    Text(message).font(.caption).csForeground(CSColor.error)
                } else if case .saved = viewModel.watchAddState {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .csForeground(CSColor.success)
                }
            }

            // Appearance / Theme
            SettingsCard(title: "Appearance",
                         subtitle: "Theme is applied across the entire app",
                         symbol: "paintpalette") {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Theme")
                            .font(.callout.weight(.medium))
                            .csForeground(CSColor.textPrimary)
                        Text("Choose Dark, Light, or follow the system appearance.")
                            .font(.caption)
                            .csForeground(CSColor.textSecondary)
                    }
                    Spacer()
                    Picker("Theme", selection: $appearance.mode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.symbol).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                    .accessibilityLabel("Theme")
                }
                // Visual swatches
                HStack(alignment: .top, spacing: 12) {
                    themeSwatch(label: "Dark",
                                top: Color(red: 0.085, green: 0.090, blue: 0.115),
                                bottom: Color(red: 0.055, green: 0.060, blue: 0.085),
                                isActive: appearance.mode == .dark)
                    themeSwatch(label: "Light",
                                top: Color(red: 0.985, green: 0.988, blue: 0.995),
                                bottom: Color(red: 0.945, green: 0.955, blue: 0.975),
                                isActive: appearance.mode == .light)
                    themeSwatch(label: "System",
                                top: Color(red: 0.55, green: 0.55, blue: 0.58),
                                bottom: Color(red: 0.30, green: 0.30, blue: 0.34),
                                isActive: appearance.mode == .system)
                }
            }
        }
    }

    private func themeSwatch(label: String, top: Color, bottom: Color, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                // Mini content mock
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(.white.opacity(0.6)).frame(width: 36, height: 4)
                    Capsule().fill(.white.opacity(0.25)).frame(width: 60, height: 3)
                    HStack(spacing: 3) {
                        Circle().fill(.white.opacity(0.4)).frame(width: 8, height: 8)
                        Capsule().fill(.white.opacity(0.20)).frame(width: 30, height: 3)
                    }
                }
                .padding(8)
            }
            .frame(width: 100, height: 64)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isActive ? Color.accentColor : Color.cs(CSColor.border),
                                  lineWidth: isActive ? 2 : 0.5)
            )
            Text(label)
                .font(.caption2.weight(isActive ? .semibold : .regular))
                .csForeground(isActive ? CSColor.sidebarSelectedTint : CSColor.textSecondary)
        }
    }

    private func formattedDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private func watchedPathRow(_ path: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .csForeground(CSColor.textSecondary)
            Text(path)
                .lineLimit(1)
                .truncationMode(.middle)
                .csForeground(CSColor.textPrimary)
            Spacer()
            if let error = viewModel.watchPathErrors[path] {
                Image(systemName: "exclamationmark.triangle.fill")
                    .csForeground(CSColor.error)
                    .help(error)
                    .accessibilityLabel(error)
            }
            Button {
                Task { await viewModel.removeWatchPath(path) }
            } label: {
                Image(systemName: "minus.circle")
                    .csForeground(CSColor.textSecondary)
            }
            .buttonStyle(.borderless)
            .help("Stop watching this directory")
            .accessibilityLabel("Remove \(path) from watched paths")
        }
        .padding(.vertical, 6)
    }

    // MARK: - Security

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            securitySummaryCard
            SettingsCard(title: "Policy",
                         subtitle: "Unset values use the backend defaults",
                         symbol: "lock.shield") {
                securityStepperRow(title: "Monitor interval",
                                   value: $viewModel.monitorIntervalSeconds,
                                   range: SettingsViewModel.monitorRange,
                                   step: 30,
                                   unit: "s",
                                   key: SettingsViewModel.monitorKey,
                                   dirty: viewModel.monitorDirty)
                securityStepperRow(title: "Audit log retention",
                                   value: $viewModel.auditRetentionDays,
                                   range: SettingsViewModel.retentionRange,
                                   step: 1,
                                   unit: "days",
                                   key: SettingsViewModel.auditKey,
                                   dirty: viewModel.auditDirty)
                securityStepperRow(title: "Findings history retention",
                                   value: $viewModel.findingsRetentionDays,
                                   range: SettingsViewModel.retentionRange,
                                   step: 1,
                                   unit: "days",
                                   key: SettingsViewModel.findingsKey,
                                   dirty: viewModel.findingsDirty)
            }
            if !viewModel.securityRecommendations.isEmpty {
                securityFindingsCard
            }
        }
        .onChange(of: viewModel.monitorIntervalSeconds) { _, _ in
            viewModel.scheduleSecuritySave(key: SettingsViewModel.monitorKey,
                                           value: viewModel.monitorIntervalSeconds)
        }
        .onChange(of: viewModel.auditRetentionDays) { _, _ in
            viewModel.scheduleSecuritySave(key: SettingsViewModel.auditKey,
                                           value: viewModel.auditRetentionDays)
        }
        .onChange(of: viewModel.findingsRetentionDays) { _, _ in
            viewModel.scheduleSecuritySave(key: SettingsViewModel.findingsKey,
                                           value: viewModel.findingsRetentionDays)
        }
    }

    private var securitySummaryCard: some View {
        SettingsCard(title: "Security posture", subtitle: viewModel.securityScore.map { "\($0.status.capitalized) · score \(String(format: "%.0f", $0.score))" } ?? "Monitoring and findings summary", symbol: "shield.lefthalf.filled") {
            if let score = viewModel.securityScore {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Circle().fill(score.status == "excellent" || score.status == "good" ? Color.cs(CSColor.success) : score.status == "fair" ? Color.cs(CSColor.warning) : Color.cs(CSColor.error)).frame(width: 8, height: 8)
                            Text("\(String(format: "%.0f", score.score)) / 100").font(.system(size: 22, weight: .bold).monospacedDigit()).csForeground(CSColor.textPrimary)
                            CSStatusBadge(text: score.status.capitalized, kind: score.status == "excellent" || score.status == "good" ? .success : score.status == "fair" ? .warning : .error)
                        }
                        Text("\(score.passedChecks) of \(score.totalChecks) checks passed · \(score.failedChecks) failed").font(.caption).csForeground(CSColor.textSecondary)
                        Text("Checked \(score.scoredAt.relativeTime)").font(.caption2).csForeground(CSColor.textTertiary)
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 6) {
                        Label("Monitoring every \(viewModel.monitorIntervalSeconds)s", systemImage: "clock.arrow.circlepath")
                            .font(.caption.weight(.medium)).csForeground(CSColor.textSecondary)
                        let unresolved = score.unresolved
                        if unresolved.isEmpty {
                            Label("No unresolved findings", systemImage: "checkmark.shield.fill").font(.caption).csForeground(CSColor.success)
                        } else {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(unresolved.count) unresolved finding\(unresolved.count == 1 ? "" : "s")").font(.caption.weight(.semibold)).csForeground(CSColor.warning)
                                ForEach(unresolved.prefix(2), id: \.id) { f in
                                    Text(f.checkName.replacingOccurrences(of: "_", with: " ").capitalized).font(.caption2).csForeground(CSColor.textSecondary).lineLimit(1)
                                }
                            }
                        }
                        if !viewModel.securityRecommendations.isEmpty {
                            let open = viewModel.securityRecommendations.filter { $0.status == "open" }.count
                            if open > 0 {
                                Text("\(open) actionable recommendation\(open == 1 ? "" : "s")").font(.caption2).csForeground(CSColor.info)
                            }
                        }
                    }
                }
                if let err = viewModel.securityStatusError {
                    Text(err).font(.caption2).csForeground(CSColor.textTertiary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading security posture…").font(.caption).csForeground(CSColor.textSecondary)
                    }
                    HStack(spacing: 8) {
                        Label("Monitoring every \(viewModel.monitorIntervalSeconds)s", systemImage: "clock.arrow.circlepath").font(.caption).csForeground(CSColor.textSecondary)
                        Spacer()
                        Text("Findings will appear after the first monitor pass").font(.caption2).csForeground(CSColor.textTertiary)
                    }
                    if let err = viewModel.securityStatusError {
                        Text(err).font(.caption2).csForeground(CSColor.warning)
                    }
                }
            }
        }
    }

    private var securityFindingsCard: some View {
        SettingsCard(title: "Findings & recommendations", subtitle: "\(viewModel.securityRecommendations.filter { $0.status == "open" }.count) open", symbol: "exclamationmark.shield") {
            if viewModel.securityRecommendations.isEmpty {
                Text("No recommendations — your security posture is clean.").font(.callout).csForeground(CSColor.textSecondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(viewModel.securityRecommendations.filter { $0.status == "open" }.prefix(4)) { rec in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(rec.title).font(.callout.weight(.medium)).lineLimit(1)
                                    Text(rec.severity.capitalized).font(.caption2.weight(.semibold))
                                        .foregroundStyle(rec.severity == "critical" ? Color.cs(CSColor.error) : rec.severity == "warning" ? Color.cs(CSColor.warning) : Color.cs(CSColor.info))
                                        .padding(.horizontal, 6).padding(.vertical, 2).background(Color.cs(CSColor.borderSubtle), in: Capsule())
                                }
                                Text(rec.detail).font(.caption).csForeground(CSColor.textSecondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color.cs(CSColor.surfaceElevated).opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5))
                    }
                    if viewModel.securityRecommendations.filter({ $0.status == "open" }).count > 4 {
                        Text("\(viewModel.securityRecommendations.filter({ $0.status == "open" }).count - 4) more recommendations retained").font(.caption2).csForeground(CSColor.textTertiary)
                    }
                }
            }
        }
    }

    private func securityStepperRow(title: String, value: Binding<Int>,
                                    range: ClosedRange<Int>, step: Int,
                                    unit: String, key: String,
                                    dirty: Bool) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Stepper(value: value, in: range, step: step) {
                    Text("\(value.wrappedValue) \(unit)")
                        .monospacedDigit()
                        .csForeground(CSColor.textPrimary)
                }
                .accessibilityLabel(title)
                if dirty {
                    Button("Revert") { viewModel.revertSecurity(key: key) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Revert \(title)")
                }
                statusBadge(viewModel.securitySave[key] ?? .idle)
            }
        }
    }

    // MARK: - Shared status feedback

    @ViewBuilder
    private func statusBadge(_ state: SettingsSaveState, savedTitle: String = "Saved") -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .saving:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Working…").font(.caption).csForeground(CSColor.textSecondary)
            }
            .accessibilityLabel("Working")
        case .saved:
            Label(savedTitle, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .csForeground(CSColor.success)
                .accessibilityLabel(savedTitle)
        case .failed(let message):
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .csForeground(CSColor.error)
                .help(message)
                .accessibilityLabel("Failed: \(message)")
        }
    }
}

// MARK: - Settings card

struct SettingsCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .csForeground(CSColor.info)
                }
                Text(title)
                    .font(.csSectionTitle)
                    .csForeground(CSColor.textPrimary)
                if let subtitle {
                    Text("·")
                        .csForeground(CSColor.textTertiary)
                    Text(subtitle)
                        .font(.caption)
                        .csForeground(CSColor.textSecondary)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.cs(CSColor.surface),
            in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                .strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5)
        )
    }
}

extension SettingsViewModel {
    var lastErrorMessage: String? {
        if case .failed(let msg) = phase { return msg }
        return nil
    }
}
