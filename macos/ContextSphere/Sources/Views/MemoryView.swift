import SwiftUI

/// ContextSphere's memory center: what the core has learned from previous
/// executions, how confident it is, how the store is aging, and what the
/// user can control. Everything rendered here comes from real backend
/// RPCs (`memory_*`); the screen only exposes capabilities the Rust core
/// provides.
struct MemoryView: View {
    @ObservedObject var viewModel: MemoryViewModel

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
    }

    // MARK: - Header

    private var header: some View {
        ScreenHeader("Memory",
                     subtitle: subtitle,
                     symbol: "brain.head.profile") {
            refreshButton
        }
    }

    private var subtitle: String {
        var parts = ["What ContextSphere has learned from your work."]
        if let stats = viewModel.stats, stats.totalRecords > 0 {
            parts.append("\(stats.totalRecords) memories")
        }
        return parts.joined(separator: " · ")
    }

    private var refreshButton: some View {
        Button {
            Task { await viewModel.refresh() }
        } label: {
            if viewModel.isFetching {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(viewModel.isFetching)
        .help("Refresh memory")
        .accessibilityLabel("Refresh memory")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            LoadingView(label: "Loading memory…")
        case .failed(let message):
            if viewModel.stats == nil {
                errorState(message)
            } else {
                loadedContent
            }
        case .loaded:
            if viewModel.hits.isEmpty && viewModel.stats?.totalRecords == 0 {
                emptyState
            } else {
                loadedContent
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("Memory unavailable").font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Retry") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Retry loading memory")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    /// Encouraging first-run state: the backend simply has nothing to
    /// show yet, not an error.
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("ContextSphere hasn't learned enough yet")
                .font(.title3.weight(.semibold))
            Text("Memories form as the core plans and completes work in your workspaces. Successful runs become workflows ContextSphere can reuse, and it learns from your feedback.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Refresh") {
                Task { await viewModel.refresh() }
            }
            .accessibilityLabel("Refresh memory")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // MARK: - Loaded content

    private var loadedContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            overview
            learnedContext
            patterns
            duplicatesSection
            dataSection
            healthSection
        }
    }

    // MARK: - Overview

    private var overview: some View {
        HStack(alignment: .top, spacing: 16) {
            ContentCard(cornerRadius: Theme.cornerLarge) {
                statTiles
            }
            ContentCard(cornerRadius: Theme.cornerLarge) {
                healthGauges
            }
        }
    }

    private var statTiles: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Overview", symbol: "brain.head.profile")
            let stats = viewModel.stats
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                      spacing: 14) {
                statTile(value: stats?.totalRecords, label: "Learned items")
                statTile(value: stats?.successful, label: "Succeeded")
                statTile(value: stats?.failed, label: "Failed")
                statTile(value: stats?.totalReplays, label: "Replays")
                statTile(value: stats?.learnedWorkflows, label: "Workflows")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statTile(value: Int?, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.map(String.init) ?? "—")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value.map(String.init) ?? "unknown")")
    }

    private var healthGauges: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Learning health", symbol: "waveform.path.ecg")
            if let health = viewModel.health, health.confidenceAverage > 0 {
                confidenceGauge(label: "Average confidence",
                                value: health.confidenceAverage,
                                help: "Mean confidence across remembered workflows")
                confidenceGauge(label: "Successful run confidence",
                                value: health.confidenceSuccessful,
                                help: "Mean confidence of successful memories")
                confidenceGauge(label: "Acceptance rate",
                                value: health.acceptanceRate,
                                help: "Share of recommendations you accepted")
                if let aging = viewModel.aging {
                    confidenceGauge(label: "Memory freshness",
                                    value: aging.avgFreshness,
                                    help: "Exponential freshness across the store, 30-day half-life")
                }
            } else {
                Text("No learning signals yet — confidence builds with each remembered run.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func confidenceGauge(label: String, value: Double, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.3)
                    .lineLimit(1)
                Spacer()
                Text(value.percentString)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .accessibilityLabel("\(label): \(value.percentString)")
            }
            ProgressView(value: value)
                .tint(value >= 0.7 ? .green : value >= 0.4 ? .orange : .red)
                .scaleEffect(x: 1, y: 1.1, anchor: .center)
                .accessibilityLabel(label)
                .help(help)
        }
    }

    // MARK: - Learned context

    private var learnedContext: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Learned context",
                          subtitle: viewModel.hits.isEmpty ? nil : "\(viewModel.hits.count) shown",
                          symbol: "books.vertical")
            filterBar
            if viewModel.hits.isEmpty && viewModel.hasSearched {
                noMatches
            } else {
                if viewModel.selectedRecord != nil {
                    memorySplit
                } else {
                    memoryList
                }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search remembered goals…", text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search remembered goals")
                    .onChange(of: viewModel.query) { _, _ in
                        viewModel.scheduleSearch()
                    }
                if !viewModel.query.isEmpty {
                    Button {
                        viewModel.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Picker("Kind", selection: Binding(
                get: { viewModel.selectedKind },
                set: { viewModel.selectedKind = $0; viewModel.filterChange() }
            )) {
                Text("All kinds").tag(MemoryKind?.none)
                ForEach(MemoryKind.allCases, id: \.self) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(Optional(kind))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("Filter by memory kind")

            Picker("Outcome", selection: Binding(
                get: { viewModel.selectedStatus },
                set: { viewModel.selectedStatus = $0; viewModel.filterChange() }
            )) {
                Text("All outcomes").tag(MemoryStatus?.none)
                ForEach(MemoryStatus.allCases, id: \.self) { status in
                    Text(status.title).tag(Optional(status))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("Filter by outcome")

            if !viewModel.workspaces.isEmpty {
                Picker("Workspace", selection: Binding(
                    get: { viewModel.selectedWorkspaceID },
                    set: { viewModel.selectedWorkspaceID = $0; viewModel.filterChange() }
                )) {
                    Text("All workspaces").tag(String?.none)
                    ForEach(viewModel.workspaces) { workspace in
                        Text(workspace.name).tag(Optional(workspace.id))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("Filter by workspace")
            }

            Spacer()
            if viewModel.selectedKind != nil || viewModel.selectedStatus != nil
                || viewModel.selectedWorkspaceID != nil {
                Button("Clear filters") { viewModel.clearFilters() }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear memory filters")
            }
        }
    }

    private var noMatches: some View {
        Text("No memories match the current filters.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
    }

    private var memorySplit: some View {
        HStack(alignment: .top, spacing: 16) {
            memoryList
                .frame(minWidth: 340, idealWidth: 380, maxWidth: 460)
            if let record = viewModel.selectedRecord {
                MemoryDetailView(viewModel: viewModel, record: record)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var memoryList: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(viewModel.hits, id: \.record.id) { hit in
                MemoryRow(hit: hit,
                          workspaceName: viewModel.workspaceName(for: hit.record.workspaceId),
                          isSelected: hit.record.id == viewModel.selectedID) {
                    viewModel.select(hit)
                }
            }
        }
    }

    // MARK: - Patterns

    private var patterns: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Patterns", symbol: "point.3.filled.connected.trianglepath.dotted")
            if viewModel.families.isEmpty && viewModel.failurePatterns.isEmpty {
                Text("Patterns emerge as the same kinds of work repeat across runs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                if !viewModel.families.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Workflow families")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LazyVStack(spacing: 8) {
                            ForEach(viewModel.families, id: \.familyId) { family in
                                WorkflowFamilyCard(family: family)
                            }
                        }
                    }
                }
                if !viewModel.failurePatterns.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Things to avoid")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LazyVStack(spacing: 8) {
                            ForEach(viewModel.failurePatterns, id: \.goalFingerprint) { pattern in
                                FailurePatternRow(pattern: pattern)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Duplicates

    @State private var confirmMerge = false

    private var duplicatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionHeader(title: "Duplicates",
                              subtitle: viewModel.duplicateGroups.isEmpty
                                  ? nil : "\(viewModel.duplicateGroups.count) group\(viewModel.duplicateGroups.count == 1 ? "" : "s")",
                              symbol: "square.on.square")
                Spacer()
                if !viewModel.duplicateGroups.isEmpty {
                    if viewModel.mergeRunning {
                        ProgressView().controlSize(.small)
                    }
                    Button("Merge identical…") { confirmMerge = true }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.mergeRunning)
                        .help("Keep the best record of each duplicate group and remove the rest")
                        .accessibilityLabel("Merge duplicate memories")
                }
            }
            if let merge = viewModel.mergeResult {
                Label("Merged \(merge.recordsMerged) duplicates in \(merge.groupsMerged) groups",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Merged \(merge.recordsMerged) duplicates in \(merge.groupsMerged) groups")
            }
            if viewModel.duplicatesLoading && viewModel.duplicateGroups.isEmpty {
                ProgressView().controlSize(.small)
            } else if viewModel.duplicateGroups.isEmpty {
                Text("No identical memories — every remembered run is unique.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.duplicateGroups, id: \.goalFingerprint) { group in
                        DuplicateGroupCard(group: group,
                                           workspaceName: viewModel.workspaceName(for: group.records.first?.workspaceId))
                    }
                }
            }
        }
        .alert("Merge identical memories?", isPresented: $confirmMerge) {
            Button("Merge", role: .destructive) {
                Task { await viewModel.mergeDuplicates() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = viewModel.duplicateGroups.reduce(0) { $0 + $1.duplicateIDs.count }
            Text("The best record of each group is kept; \(count) duplicate cop\(count == 1 ? "y" : "ies") are removed. Merges are recorded in each memory's lineage. This cannot be undone.")
        }
    }

    // MARK: - Snapshots & transfer

    @State private var showSnapshotField = false
    @State private var newSnapshotLabel = ""
    @State private var confirmRestoreSnapshotID: String?

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Snapshots & transfer",
                          symbol: "externaldrive.badge.timemachine")
            HStack(alignment: .top, spacing: 20) {
                snapshotsPanel
                transferPanel
            }
        }
    }

    private var snapshotsPanel: some View {
        ContentCard(cornerRadius: Theme.cornerRegular) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Snapshots", systemImage: "camera.on.rectangle")
                    .font(.callout.weight(.semibold))
                if showSnapshotField {
                    HStack(spacing: 8) {
                        TextField("Label (optional)", text: $newSnapshotLabel)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Snapshot label")
                            .onSubmit { createSnapshotFromField() }
                        Button("Create") { createSnapshotFromField() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(viewModel.snapshotRunning)
                        Button("Cancel") { showSnapshotField = false }
                            .controlSize(.small)
                    }
                } else {
                    Button {
                        newSnapshotLabel = ""
                        showSnapshotField = true
                    } label: {
                        if viewModel.snapshotRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("New snapshot", systemImage: "plus")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.snapshotRunning || viewModel.stats?.totalRecords == 0)
                    .help("Capture the whole memory store under a label")
                    .accessibilityLabel("Create memory snapshot")
                }
                if let notice = viewModel.snapshotNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel(notice)
                }
                if viewModel.snapshotsLoading && viewModel.snapshots.isEmpty {
                    ProgressView().controlSize(.small)
                } else if viewModel.snapshots.isEmpty {
                    Text("No snapshots yet — capture one before risky cleanups.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.snapshots.prefix(5)) { snapshot in
                        snapshotRow(snapshot)
                    }
                    if viewModel.snapshots.count > 5 {
                        Text("\(viewModel.snapshots.count - 5) older snapshot\(viewModel.snapshots.count - 5 == 1 ? "" : "s") kept by the core")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let restore = viewModel.restoreResult {
                    Text("Restored \(restore.recordsRestored) records · \(restore.snapshotsKept) snapshots kept")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .accessibilityLabel("Restore finished: \(restore.recordsRestored) records restored")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert(item: Binding(
            get: { confirmRestoreSnapshotID.map { PendingRestore(id: $0) } },
            set: { confirmRestoreSnapshotID = $0?.id })) { pending in
            restoreAlert(for: pending.id)
        }
    }

    private func createSnapshotFromField() {
        let label = newSnapshotLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        showSnapshotField = false
        Task { await viewModel.createSnapshot(label: label.isEmpty ? nil : label) }
    }

    private struct PendingRestore: Identifiable { let id: String }

    private func restoreAlert(for id: String) -> Alert {
        Alert(
            title: Text("Restore this snapshot?"),
            message: Text("The store is rebuilt from the snapshot's records; anything learned since is dropped. The vector index is rebuilt automatically."),
            primaryButton: .destructive(Text("Restore")) {
                Task { await viewModel.restoreSnapshot(id) }
            },
            secondaryButton: .cancel())
    }

    private func snapshotRow(_ snapshot: MemorySnapshot) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "camera")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text("\(snapshot.recordCount) records · \(snapshot.createdAt.relativeTime)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Restore") { confirmRestoreSnapshotID = snapshot.id }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(viewModel.snapshotRunning)
                .help("Rebuild the memory store from this snapshot")
                .accessibilityLabel("Restore snapshot \(snapshot.label)")
        }
        .padding(.vertical, 3)
    }

    private var transferPanel: some View {
        ContentCard(cornerRadius: Theme.cornerRegular) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Export & import", systemImage: "arrow.up.doc")
                    .font(.callout.weight(.semibold))
                Text("Move the whole store between machines as portable JSON.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        exportMemoryStore()
                    } label: {
                        if viewModel.importExportRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Export…", systemImage: "square.and.arrow.up")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.importExportRunning || viewModel.stats?.totalRecords == 0)
                    .help("Save the whole memory store as JSON")
                    .accessibilityLabel("Export memory store")

                    Button {
                        importMemoryStore()
                    } label: {
                        Label("Import…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.importExportRunning)
                    .help("Import an exported memory file (ids already present are skipped)")
                    .accessibilityLabel("Import memory store")
                }
                if let imported = viewModel.importResult {
                    Text("Imported \(imported.imported), skipped \(imported.skipped) existing")
                        .font(.caption)
                        .foregroundStyle(imported.imported > 0 ? Color.green : Color.secondary)
                        .accessibilityLabel("Import finished: \(imported.imported) imported, \(imported.skipped) skipped")
                }
                if let transfer = viewModel.transferNotice {
                    Text(transfer).font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel(transfer)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func exportMemoryStore() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "contextsphere-memory.json"
        panel.message = "Choose where to save the memory store export."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if await viewModel.exportToFile(at: url) {
                viewModel.transferNotice = "Exported to \(url.lastPathComponent)"
            }
        }
    }

    private func importMemoryStore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a ContextSphere memory export."
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        viewModel.transferNotice = nil
        Task { await viewModel.importFromFile(at: url) }
    }

    // MARK: - Health & data

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Memory data", symbol: "internaldrive")
            HStack(alignment: .top, spacing: 20) {
                indexPanel
                storagePanel
                lifecyclePanel
            }
            if let lastError = viewModel.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Memory action error: \(lastError)")
            }
        }
    }

    private var indexPanel: some View {
        ContentCard(cornerRadius: Theme.cornerRegular) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Vector index", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    .font(.callout.weight(.semibold))
                if let index = viewModel.indexStatus {
                    infoRow(label: "Provider", value: index.provider.isEmpty ? "none" : index.provider)
                    if index.dimensions > 0 {
                        infoRow(label: "Dimensions", value: "\(index.dimensions)")
                    }
                    infoRow(label: "Indexed", value: "\(index.indexed) / \(index.totalRecords)")
                    if index.cacheHits + index.cacheMisses > 0 {
                        infoRow(label: "Cache hit rate", value: index.cacheHitRate.percentString)
                    }
                } else {
                    Text("No index information.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button {
                    Task { await viewModel.reindex() }
                } label: {
                    if viewModel.reindexRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Reindex", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.reindexRunning)
                .help("Rebuild the memory vector index")
                .accessibilityLabel("Reindex memory")
                if let result = viewModel.reindexResult {
                    Text("Indexed \(result.indexed) of \(result.requested) (\(result.failed) failed)")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Reindex finished: \(result.indexed) of \(result.requested)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var storagePanel: some View {
        ContentCard(cornerRadius: Theme.cornerRegular) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Storage", systemImage: "internaldrive")
                    .font(.callout.weight(.semibold))
                if let storage = viewModel.storage {
                    infoRow(label: "Database", value: byteString(storage.databaseSizeBytes))
                    infoRow(label: "Vectors", value: byteString(storage.vectorIndexSizeBytes))
                    infoRow(label: "Permanent", value: "\(storage.permanentMemories)")
                    infoRow(label: "Archived", value: "\(storage.archivedMemories)")
                    infoRow(label: "Expired", value: "\(storage.expiredMemories)")
                } else {
                    Text("No storage information.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var lifecyclePanel: some View {
        ContentCard(cornerRadius: Theme.cornerRegular) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Lifecycle", systemImage: "clock.arrow.circlepath")
                    .font(.callout.weight(.semibold))
                Text("Expired memories are removed on the next cleanup pass.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await viewModel.runCleanup() }
                } label: {
                    if viewModel.cleanupRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Clean up now", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.cleanupRunning)
                .help("Run one cleanup pass now")
                .accessibilityLabel("Run memory cleanup now")
                if let report = viewModel.cleanupReport {
                    Text("Removed \(report.removedExpired) expired, marked \(report.expiredMarked), compressed \(report.compressed)")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Cleanup result: removed \(report.removedExpired) expired, marked \(report.expiredMarked), compressed \(report.compressed)")
                }
                Divider()
                Button {
                    Task { await viewModel.compressOversized() }
                } label: {
                    if viewModel.compressRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Compress oversized", systemImage: "doc.zipper")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.compressRunning || viewModel.stats?.totalRecords == 0)
                .help("Shrink very long reasoning histories into compact summaries (originals are archived)")
                .accessibilityLabel("Compress oversized memories")
                if let compress = viewModel.compressResult {
                    Text("Compressed \(compress.compressed) of \(compress.examined) examined")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Compression finished: \(compress.compressed) of \(compress.examined)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Presentation helpers

extension ExecutionMemoryRecord {
    /// Human-readable retention note, shown on rows and in the inspector.
    var retentionBadge: String? {
        switch retention {
        case .permanent: nil
        case .temporary:
            "Expires \(retentionUntilDate?.formatted(date: .abbreviated, time: .omitted) ?? "soon")"
        case .archived: "Archived"
        case .expired: "Expired"
        }
    }
}

// MARK: - Memory row

private struct MemoryRow: View {
    let hit: MemoryHit
    let workspaceName: String?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: hit.record.kind.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(hit.record.status == .success ? Color.green : Color.secondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(hit.record.goal)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        statusBadge
                        Text(hit.record.kind.title)
                            .foregroundStyle(.secondary)
                        if let workspaceName {
                            Text("· \(workspaceName)")
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .font(.caption2)
                    HStack(spacing: 6) {
                        if let retentionBadge = hit.record.retentionBadge {
                            Text(retentionBadge)
                                .foregroundStyle(.tertiary)
                        }
                        if hit.record.replayCount > 0 {
                            Label("\(hit.record.replayCount) replays",
                                  systemImage: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(hit.record.createdAt.relativeTime)
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected
                    ? AnyShapeStyle(Color.accentColor.opacity(0.5))
                    : AnyShapeStyle(.quaternary),
                              lineWidth: isSelected ? 1 : 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var statusBadge: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(hit.record.status.title)
                .foregroundStyle(statusColor)
        }
        .accessibilityHidden(true)
    }

    private var statusColor: Color {
        switch hit.record.status {
        case .success: .green
        case .failed: .red
        case .cancelled: .orange
        }
    }

    private var accessibilityText: String {
        var parts = [hit.record.goal, hit.record.kind.title, hit.record.status.title]
        if let workspaceName { parts.append("in \(workspaceName)") }
        if hit.record.replayCount > 0 { parts.append("\(hit.record.replayCount) replays") }
        parts.append(hit.record.createdAt.relativeTime)
        return parts.joined(separator: ", ")
    }
}

// MARK: - Patterns

private struct WorkflowFamilyCard: View {
    let family: WorkflowFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(family.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(family.memberCount) workflow\(family.memberCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !family.goals.isEmpty {
                Text(family.goals.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 12) {
                Label("\(family.totalSuccesses) succeeded", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Label("\(family.totalFailures) failed", systemImage: "xmark.circle")
                    .foregroundStyle(.red)
                if family.avgConfidence > 0 {
                    Label("\(family.avgConfidence.percentString) confidence",
                          systemImage: "waveform.path.ecg")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
            if !family.sharedTools.isEmpty {
                HStack(spacing: 4) {
                    ForEach(family.sharedTools.prefix(6), id: \.self) { tool in
                        Text(tool)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.35), in: Capsule())
                    }
                    .accessibilityHidden(true)
                }
                .accessibilityLabel("Shared tools: \(family.sharedTools.prefix(6).joined(separator: ", "))")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = ["Workflow family \(family.name)",
                     "\(family.memberCount) workflows",
                     "\(family.totalSuccesses) succeeded",
                     "\(family.totalFailures) failed"]
        if family.avgConfidence > 0 {
            parts.append("average confidence \(family.avgConfidence.percentString)")
        }
        return parts.joined(separator: ", ")
    }
}

private struct FailurePatternRow: View {
    let pattern: FailurePattern

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(severityColor)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(pattern.patternType.title)
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text("\(pattern.occurrences) run\(pattern.occurrences == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(pattern.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(pattern.goal)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pattern.patternType.title), \(pattern.description), \(pattern.occurrences) runs")
    }

    private var severityColor: Color {
        if pattern.severity > 0.7 { return .red }
        if pattern.severity > 0.4 { return .orange }
        return .yellow
    }
}

// MARK: - Duplicate group card

/// One identical-memory group: the reason it is considered duplicate, its
/// members, and the record a merge would keep.
private struct DuplicateGroupCard: View {
    let group: MemoryDuplicateGroup
    let workspaceName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.records.first?.goal ?? group.goalFingerprint)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(group.records.count) copies · \(group.duplicateIDs.count) removed by merge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(group.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            ForEach(group.records, id: \.id) { record in
                HStack(spacing: 6) {
                    Image(systemName: record.id == group.keepId ? "star.fill" : "doc")
                        .font(.caption2)
                        .foregroundStyle(record.id == group.keepId ? Color.yellow : Color.secondary)
                        .accessibilityHidden(true)
                    Text(record.status.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let workspaceName {
                        Text("· \(workspaceName)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(record.createdAt.relativeTime)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if record.id == group.keepId {
                        Text("kept")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(record.status.title) copy from \(record.createdAt.relativeTime)\(record.id == group.keepId ? ", kept after merge" : "")")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Duplicate group: \(group.reason)")
    }
}
