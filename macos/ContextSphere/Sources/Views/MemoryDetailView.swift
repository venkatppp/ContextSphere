import SwiftUI

/// Detail inspector for one remembered run: what was learned, its
/// outcome, the plan that ran, its lineage, and the controls the backend
/// supports (feedback, retention, forget).
struct MemoryDetailView: View {
    @ObservedObject var viewModel: MemoryViewModel
    let record: ExecutionMemoryRecord

    @State private var confirmForget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: record.kind.symbol)
                        .foregroundStyle(record.status == .success ? Color.cs(CSColor.success) : Color.cs(CSColor.textSecondary))
                    Text(record.goal)
                        .font(.headline)
                        .lineLimit(3)
                    Spacer()
                    if record.version > 1 {
                        Text("v\(record.version)")
                            .font(.caption.monospacedDigit())
                            .csForeground(CSColor.textTertiary)
                            .accessibilityLabel("Version \(record.version)")
                    }
                }
                HStack(spacing: 6) {
                    statusBadge
                    Text(record.kind.title)
                    if let workspace = viewModel.workspaceName(for: record.workspaceId) {
                        Text("· \(workspace)")
                    }
                    if let retentionBadge = record.retentionBadge {
                        Text("· \(retentionBadge)")
                            .csForeground(CSColor.warning)
                    }
                }
                .font(.caption)
                .csForeground(CSColor.textSecondary)
                .accessibilityElement(children: .combine)
                HStack(spacing: 10) {
                    Text("Learned \(record.createdAt.relativeTime)")
                    Text("·")
                    Text("Observed \(record.updatedAt.relativeTime)")
                    if record.replayCount > 0 {
                        Text("·")
                        Text("\(record.replayCount) replays")
                    }
                }
                .font(.caption2)
                .csForeground(CSColor.textTertiary)
                .accessibilityElement(children: .combine)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let summary = record.summary {
                Label(summary, systemImage: "doc.zipper")
                    .font(.caption)
                    .csForeground(CSColor.textSecondary)
                    .accessibilityLabel("Compressed summary: \(summary)")
            }

            outcomeRow
            if !record.toolsUsed.isEmpty {
                toolsRow
            }
            if !record.failedSteps.isEmpty || record.error != nil {
                failuresRow
            }
            if !record.steps.isEmpty {
                stepsSection
            }
            if let plan = record.plan {
                planSection(plan)
            }
            if !record.reasoning.isEmpty {
                reasoningSection
            }
            lineageSection
            controlsRow
        }
        .padding(14)
        .background(Color.cs(CSColor.surface), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5)
        )
        .alert("Forget this memory?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) {
                Task { await viewModel.setRetention(for: record.id, policy: .expired) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This marks the remembered run as expired. The core removes expired memories on its next cleanup pass, which runs immediately. This cannot be undone.")
        }
        .accessibilityLabel("Memory detail for \(record.goal)")
    }

    // MARK: - Status

    private var statusBadge: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(record.status.title)
                .foregroundStyle(statusColor)
        }
        .accessibilityHidden(true)
    }

    private var statusColor: Color {
        switch record.status {
        case .success: Color.cs(CSColor.success)
        case .failed: Color.cs(CSColor.error)
        case .cancelled: Color.cs(CSColor.warning)
        }
    }

    // MARK: - Outcome

    private var outcomeRow: some View {
        HStack(spacing: 16) {
            outcomeItem(value: "\(record.outcome.completed) / \(record.outcome.steps)",
                        label: "Steps completed")
            outcomeItem(value: "\(record.outcome.replaced)", label: "Replaced")
            outcomeItem(value: "\(record.outcome.replanCount)", label: "Replans")
            if record.outcome.durationSeconds > 0 {
                outcomeItem(value: durationString(record.outcome.durationSeconds),
                            label: "Duration")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Outcome: \(record.outcome.completed) of \(record.outcome.steps) steps completed")
    }

    private func outcomeItem(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption2)
                .csForeground(CSColor.textSecondary)
        }
    }

    private func durationString(_ seconds: Int) -> String {
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    private var toolsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tools used")
                .font(.caption).csForeground(CSColor.textSecondary)
            HStack(spacing: 4) {
                ForEach(record.toolsUsed.prefix(8), id: \.self) { tool in
                    Text(tool)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.cs(CSColor.borderSubtle), in: Capsule())
                }
                .accessibilityHidden(true)
            }
            .accessibilityLabel("Tools used: \(record.toolsUsed.prefix(8).joined(separator: ", "))")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var failuresRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What went wrong")
                .font(.caption).csForeground(CSColor.error)
            if !record.failedSteps.isEmpty {
                ForEach(record.failedSteps, id: \.self) { step in
                    Label(step, systemImage: "xmark.octagon")
                        .font(.caption)
                        .csForeground(CSColor.error)
                }
            }
            if let error = record.error {
                Text(error)
                    .font(.caption)
                    .csForeground(CSColor.error)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Steps

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Steps")
                .font(.caption).csForeground(CSColor.textSecondary)
            ForEach(Array(record.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit())
                        .csForeground(CSColor.textTertiary)
                        .frame(width: 18, alignment: .trailing)
                    Text(step)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(index + 1): \(step)")
            }
        }
    }

    // MARK: - Plan

    private func planSection(_ plan: MemoryPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Remembered plan")
                    .font(.caption).csForeground(CSColor.textSecondary)
                Spacer()
                if plan.confidence > 0 {
                    Text("plan confidence \(plan.confidence.percentString)")
                        .font(.caption2.monospacedDigit())
                        .csForeground(CSColor.textSecondary)
                        .accessibilityLabel("Plan confidence \(plan.confidence.percentString)")
                }
            }
            if !plan.requiredFiles.isEmpty {
                Label(plan.requiredFiles.joined(separator: ", "),
                      systemImage: "doc")
                    .font(.caption2)
                    .csForeground(CSColor.textSecondary)
                    .lineLimit(2)
                    .accessibilityLabel("Required files: \(plan.requiredFiles.joined(separator: ", "))")
            }
            ForEach(plan.tasks, id: \.id) { task in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 10))
                        .foregroundStyle(task.completed ? Color.cs(CSColor.success) : Color.cs(CSColor.textSecondary))
                    Text(task.description)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(task.completed ? "Completed: \(task.description)" : task.description)
            }
        }
        .padding(10)
        .background(Color.cs(CSColor.hoverFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var reasoningSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Reasoning")
                .font(.caption).csForeground(CSColor.textSecondary)
            ForEach(record.reasoning, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .csForeground(CSColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Lineage

    private var lineageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Lineage")
                .font(.caption).csForeground(CSColor.textSecondary)
            if let lineage = viewModel.lineage {
                if lineage.ancestors.isEmpty && lineage.children.isEmpty && lineage.mergedInto.isEmpty {
                    Text("This is the first version of its workflow.")
                        .font(.caption)
                        .csForeground(CSColor.textSecondary)
                } else {
                    if !lineage.ancestors.isEmpty {
                        lineageNodeList(nodes: lineage.ancestors,
                                        relationTitle: "Earlier versions")
                    }
                    if !lineage.children.isEmpty {
                        lineageNodeList(nodes: lineage.children,
                                        relationTitle: "Later versions")
                    }
                    if !lineage.mergedInto.isEmpty {
                        lineageNodeList(nodes: lineage.mergedInto,
                                        relationTitle: "Merged duplicates")
                    }
                }
            } else if viewModel.detailLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading lineage…").font(.caption).csForeground(CSColor.textSecondary)
                }
            } else if let detailError = viewModel.detailError {
                Text("Lineage unavailable: \(detailError)")
                    .font(.caption)
                    .csForeground(CSColor.error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lineageNodeList(nodes: [LineageNode], relationTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(relationTitle)
                .font(.caption2).csForeground(CSColor.textTertiary)
            ForEach(nodes, id: \.id) { node in
                HStack(spacing: 6) {
                    Circle()
                        .fill(node.status == .success ? Color.cs(CSColor.success) : Color.cs(CSColor.warning))
                        .frame(width: 5, height: 5)
                    Text(node.goal)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Text(node.status.title)
                        .font(.caption2)
                        .csForeground(CSColor.textSecondary)
                    Text(node.createdAt.relativeTime)
                        .font(.caption2)
                        .csForeground(CSColor.textTertiary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(node.goal), \(node.status.title), \(node.createdAt.relativeTime)")
            }
        }
    }

    // MARK: - Controls

    private var controlsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if record.compressedAt != nil {
                HStack(spacing: 8) {
                    Label("Reasoning compressed \(record.compressedAt?.relativeTime ?? "")",
                          systemImage: "doc.zipper")
                        .font(.caption)
                        .csForeground(CSColor.textSecondary)
                    actionButton("Restore full reasoning", symbol: "arrow.uturn.backward",
                                 help: "Restore the original reasoning from the compression archive") {
                        Task { await viewModel.restoreCompressed(record.id) }
                    }
                    .disabled(viewModel.restoreCompressedState[record.id] == .working)
                    if viewModel.restoreCompressedState[record.id] == .working {
                        ProgressView().controlSize(.small)
                    }
                }
                Divider()
            }
            HStack(spacing: 10) {
                Text("Feedback")
                    .font(.caption)
                    .csForeground(CSColor.textSecondary)
                actionButton("Helpful", symbol: "hand.thumbsup", help: "Accept this memory for future recommendations") {
                    Task { await viewModel.sendFeedback(for: record.id, accepted: true) }
                }
                actionButton("Not helpful", symbol: "hand.thumbsdown", help: "Reject this memory for future recommendations") {
                    Task { await viewModel.sendFeedback(for: record.id, accepted: false) }
                }
                feedbackResult
                Spacer()
                Divider().frame(height: 16)
                Text("Retention")
                    .font(.caption)
                    .csForeground(CSColor.textSecondary)
                if record.retention == .archived {
                    actionButton("Keep", symbol: "lock.open", help: "Make this memory permanent again") {
                        Task { await viewModel.setRetention(for: record.id, policy: .permanent) }
                    }
                } else if record.retention != .expired {
                    actionButton("Archive", symbol: "archivebox", help: "Keep this memory out of active use") {
                        Task { await viewModel.setRetention(for: record.id, policy: .archived) }
                    }
                }
                if record.retention != .expired {
                    Button("Forget", role: .destructive) {
                        confirmForget = true
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this memory from the store")
                    .accessibilityLabel("Forget this memory")
                }
            }
            if case .failed(let message) = viewModel.retentionState[record.id] {
                Text(message).font(.caption).csForeground(CSColor.error)
            }
        }
    }

    private func actionButton(_ title: String, symbol: String,
                              help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel("\(title): \(record.goal)")
    }

    @ViewBuilder
    private var feedbackResult: some View {
        switch viewModel.feedbackState[record.id] ?? .idle {
        case .idle:
            EmptyView()
        case .working:
            ProgressView().controlSize(.small)
                .accessibilityLabel("Recording feedback")
        case .done:
            Label("Recorded", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .csForeground(CSColor.success)
                .accessibilityLabel("Feedback recorded")
        case .failed(let message):
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .csForeground(CSColor.error)
                .help(message)
                .accessibilityLabel("Feedback failed: \(message)")
        }
    }
}