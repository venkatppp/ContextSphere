import SwiftUI

struct PerformanceView: View {
    @ObservedObject var viewModel: PerformanceViewModel
    @State private var showOptimizeConfirm = false
    @State private var applyOptimize = false

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
        .confirmationDialog("Apply optimizations?", isPresented: $showOptimizeConfirm, titleVisibility: .visible) {
            Button(applyOptimize ? "Apply" : "Analyze") {
                Task { await viewModel.runOptimize(apply: applyOptimize) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(applyOptimize ? "Safe optimizations will be applied (clear expired cache, trim, prune history)." : "Analysis only — no changes will be applied.")
        }
    }

    private var header: some View {
        ScreenHeader("Performance",
                     subtitle: viewModel.startup.map { "Last launch \($0.totalMs) ms · \($0.stages.count) stages" } ?? "What ContextSphere is doing right now",
                     symbol: "gauge.with.dots.needle.67percent",
                     eyebrow: "System") {
            HStack(spacing: 8) {
                Button {
                    Task { await viewModel.refreshAll() }
                } label: {
                    if viewModel.isFetching { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium)) }
                }
                .buttonStyle(.borderless)
                .help("Refresh performance")
                Menu {
                    Button("Run Benchmark") { Task { await viewModel.runBenchmark() } }
                    Divider()
                    Button("Analyze") { applyOptimize = false; showOptimizeConfirm = true }
                    Button("Apply Optimizations") { applyOptimize = true; showOptimizeConfirm = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            LoadingView(label: "Loading performance…")
        case .failed(let msg):
            if viewModel.profile == nil { errorState(msg) } else { loadedContent }
        case .loaded:
            loadedContent
        }
    }

    private func errorState(_ msg: String) -> some View {
        EmptyStateView(
            title: "Performance unavailable",
            message: msg,
            symbol: "exclamationmark.triangle",
            primaryAction: ("Retry", { Task { await viewModel.refreshAll() } })
        )
    }

    private var loadedContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let startup = viewModel.startup { startupCard(startup) }
            if let diag = viewModel.diagnostics { diagnosticsCard(diag) }
            if let profile = viewModel.profile { profileCard(profile) }
            if let opt = viewModel.optimizeResult, !opt.recommendations.isEmpty { optimizeCard(opt) }
            if let err = viewModel.lastError {
                Text(err).font(.caption).csForeground(CSColor.error).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func startupCard(_ s: StartupProfile) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Startup", subtitle: "\(s.totalMs) ms", symbol: "bolt.circle")
                ForEach(s.stages, id: \.name) { stage in
                    HStack {
                        Text(stage.label).font(.callout)
                        Spacer()
                        Text("\(stage.durationMs) ms").font(.caption.monospacedDigit()).csForeground(CSColor.textSecondary)
                    }
                    ProgressView(value: Double(stage.durationMs) / Double(max(s.totalMs, 1))).tint(Color.cs(CSColor.info))
                }
            }
        }
    }

    private func diagnosticsCard(_ d: DiagnosticsSnapshot) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "System", symbol: "internaldrive")
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("CPU \(String(format: "%.1f", d.cpu.usagePercent))%", systemImage: "cpu").font(.callout.weight(.medium))
                        Text("\(d.cpu.cores) cores · parallelism \(d.cpu.cpuParallelism)").font(.caption2).csForeground(CSColor.textSecondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Memory \(String(format: "%.1f", d.memory.percent))%", systemImage: "memorychip").font(.callout.weight(.medium))
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(d.memory.usedBytes), countStyle: .memory)) / \(ByteCountFormatter.string(fromByteCount: Int64(d.memory.totalBytes), countStyle: .memory))").font(.caption2).csForeground(CSColor.textSecondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Label("DB \(ByteCountFormatter.string(fromByteCount: Int64(d.db.sizeBytes), countStyle: .file))", systemImage: "cylinder").font(.callout.weight(.medium))
                        Text(d.db.path).font(.caption2).csForeground(CSColor.textTertiary).lineLimit(1).truncationMode(.middle)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if !d.workers.isEmpty {
                    Divider().opacity(0.5)
                    ForEach(d.workers, id: \.name) { w in
                        HStack {
                            Text(w.name).font(.caption.weight(.medium))
                            Spacer()
                            Text(w.status).font(.caption2).foregroundStyle(w.status == "healthy" ? Color.cs(CSColor.success) : Color.cs(CSColor.warning)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.cs(CSColor.borderSubtle), in: Capsule())
                            Text("\(w.executionCount) runs · \(String(format: "%.1f", w.avgExecutionTimeMs)) ms").font(.caption2).csForeground(CSColor.textSecondary).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func profileCard(_ p: ProfileSnapshot) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Profiler", subtitle: "\(p.aggregates.count) aggregates · \(p.recent.count) recent", symbol: "waveform.path.ecg")
                if p.aggregates.isEmpty {
                    Text("No samples yet — profiler fills as you use the app.").font(.callout).csForeground(CSColor.textSecondary)
                } else {
                    ForEach(p.aggregates.prefix(6), id: \.name) { agg in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(agg.name).font(.callout.weight(.medium)).lineLimit(1)
                                Text(agg.category).font(.caption2).csForeground(CSColor.textSecondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(String(format: "%.1f ms", agg.avgMs)).font(.caption.monospacedDigit()).csForeground(CSColor.textPrimary)
                                Text("p95 \(String(format: "%.1f", agg.p95Ms)) ms · \(agg.count)×").font(.caption2).csForeground(CSColor.textTertiary).monospacedDigit()
                            }
                        }
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }

    private func optimizeCard(_ r: OptimizeResult) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Optimize", subtitle: r.applied.isEmpty ? "Analysis" : "Applied \(r.applied.count)", symbol: "wand.and.stars")
                ForEach(r.recommendations.prefix(5), id: \.id) { rec in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(rec.title).font(.callout.weight(.medium))
                            Spacer()
                            Text(rec.severity.capitalized).font(.caption2.weight(.semibold)).foregroundStyle(rec.severity == "critical" ? Color.cs(CSColor.error) : rec.severity == "warning" ? Color.cs(CSColor.warning) : .secondary).padding(.horizontal, 6).padding(.vertical, 2).background(Color.cs(CSColor.borderSubtle), in: Capsule())
                        }
                        Text(rec.detail).font(.caption).csForeground(CSColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(Color.cs(CSColor.hoverFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }
}
