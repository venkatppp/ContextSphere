import SwiftUI

struct MaintenanceView: View {
    @ObservedObject var viewModel: MaintenanceViewModel
    @State private var showRestoreConfirm: Int64?
    @State private var showCancelRestoreConfirm = false

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
        StandardPageHeader(
            section: .maintenance,
            title: "Maintenance",
            subtitle: viewModel.integrity.map { $0.ok ? "Integrity OK · \(viewModel.backups.count) backups" : "Integrity issues detected" } ?? "Database health and backups",
            symbol: AppSection.maintenance.symbol,
            eyebrow: NavGroup.system.title.uppercased()
        ) {
            HStack(spacing: 8) {
                Button { Task { await viewModel.refresh() } } label: {
                    if viewModel.isFetching { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium)) }
                }
                .buttonStyle(.borderless)
                .help("Refresh")
                Button { Task { await viewModel.runBackup() } } label: {
                    Label("Backup", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.isFetching)
                Menu {
                    Button("Run Integrity Check") { Task { await viewModel.refresh() } }
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
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .light))
                .csForeground(CSColor.warning)
            Text("Maintenance unavailable")
                .font(.title3.weight(.semibold))
            Text(humanMaintenanceError(msg))
                .font(.callout)
                .csForeground(CSColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .textSelection(.enabled)
            if humanMaintenanceError(msg) != msg {
                Text(msg)
                    .font(.caption)
                    .csForeground(CSColor.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Button("Retry") { Task { await viewModel.refresh() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Retry maintenance check")
                Button("Create Backup") { Task { await viewModel.runBackup() } }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isFetching)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func humanMaintenanceError(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower == "empty result" || lower.contains("empty result") {
            return "The maintenance service returned no data. Retry to re-check database health."
        }
        if lower.contains("timed out") { return "The maintenance check timed out. Retry." }
        if lower.contains("core daemon is not running") { return "Connection unavailable. Try Refresh to reconnect." }
        return raw
    }

    private var loadedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Concise summary row: integrity + backup count + last optimize
            if let integ = viewModel.integrity { summaryCard(integ) }
            if let pending = viewModel.pendingRestore {
                pendingCard(pending)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 10, weight: .semibold)).csForeground(CSColor.success)
                    Text("No pending restore").font(.caption).csForeground(CSColor.textSecondary)
                    Spacer()
                    Text("A staged restore applies on next launch").font(.caption2).csForeground(CSColor.textTertiary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.cs(CSColor.surface).opacity(0.85), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5))
            }
            backupsCardCompact
            if let rep = viewModel.lastOptimize { maintenanceResultCard(rep) }
            if let err = viewModel.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle").csForeground(CSColor.warning)
                    Text(err).font(.caption).csForeground(CSColor.textSecondary).textSelection(.enabled)
                    Spacer()
                    Button("Retry") { Task { await viewModel.refresh() } }.buttonStyle(.borderless).controlSize(.small)
                }
                .padding(10)
                .background(Color.cs(CSColor.surface), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5))
                .accessibilityLabel("Maintenance warning: \(err)")
            }
        }
    }

    private func summaryCard(_ r: IntegrityReport) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Database", subtitle: r.ok ? "Healthy" : "Needs attention", symbol: r.ok ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle().fill(r.ok ? Color.cs(CSColor.success) : Color.cs(CSColor.error)).frame(width: 8, height: 8)
                            Text(r.ok ? "Integrity OK" : "Integrity issues").font(.caption.weight(.semibold)).csForeground(r.ok ? CSColor.success : CSColor.error)
                            Text("· \(viewModel.backups.count) backups").font(.caption).csForeground(CSColor.textSecondary)
                            if let rep = viewModel.lastOptimize {
                                Text("· last vacuum \(rep.checkedAt.relativeTime)").font(.caption2).csForeground(CSColor.textTertiary)
                            }
                        }
                        Text(r.dbPath).font(.caption2.monospaced()).csForeground(CSColor.textSecondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Text("\(ByteCountFormatter.string(fromByteCount: r.main.databaseSizeBytes, countStyle: .file)) · \(r.main.pageCount) pages · \(r.main.journalMode) · freelist \(r.main.freelistCount)")
                            .font(.caption2).csForeground(CSColor.textTertiary)
                    }
                    Spacer(minLength: 12)
                }
                HStack(spacing: 8) {
                    Label(r.main.integrity.ok ? "integrity_check OK" : "integrity_check failed", systemImage: r.main.integrity.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption2).foregroundStyle(r.main.integrity.ok ? Color.cs(CSColor.success) : Color.cs(CSColor.error))
                    Label(r.main.quickCheck.ok ? "quick_check OK" : "quick_check failed", systemImage: r.main.quickCheck.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption2).foregroundStyle(r.main.quickCheck.ok ? Color.cs(CSColor.success) : Color.cs(CSColor.error))
                    if !r.main.foreignKeyCheck.isEmpty {
                        Text("· \(r.main.foreignKeyCheck.count) foreign-key issues").font(.caption2).csForeground(CSColor.error)
                    }
                }
            }
        }
    }

    private func pendingCard(_ p: RestoreResult) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Pending Restore", systemImage: "arrow.triangle.branch").font(.callout.weight(.semibold))
                Text(p.message).font(.callout).csForeground(CSColor.textSecondary)
                Text("Applies on next launch · \(p.backupPath)").font(.caption2).csForeground(CSColor.textTertiary).lineLimit(1).truncationMode(.middle)
                Button("Cancel Pending Restore") { showCancelRestoreConfirm = true }.buttonStyle(.bordered).controlSize(.small).tint(Color.cs(CSColor.error))
            }
        }
    }

    private var backupsCardCompact: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SectionHeader(title: "Recent backups", subtitle: "\(viewModel.backups.count) total", symbol: "externaldrive")
                    Spacer()
                    if !viewModel.backups.isEmpty {
                        Text("Showing last 5").font(.caption2).csForeground(CSColor.textTertiary)
                    }
                }
                if viewModel.backups.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No backups yet").font(.callout.weight(.medium)).csForeground(CSColor.textPrimary)
                        Text("Create one to be able to restore. Backups are validated before a restore is staged.").font(.caption).csForeground(CSColor.textSecondary)
                        Button { Task { await viewModel.runBackup() } } label: { Label("Create Backup", systemImage: "plus.circle.fill") }
                            .buttonStyle(.borderedProminent).controlSize(.small).disabled(viewModel.isFetching)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 6) {
                        ForEach(viewModel.backups.prefix(5), id: \.id) { run in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(run.kind.capitalized).font(.caption2.weight(.semibold)).csForeground(CSColor.textSecondary).textCase(.uppercase)
                                        Text(run.status.capitalized).font(.caption2.weight(.semibold))
                                            .foregroundStyle(run.status == "success" ? Color.cs(CSColor.success) : run.status == "failed" ? Color.cs(CSColor.error) : Color.cs(CSColor.warning))
                                            .padding(.horizontal, 5).padding(.vertical, 1).background(Color.cs(CSColor.borderSubtle), in: Capsule())
                                        Text(run.startedAt.relativeTime).font(.caption2).csForeground(CSColor.textTertiary)
                                        Text("· \(ByteCountFormatter.string(fromByteCount: run.sizeBytes, countStyle: .file))").font(.caption2).csForeground(CSColor.textTertiary)
                                    }
                                    Text(run.path.isEmpty ? run.detail : run.path).font(.caption).csForeground(CSColor.textSecondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 8)
                                if run.kind == "backup" && run.status == "success" {
                                    Button("Restore") { showRestoreConfirm = run.id }
                                        .buttonStyle(.bordered).controlSize(.small).tint(Color.cs(CSColor.warning))
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Color.cs(CSColor.surfaceElevated).opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5))
                        }
                    }
                    if viewModel.backups.count > 5 {
                        Text("\(viewModel.backups.count - 5) older backups retained").font(.caption2).csForeground(CSColor.textTertiary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 8) {
                        Button { Task { await viewModel.runBackup() } } label: { Label("Create Backup", systemImage: "plus.circle.fill") }
                            .buttonStyle(.borderedProminent).controlSize(.small).disabled(viewModel.isFetching)
                        Button { Task { await viewModel.runOptimize() } } label: { Label("Vacuum", systemImage: "wand.and.stars") }
                            .buttonStyle(.bordered).controlSize(.small).disabled(viewModel.isFetching)
                    }
                }
            }
        }
    }

    private var backupsCard: some View { backupsCardCompact }

    private func maintenanceResultCard(_ r: MaintenanceReport) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Last Maintenance", systemImage: "hammer").font(.callout.weight(.semibold))
                Text("Freed \(r.freedPages) pages · \(ByteCountFormatter.string(fromByteCount: r.recoveredBytes, countStyle: .file)) · Vacuum \(r.vacuumRan ? "yes" : "no") · Checkpoint \(r.checkpointedFrames) frames").font(.caption).csForeground(CSColor.textSecondary)
                Text(r.checkedAt.relativeTime).font(.caption2).csForeground(CSColor.textTertiary)
            }
        }
    }
}
