import SwiftUI

struct RecoveryView: View {
    @ObservedObject var viewModel: RecoveryViewModel
    @State private var showSelfHealConfirm = false
    @State private var showRollbackConfirm = false

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: Theme.contentMaxWidth)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .safeAreaInset(edge: .top, spacing: 8) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        ScreenHeader("Recovery",
                     subtitle: viewModel.status.map { "\($0.status.capitalized) · score \(String(format: "%.0f", $0.overallScore))" } ?? "System health and recovery",
                     symbol: "heart.text.square",
                     eyebrow: "System") {
            HStack(spacing: 8) {
                Button { Task { await viewModel.refresh() } } label: {
                    if viewModel.isFetching { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium)) }
                }
                .buttonStyle(.borderless)
                .help("Refresh")
                Menu {
                    Button("Self-Heal") { showSelfHealConfirm = true }
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
        VStack(alignment: .leading, spacing: 20) {
            if let s = viewModel.status { healthCard(s) }
            if let j = viewModel.latestCheckpoint { checkpointCard(j) }
            crashesCard
            historyCard
            if let h = viewModel.selfHealResult { selfHealCard(h) }
            if let r = viewModel.rollbackResult { rollbackCard(r) }
            if let t = viewModel.lastTick { Text("Watchdog tick \(t)").font(.caption2).csForeground(CSColor.textTertiary) }
            if let err = viewModel.lastError { Text(err).font(.caption).csForeground(CSColor.error) }
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
                SectionHeader(title: "Crashes", subtitle: "\(viewModel.crashes.count)", symbol: "exclamationmark.octagon")
                if viewModel.crashes.isEmpty {
                    Text("No crashes recorded — recovery journal is clean.").font(.callout).csForeground(CSColor.textSecondary)
                } else {
                    ForEach(viewModel.crashes.prefix(5), id: \.id) { c in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(c.component).font(.callout.weight(.medium))
                                Spacer()
                                Text(c.crashType).font(.caption2.weight(.semibold)).foregroundStyle(c.wasRecovered ? Color.cs(CSColor.success) : Color.cs(CSColor.error)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.cs(CSColor.borderSubtle), in: Capsule())
                            }
                            Text(c.message).font(.caption).csForeground(CSColor.textSecondary).lineLimit(2)
                            Text("\(c.reportedAt.relativeTime) · \(c.severity) · recovered: \(c.wasRecovered ? "yes" : "no")").font(.caption2).csForeground(CSColor.textTertiary)
                        }
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }

    private var historyCard: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Journal", subtitle: viewModel.history.map { "\($0.journal.count) entries" } ?? "—", symbol: "list.bullet.rectangle")
                if let h = viewModel.history, !h.journal.isEmpty {
                    ForEach(h.journal.prefix(10), id: \.id) { e in
                        HStack {
                            Text(e.entryType).font(.caption.weight(.medium)).csForeground(CSColor.textPrimary).frame(width: 90, alignment: .leading)
                            Text(e.scope + "/" + e.entity).font(.caption2).csForeground(CSColor.textSecondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(e.createdAt.relativeTime).font(.caption2).csForeground(CSColor.textTertiary)
                        }
                    }
                    if !h.runs.isEmpty {
                        Divider().opacity(0.5)
                        ForEach(h.runs.prefix(3), id: \.id) { r in
                            HStack {
                                Text(r.trigger).font(.caption.weight(.medium))
                                Text(r.outcome).font(.caption2).foregroundStyle(r.outcome == "recovered" ? Color.cs(CSColor.success) : Color.cs(CSColor.warning)).padding(.horizontal, 5).padding(.vertical, 1).background(Color.cs(CSColor.borderSubtle), in: Capsule())
                                Spacer()
                                Text("\(r.actions.count) actions · \(r.durationMs) ms").font(.caption2).csForeground(CSColor.textSecondary).monospacedDigit()
                            }
                        }
                    }
                } else {
                    Text("No journal entries yet.").font(.callout).csForeground(CSColor.textSecondary)
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
