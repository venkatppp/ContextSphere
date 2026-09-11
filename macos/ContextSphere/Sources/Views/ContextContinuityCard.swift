import SwiftUI

/// Renders the reconstructed work context and continuity score when returning to work,
/// with explainable signals, ground-truth file verification, and non-destructive resume actions.
///
/// Information hierarchy:
/// 1. Resume Context + continuity % + primary Resume button (immediate)
/// 2. Episode summary & relevant files (3 shown, expand for more)
/// 3. Signals & evidence (collapsed by default — progressive disclosure)
struct ContextContinuityCard: View {
    let context: ReconstructedContext
    var onResume: ((ResumeAction) -> Void)? = nil
    var onSnapshot: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded: Bool = true
    @State private var showAllFiles: Bool = false
    @State private var showSignals: Bool = false

    private var continuityKind: CSStatusBadge.Kind {
        if context.continuityScore >= 0.70 {
            return .success
        } else if context.continuityScore >= 0.35 {
            return .warning
        } else {
            return .neutral
        }
    }

    private var continuityPct: Int {
        Int((context.continuityScore * 100).rounded())
    }

    /// Files to display: first 3 unless expanded.
    private var visibleFiles: ArraySlice<ReconstructedFile> {
        showAllFiles
            ? context.relevantFiles.prefix(context.relevantFiles.count)
            : context.relevantFiles.prefix(3)
    }

    var body: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 12) {
                // MARK: Header — title, continuity metric, resume action
                HStack(alignment: .center, spacing: 10) {
                    // Continuity metric circle
                    ZStack {
                        Circle()
                            .stroke(Color.cs(CSColor.borderSubtle).opacity(0.4), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: CGFloat(context.continuityScore.clamped(0.0, 1.0)))
                            .stroke(
                                continuityKind == .success
                                    ? Color.cs(CSColor.success)
                                    : (continuityKind == .warning ? Color.cs(CSColor.warning) : Color.cs(CSColor.textTertiary)),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                        Text("\(continuityPct)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .csForeground(CSColor.textPrimary)
                    }
                    .frame(width: 38, height: 38)
                    .accessibilityLabel("\(continuityPct)% continuity")

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Resume Context")
                            .font(.csCardTitle)
                            .csForeground(CSColor.textPrimary)
                        Text(context.selectionReason)
                            .font(.csTiny)
                            .csForeground(CSColor.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    // Primary resume button
                    if let primaryAction = context.recommendedActions.first {
                        Button {
                            onResume?(primaryAction)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.uturn.forward")
                                    .font(.system(size: 12, weight: .semibold))
                                Text(primaryAction.label)
                                    .font(.csMetadata.weight(.medium))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }

                    Button {
                        withAnimation(Theme.snappy(reduceMotion)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .medium))
                            .csForeground(CSColor.textTertiary)
                            .frame(width: 22, height: 22)
                            .background(Color.cs(CSColor.hoverFill).opacity(0.4), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Collapse context" : "Expand context")
                }

                if isExpanded {
                    // MARK: Episode summary
                    if let ep = context.latestEpisode {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ep.summary)
                                    .font(.csMetadata.weight(.medium))
                                    .csForeground(CSColor.textPrimary)
                                    .lineLimit(2)
                                HStack(spacing: 6) {
                                    Text("\(ep.durationSeconds / 60)m elapsed")
                                        .font(.csTiny)
                                        .csForeground(CSColor.textSecondary)
                                    if let app = context.primaryApp, !app.isEmpty {
                                        Text("·")
                                            .csForeground(CSColor.textTertiary)
                                        Label(app, systemImage: "app.dashed")
                                            .font(.csTiny)
                                            .csForeground(CSColor.textTertiary)
                                    }
                                }
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(
                            Color.accentColor.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous)
                        )
                    }

                    // MARK: Relevant files (progressive disclosure)
                    if !context.relevantFiles.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Working Context")
                                    .font(.csSmallLabel)
                                    .csForeground(CSColor.textSecondary)
                                Spacer()
                                Text("\(context.relevantFiles.filter(\.existsOnDisk).count)/\(context.relevantFiles.count) accessible")
                                    .font(.csTiny)
                                    .csForeground(CSColor.textTertiary)
                            }

                            ForEach(visibleFiles) { file in
                                HStack(spacing: 6) {
                                    Image(systemName: file.existsOnDisk ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(file.existsOnDisk ? Color.cs(CSColor.success) : Color.cs(CSColor.warning))

                                    Text(file.fileName)
                                        .font(.csMetadata.weight(.medium))
                                        .csForeground(file.existsOnDisk ? CSColor.textPrimary : CSColor.textTertiary)
                                        .lineLimit(1)

                                    if let lang = file.language, !lang.isEmpty {
                                        Text(lang)
                                            .font(.csTiny.monospaced())
                                            .csForeground(CSColor.textTertiary)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(
                                                Color.cs(CSColor.hoverFill).opacity(0.5),
                                                in: RoundedRectangle(cornerRadius: 3)
                                            )
                                    }

                                    Spacer()

                                    Text(file.isInferred ? "Inferred" : "Known")
                                        .font(.csTiny)
                                        .csForeground(file.isInferred ? CSColor.textTertiary : CSColor.textSecondary)
                                }
                                .padding(.vertical, 3)
                                .padding(.horizontal, 6)
                            }

                            // Show more / less toggle
                            if context.relevantFiles.count > 3 {
                                Button {
                                    withAnimation(Theme.snappy(reduceMotion)) {
                                        showAllFiles.toggle()
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: showAllFiles ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 12, weight: .medium))
                                        Text(showAllFiles ? "Show less" : "\(context.relevantFiles.count - 3) more files")
                                            .font(.csTiny.weight(.medium))
                                    }
                                    .csForeground(CSColor.info)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // MARK: Signals (collapsed by default)
                    signalsCollapsible

                    // MARK: Secondary actions
                    actionsRow
                }
            }
        }
    }

    // MARK: - Subviews

    private var signalsCollapsible: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(Theme.snappy(reduceMotion)) {
                    showSignals.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showSignals ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                    Text("Continuity Signals & Evidence")
                        .font(.csTiny.weight(.medium))
                    Spacer()
                }
                .csForeground(CSColor.textTertiary)
            }
            .buttonStyle(.plain)

            if showSignals {
                VStack(spacing: 6) {
                    ForEach(context.signals) { sig in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(humanSignalName(sig.signal))
                                    .font(.csSmallLabel)
                                    .csForeground(CSColor.textPrimary)
                                Spacer()
                                Text("\(Int((sig.weight * 100).rounded()))% weight · \(Int((sig.score * 100).rounded()))%")
                                    .font(.csTiny.monospacedDigit())
                                    .csForeground(CSColor.textSecondary)
                            }
                            Text(sig.explanation)
                                .font(.csTiny)
                                .csForeground(CSColor.textTertiary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(8)
                .background(
                    Color.cs(CSColor.hoverFill).opacity(0.3),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
            }
        }
    }

    private var actionsRow: some View {
        HStack(spacing: 6) {
            ForEach(context.recommendedActions.dropFirst()) { action in
                Button {
                    onResume?(action)
                } label: {
                    Text(action.label)
                        .font(.csTiny.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()

            Button {
                onSnapshot?()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "camera.circle")
                        .font(.system(size: 12))
                    Text("Snapshot")
                        .font(.csTiny.weight(.medium))
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .csForeground(CSColor.textSecondary)
            .help("Preserve this work episode state into Context Memory")
        }
    }

    // MARK: - Helpers

    private func humanSignalName(_ key: String) -> String {
        switch key {
        case "recency": return "Temporal Recency"
        case "workspace_confidence": return "Workspace Confidence"
        case "activity_continuity": return "Activity Continuity"
        case "file_integrity": return "File Integrity"
        case "relationship_coherence": return "Graph Coherence"
        default: return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

private extension Double {
    func clamped(_ minVal: Double, _ maxVal: Double) -> Double {
        return Swift.max(minVal, Swift.min(self, maxVal))
    }
}
