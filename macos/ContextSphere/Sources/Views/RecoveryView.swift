import SwiftUI

struct RecoveryView: View {
    @ObservedObject var viewModel: RecoveryViewModel
    @State private var showSelfHealConfirm = false
    @State private var showRollbackConfirm = false

    @State private var containerWidth: CGFloat = 1024
    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Theme.horizontalPadding(for: containerWidth))
                .padding(.vertical, Theme.pageHeaderVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            Hairline(opacity: Theme.pageHeaderDividerOpacity)
            ScrollView {
                content
                    .padding(.horizontal, Theme.horizontalPadding(for: containerWidth))
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(.automatic)
            .defaultScrollAnchor(.top)
        }
        .overlay {
            GeometryReader { geo in
                Color.clear
                    .onAppear { containerWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in containerWidth = new }
            }
            .frame(height: 0)
        }
        .task { await viewModel.initialLoadIfNeeded() }
        .confirmationDialog("Run self-healing?", isPresented: $showSelfHealConfirm, titleVisibility: .visible) {
            Button("Run Self-Healing") { Task { await viewModel.runSelfHeal() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Checks worker health and restarts stalled monitors. Safe to run.") }
        .confirmationDialog("Rollback to last valid checkpoint?", isPresented: $showRollbackConfirm, titleVisibility: .visible) {
            Button("Rollback", role: .destructive) { Task { await viewModel.runRollback() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Restores state to the last valid checkpoint. Recent uncheckpointed work may be lost.") }
    }

    private var header: some View {
        StandardPageHeader(
            section: .recovery,
            title: "Recovery",
            subtitle: viewModel.status.map { "\($0.status.capitalized) · score \(String(format: "%.0f", $0.overallScore))" } ?? "System health and recovery",
            symbol: AppSection.recovery.symbol,
            eyebrow: NavGroup.system.title.uppercased()
        ) {
            HStack(spacing: 8) {
                Button { Task { await viewModel.refresh() } } label: {
                    if viewModel.isFetching { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium)) }
                }
                .buttonStyle(.borderless)
                .help("Refresh")
                Button("Self-Heal") { showSelfHealConfirm = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Menu {
                    Button("Rollback", role: .destructive) { showRollbackConfirm = true }
                    Divider()
                    Button("Tick Watchdog") { Task { await viewModel.tick() } }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            LoadingView(label: "Loading recovery…")
        case .failed(let msg):
            if viewModel.status == nil { errorState(msg) } else { loadedContent }
        case .loaded:
            loadedContent
        }
    }

    private func errorState(_ msg: String) -> some View {
        EmptyStateView(
            title: "Recovery unavailable",
            message: msg,
            symbol: "exclamationmark.triangle",
            primaryAction: ("Retry", { Task { await viewModel.refresh() } })
        )
    }

    private var loadedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let s = viewModel.status { connectedHealthCard(s) }
            crashesCard
            historyCard
            if let h = viewModel.selfHealResult { selfHealCard(h) }
            if let r = viewModel.rollbackResult { rollbackCard(r) }
            if let t = viewModel.lastTick { Text("Watchdog tick \(t)").font(.caption2).csForeground(CSColor.textTertiary) }
            if let err = viewModel.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle").csForeground(CSColor.warning)
                    Text(err).font(.caption).csForeground(CSColor.textSecondary)
                }
                .padding(10)
                .background(Color.cs(CSColor.surface), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5))
            }
        }
    }

    /// Health score + checkpoint + recovery runs in one connected narrative:
    /// score explains why the system can be healthy despite past interruptions.
    private func connectedHealthCard(_ s: HealthSnapshot) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Health", subtitle: s.status.capitalized, symbol: s.status == "healthy" ? "checkmark.shield.fill" : s.status == "degraded" ? "exclamationmark.shield" : "xmark.shield.fill")
                HStack(alignment: .top, spacing: 16) {
                    HStack(spacing: 12) {
                        Text("\(String(format: "%.0f", s.overallScore))")
                            .font(.system(size: 30, weight: .bold).monospacedDigit())
                            .foregroundStyle(s.status == "healthy" ? Color.cs(CSColor.success) : s.status == "degraded" ? Color.cs(CSColor.warning) : Color.cs(CSColor.error))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Score / 100").font(.caption2).csForeground(CSColor.textSecondary)
                            Text(s.capturedAt.relativeTime).font(.caption2).csForeground(CSColor.textTertiary)
                            if let j = viewModel.latestCheckpoint {
                                Text("Checkpoint #\(j.id) · \(j.createdAt.relativeTime)").font(.caption2).csForeground(CSColor.textSecondary)
                            } else {
                                Text("No checkpoint yet").font(.caption2).csForeground(CSColor.textTertiary)
                            }
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        if let h = viewModel.history, !h.runs.isEmpty {
                            let recovered = h.runs.filter { $0.outcome == "recovered" }.count
                            Text("\(h.runs.count) recovery runs").font(.caption.weight(.medium)).csForeground(CSColor.textSecondary)
                            Text("\(recovered) recovered").font(.caption2).csForeground(CSColor.success)
                        } else if viewModel.crashes.isEmpty {
                            Text("No interruptions").font(.caption2).csForeground(CSColor.textTertiary)
                        }
                        if !s.issues.isEmpty {
                            ForEach(s.issues.prefix(2), id: \.self) { issue in
                                Text(issue).font(.caption2).csForeground(CSColor.warning).lineLimit(1)
                            }
                        }
                    }
                }
                // Narrative bridge: explains why healthy despite historical crashes
                if !viewModel.crashes.isEmpty {
                    let recoveredCount = viewModel.crashes.filter(\.wasRecovered).count
                    let total = viewModel.crashes.count
                    HStack(spacing: 6) {
                        Image(systemName: recoveredCount == total ? "checkmark.seal.fill" : "info.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(recoveredCount == total ? Color.cs(CSColor.success) : Color.cs(CSColor.warning))
                        Text(recoveredCount == total
                             ? "System is healthy because all \(total) past interruptions were recovered via checkpoint."
                             : "\(recoveredCount) of \(total) interruptions were recovered; unresolved items may affect health score.")
                            .font(.caption).csForeground(CSColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color.cs(CSColor.surfaceElevated).opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5))
                } else if let j = viewModel.latestCheckpoint {
                    HStack(spacing: 6) {
                        Image(systemName: "flag.checkered").font(.system(size: 10, weight: .semibold)).csForeground(CSColor.textSecondary)
                        Text("Recovery point is checkpoint #\(j.id) (\(j.state)) — rollback would restore to this state.")
                            .font(.caption).csForeground(CSColor.textSecondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color.cs(CSColor.surfaceElevated).opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                if !s.workers.isEmpty {
                    Divider().opacity(0.5)
                    ForEach(s.workers.prefix(6), id: \.id) { w in
                        HStack {
                            Text(w.worker).font(.caption.weight(.medium))
                            Spacer()
                            Text(w.status).font(.caption2.weight(.semibold)).foregroundStyle(w.status == "healthy" ? Color.cs(CSColor.success) : w.status == "stalled" ? Color.cs(CSColor.warning) : Color.cs(CSColor.error)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.cs(CSColor.borderSubtle), in: Capsule())
                            Text("\(w.executionCount) runs · \(w.consecutiveMisses) misses").font(.caption2).csForeground(CSColor.textSecondary).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func healthCard(_ s: HealthSnapshot) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Health", subtitle: s.status.capitalized, symbol: s.status == "healthy" ? "checkmark.shield.fill" : s.status == "degraded" ? "exclamationmark.shield" : "xmark.shield.fill")
                HStack(spacing: 16) {
                    Text("\(String(format: "%.0f", s.overallScore))").font(.system(size: 28, weight: .bold).monospacedDigit()).foregroundStyle(s.status == "healthy" ? Color.cs(CSColor.success) : s.status == "degraded" ? Color.cs(CSColor.warning) : Color.cs(CSColor.error))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Score / 100").font(.caption2).csForeground(CSColor.textSecondary)
                        Text(s.capturedAt.relativeTime).font(.caption2).csForeground(CSColor.textTertiary)
                    }
                    Spacer()
                    if !s.issues.isEmpty {
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(s.issues.prefix(3), id: \.self) { issue in
                                Text(issue).font(.caption2).csForeground(CSColor.warning).lineLimit(1)
                            }
                        }
                    }
                }
                if !s.workers.isEmpty {
                    Divider().opacity(0.5)
                    ForEach(s.workers.prefix(6), id: \.id) { w in
                        HStack {
                            Text(w.worker).font(.caption.weight(.medium))
                            Spacer()
                            Text(w.status).font(.caption2.weight(.semibold)).foregroundStyle(w.status == "healthy" ? Color.cs(CSColor.success) : w.status == "stalled" ? Color.cs(CSColor.warning) : Color.cs(CSColor.error)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.cs(CSColor.borderSubtle), in: Capsule())
                            Text("\(w.executionCount) runs · \(w.consecutiveMisses) misses").font(.caption2).csForeground(CSColor.textSecondary).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func checkpointCard(_ j: RecoveryJournalEntry) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Latest Checkpoint", systemImage: "flag.checkered").font(.callout.weight(.semibold))
                Text("ID \(j.id) · \(j.entryType) · \(j.scope)/\(j.entity) · \(j.state)").font(.caption).csForeground(CSColor.textSecondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Text(j.createdAt.relativeTime).font(.caption2).csForeground(CSColor.textTertiary)
                if j.checksum != "0000000000000000" {
                    Text("Checksum \(j.checksum.prefix(8))…").font(.caption2.monospaced()).csForeground(CSColor.textTertiary)
                }
            }
        }
    }

    private var crashesCard: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Interruptions", subtitle: "\(viewModel.crashes.count) total", symbol: "exclamationmark.octagon")
                Text("Timeout · Unexpected shutdown · Crash · Recovered — each is logged and, when recovered, does not affect current health.")
                    .font(.caption2).csForeground(CSColor.textTertiary).fixedSize(horizontal: false, vertical: true)
                if viewModel.crashes.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").csForeground(CSColor.success)
                        Text("No interruptions recorded — recovery journal is clean.").font(.callout).csForeground(CSColor.textSecondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    VStack(spacing: 8) {
                        ForEach(viewModel.crashes.prefix(5), id: \.id) { c in
                            HStack(alignment: .top, spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(crashColor(c).opacity(0.14))
                                    Image(systemName: crashSymbol(c)).font(.system(size: 11, weight: .semibold)).foregroundStyle(crashColor(c))
                                }.frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(c.component).font(.callout.weight(.medium)).lineLimit(1)
                                        Text(crashLabel(c)).font(.caption2.weight(.semibold))
                                            .foregroundStyle(crashColor(c))
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(crashColor(c).opacity(0.13), in: Capsule())
                                        Spacer()
                                        CSStatusBadge(text: c.wasRecovered ? "Recovered" : "Unrecovered", kind: c.wasRecovered ? .success : .error)
                                    }
                                    Text(c.message).font(.caption).csForeground(CSColor.textSecondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                    Text("\(c.reportedAt.relativeTime) · \(c.severity.capitalized)").font(.caption2).csForeground(CSColor.textTertiary)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(Color.cs(CSColor.surfaceElevated).opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous).strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5))
                        }
                    }
                    if viewModel.crashes.count > 5 {
                        Text("\(viewModel.crashes.count - 5) older interruptions retained").font(.caption2).csForeground(CSColor.textTertiary)
                    }
                }
            }
        }
    }

    private func crashLabel(_ c: CrashReport) -> String {
        switch c.crashType.lowercased() {
        case "timeout": return "Timeout"
        case "panic", "crash": return "Crash"
        case "unexpected_shutdown", "shutdown": return "Unexpected shutdown"
        case "oom", "out_of_memory": return "Out of memory"
        default: return c.crashType.capitalized.replacingOccurrences(of: "_", with: " ")
        }
    }
    private func crashSymbol(_ c: CrashReport) -> String {
        switch c.crashType.lowercased() {
        case "timeout": return "clock.badge.exclamationmark"
        case "panic", "crash": return "exclamationmark.octagon.fill"
        case "unexpected_shutdown", "shutdown": return "power"
        case "oom", "out_of_memory": return "memorychip"
        default: return "exclamationmark.triangle"
        }
    }
    private func crashColor(_ c: CrashReport) -> Color {
        if c.wasRecovered { return Color.cs(CSColor.success) }
        switch c.crashType.lowercased() {
        case "timeout": return Color.cs(CSColor.warning)
        case "panic", "crash": return Color.cs(CSColor.error)
        case "unexpected_shutdown", "shutdown": return Color.cs(CSColor.warning)
        default: return Color.cs(CSColor.textSecondary)
        }
    }

    private var historyCard: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Recovery journal", subtitle: viewModel.history.map { "\($0.journal.count) entries · \(viewModel.history?.runs.count ?? 0) runs" } ?? "—", symbol: "list.bullet.rectangle")
                if let h = viewModel.history, !h.journal.isEmpty {
                    Text("Every checkpoint and recovery run is appended here. The latest checkpoint is the restore point; runs show what was healed.")
                        .font(.caption2).csForeground(CSColor.textTertiary).fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 4) {
                        ForEach(h.journal.prefix(6), id: \.id) { e in
                            HStack(spacing: 8) {
                                Text(e.entryType).font(.caption.weight(.medium)).csForeground(CSColor.textPrimary).frame(width: 96, alignment: .leading).lineLimit(1)
                                Text(e.scope + "/" + e.entity).font(.caption2).csForeground(CSColor.textSecondary).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(e.createdAt.relativeTime).font(.caption2).csForeground(CSColor.textTertiary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.cs(CSColor.surfaceElevated).opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                    if !h.runs.isEmpty {
                        Divider().opacity(0.4)
                        Text("Recent recovery runs").font(.caption2.weight(.semibold)).csForeground(CSColor.textSecondary).textCase(.uppercase).tracking(0.4)
                        VStack(spacing: 6) {
                            ForEach(h.runs.prefix(3), id: \.id) { r in
                                HStack(spacing: 8) {
                                    Text(r.trigger).font(.caption.weight(.medium)).lineLimit(1)
                                    Text(r.outcome).font(.caption2.weight(.semibold)).foregroundStyle(r.outcome == "recovered" ? Color.cs(CSColor.success) : Color.cs(CSColor.warning)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.cs(CSColor.borderSubtle), in: Capsule())
                                    Spacer()
                                    Text("\(r.actions.count) actions · \(r.durationMs) ms").font(.caption2).csForeground(CSColor.textSecondary).monospacedDigit()
                                }
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(Color.cs(CSColor.surfaceElevated).opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No journal entries yet.").font(.callout).csForeground(CSColor.textSecondary)
                        Text("Checkpoints and recovery runs will appear here once the system has operated.").font(.caption).csForeground(CSColor.textTertiary)
                    }
                }
            }
        }
    }

    private func selfHealCard(_ r: SelfHealingReport) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 6) {
                Label("Last Self-Healing", systemImage: "wand.and.stars").font(.callout.weight(.semibold))
                Text("Executed \(r.executed.count) · Failed \(r.failed.count) · Healed \(r.healedWorkers.count) workers · \(r.ranAt.relativeTime)").font(.caption).csForeground(CSColor.textSecondary)
            }
        }
    }

    private func rollbackCard(_ r: RollbackResult) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 6) {
                Label(r.ok ? "Rollback Succeeded" : "Rollback", systemImage: r.ok ? "checkmark.circle.fill" : "arrow.uturn.backward.circle").font(.callout.weight(.semibold)).foregroundStyle(r.ok ? Color.cs(CSColor.success) : .secondary)
                Text(r.message).font(.callout).csForeground(CSColor.textSecondary)
                if let to = r.rolledBackTo { Text("To journal \(to)").font(.caption2).csForeground(CSColor.textTertiary) }
            }
        }
    }
}
