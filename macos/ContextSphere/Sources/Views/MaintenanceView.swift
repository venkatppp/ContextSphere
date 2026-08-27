import SwiftUI

struct MaintenanceView: View {
    @ObservedObject var viewModel: MaintenanceViewModel
    @State private var showRestoreConfirm: Int64?
    @State private var showCancelRestoreConfirm = false

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
        .confirmationDialog("Restore backup?", isPresented: Binding(get: { showRestoreConfirm != nil }, set: { if !$0 { showRestoreConfirm = nil } }), titleVisibility: .visible) {
            Button("Restore on Next Launch", role: .destructive) {
                if let id = showRestoreConfirm { Task { await viewModel.stageRestore(id: id) } }
            }
            Button("Cancel", role: .cancel) { showRestoreConfirm = nil }
        } message: {
            Text("The selected backup will be validated and staged. It will replace the current database on the next launch. This cannot be undone without another backup.")
        }
        .confirmationDialog("Cancel pending restore?", isPresented: $showCancelRestoreConfirm, titleVisibility: .visible) {
            Button("Cancel Restore", role: .destructive) { Task { await viewModel.cancelRestore() } }
            Button("Keep", role: .cancel) {}
        } message: { Text("The staged restore will be discarded.") }
    }

    private var header: some View {
        ScreenHeader("Maintenance", subtitle: viewModel.integrity.map { $0.ok ? "Integrity OK · \(viewModel.backups.count) backups" : "Integrity issues detected" } ?? "Database health and backups", symbol: "wrench.and.screwdriver") {
            HStack(spacing: 8) {
                Button { Task { await viewModel.refresh() } } label: {
                    if viewModel.isFetching { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }.help("Refresh")
                Menu {
                    Button("Run Integrity Check") { Task { await viewModel.refresh() } }
                    Button("Create Backup") { Task { await viewModel.runBackup() } }
                    Button("Run Maintenance (Vacuum)") { Task { await viewModel.runOptimize() } }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            LoadingView(label: "Checking database…")
        case .failed(let msg):
            if viewModel.integrity == nil { errorState(msg) } else { loadedContent }
        case .loaded:
            loadedContent
        }
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundStyle(.orange)
            Text("Maintenance unavailable").font(.title3.weight(.semibold))
            Text(humanMaintenanceError(msg)).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380).textSelection(.enabled)
            if humanMaintenanceError(msg) != msg {
                Text(msg).font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 380).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Button("Retry") { Task { await viewModel.refresh() } }.buttonStyle(.borderedProminent).accessibilityLabel("Retry maintenance check")
                Button("Create Backup") { Task { await viewModel.runBackup() } }.buttonStyle(.bordered).disabled(viewModel.isFetching)
            }
        }.frame(maxWidth: .infinity).padding(32)
    }

    private func humanMaintenanceError(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower == "empty result" || lower.contains("empty result") {
            return "The maintenance service returned no data. Retry to re-check database health."
        }
        if lower.contains("timed out") { return "The maintenance check timed out. Retry." }
        if lower.contains("core daemon is not running") { return "Core daemon is not running. Reconnect via the status footer." }
        return raw
    }

    private var loadedContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let integ = viewModel.integrity { integrityCard(integ) }
            if let pending = viewModel.pendingRestore {
                pendingCard(pending)
            } else {
                // Valid empty: no pending restore is normal; show subtle hint, not an error.
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    Text("No pending restore").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("A staged restore appears here and applies on next launch.").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            backupsCard
            if let rep = viewModel.lastOptimize { maintenanceResultCard(rep) }
            if let err = viewModel.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(err).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button("Retry") { Task { await viewModel.refresh() } }.buttonStyle(.borderless).controlSize(.small)
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Maintenance warning: \(err)")
            }
        }
    }

    private func integrityCard(_ r: IntegrityReport) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Integrity", subtitle: r.ok ? "OK" : "Failed", symbol: r.ok ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.dbPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Text("Size \(ByteCountFormatter.string(fromByteCount: r.main.databaseSizeBytes, countStyle: .file)) · \(r.main.pageCount) pages · \(r.main.journalMode)").font(.caption2).foregroundStyle(.tertiary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Circle().fill(r.ok ? Color.green : Color.red).frame(width: 10, height: 10)
                }
                if !r.main.foreignKeyCheck.isEmpty {
                    Text("Foreign key issues: \(r.main.foreignKeyCheck.joined(separator: ", "))").font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Label(r.main.integrity.ok ? "integrity_check OK" : "integrity_check failed", systemImage: r.main.integrity.ok ? "checkmark.circle.fill" : "xmark.circle.fill").font(.caption2).foregroundStyle(r.main.integrity.ok ? .green : .red)
                    Label(r.main.quickCheck.ok ? "quick_check OK" : "quick_check failed", systemImage: r.main.quickCheck.ok ? "checkmark.circle.fill" : "xmark.circle.fill").font(.caption2).foregroundStyle(r.main.quickCheck.ok ? .green : .red)
                    Spacer()
                    Text("Freelist \(r.main.freelistCount)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func pendingCard(_ p: RestoreResult) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Pending Restore", systemImage: "arrow.triangle.branch").font(.callout.weight(.semibold))
                Text(p.message).font(.callout).foregroundStyle(.secondary)
                Text("Applies on next launch · \(p.backupPath)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                Button("Cancel Pending Restore") { showCancelRestoreConfirm = true }.buttonStyle(.bordered).controlSize(.small).tint(.red)
            }
        }
    }

    private var backupsCard: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Backups", subtitle: "\(viewModel.backups.count)", symbol: "externaldrive")
                if viewModel.backups.isEmpty {
                    Text("No backups yet — create one to be able to restore.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.backups.prefix(10), id: \.id) { run in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(run.kind.capitalized).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                                    Text(run.status.capitalized).font(.caption2.weight(.semibold)).foregroundStyle(run.status == "success" ? .green : run.status == "failed" ? .red : .orange).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary.opacity(0.3), in: Capsule())
                                }
                                Text(run.path.isEmpty ? run.detail : run.path).font(.callout).lineLimit(1).truncationMode(.middle)
                                Text("\(run.startedAt.relativeTime) · \(ByteCountFormatter.string(fromByteCount: run.sizeBytes, countStyle: .file)) · \(run.durationMs) ms").font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if run.kind == "backup" && run.status == "success" {
                                Button("Restore") { showRestoreConfirm = run.id }.buttonStyle(.bordered).controlSize(.small).tint(.orange)
                            }
                        }
                        Divider().opacity(0.3)
                    }
                }
                HStack(spacing: 8) {
                    Button {
                        Task { await viewModel.runBackup() }
                    } label: { Label("Create Backup", systemImage: "plus.circle.fill") }.buttonStyle(.borderedProminent).controlSize(.small).disabled(viewModel.isFetching)
                    Button {
                        Task { await viewModel.runOptimize() }
                    } label: { Label("Vacuum / Optimize", systemImage: "wand.and.stars") }.buttonStyle(.bordered).controlSize(.small).disabled(viewModel.isFetching)
                }
            }
        }
    }

    private func maintenanceResultCard(_ r: MaintenanceReport) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Last Maintenance", systemImage: "hammer").font(.callout.weight(.semibold))
                Text("Freed \(r.freedPages) pages · \(ByteCountFormatter.string(fromByteCount: r.recoveredBytes, countStyle: .file)) · Vacuum \(r.vacuumRan ? "yes" : "no") · Checkpoint \(r.checkpointedFrames) frames").font(.caption).foregroundStyle(.secondary)
                Text(r.checkedAt.relativeTime).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
