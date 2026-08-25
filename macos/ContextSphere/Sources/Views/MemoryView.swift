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