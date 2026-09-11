import SwiftUI

/// Renders explainable workspace intelligence: confidence score, active inference state,
/// signal breakdown (temporal, activity, health, session), work episode, and suggestions.
///
/// Compact signal layout: each signal row shows name, inline strength bar, score, and
/// a one-line explanation — no full-width GeometryReader progress bars.
struct WorkspaceIntelligenceCard: View {
    let intelligence: WorkspaceIntelligence
    var onResumeEpisode: (() -> Void)? = nil
    var onExecuteSuggestion: ((WorkspaceSuggestion) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded: Bool = true

    private var confidenceKind: CSStatusBadge.Kind {
        if intelligence.isActiveInference {
            return .success
        } else if intelligence.confidence >= 0.35 {
            return .warning
        } else {
            return .neutral
        }
    }

    private var confidenceLabel: String {
        let pct = Int((intelligence.confidence * 100).rounded())
        if intelligence.isActiveInference {
            return "\(pct)% Active Inference"
        } else {
            return "\(pct)% Confidence"
        }
    }

    var body: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack(alignment: .center, spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.accentColor.opacity(0.15))
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 26, height: 26)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Workspace Intelligence")
                            .font(.csCardTitle)
                            .csForeground(CSColor.textPrimary)
                        if let app = intelligence.primaryApp, !app.isEmpty {
                            Text("Primary: \(app)")
                                .font(.csTiny)
                                .csForeground(CSColor.textTertiary)
                        }
                    }

                    Spacer(minLength: 6)

                    CSStatusBadge(text: confidenceLabel, kind: confidenceKind)

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
                    .accessibilityLabel(isExpanded ? "Collapse intelligence" : "Expand intelligence")
                }

                if isExpanded {
                    // Compact signal grid
                    signalGrid

                    // Reconstructed Work Episode
                    if let ep = intelligence.latestEpisode {
                        episodeBox(ep)
                    }

                    // Contextual Suggestions
                    if !intelligence.suggestions.isEmpty {
                        suggestionsBox(intelligence.suggestions)
                    }
                }
            }
        }
    }

    // MARK: - Compact Signal Grid

    /// Two-column grid with explicit minimum column widths (140pt).
    /// Each signal: name (single line), flexible spacer, inline horizontal capsule bar (fixed 44pt), score percentage.
    /// Explanation underneath in tertiary text.
    private var signalGrid: some View {
        let columns = [
            GridItem(.flexible(minimum: 140), spacing: 10),
            GridItem(.flexible(minimum: 140), spacing: 10)
        ]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(intelligence.signals) { sig in
                signalCell(sig)
            }
        }
        .padding(10)
        .background(
            Color.cs(CSColor.hoverFill).opacity(0.3),
            in: RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous)
        )
    }

    private func signalCell(_ sig: ConfidenceSignal) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 6) {
                Text(humanSignalName(sig.signal))
                    .font(.csSmallLabel)
                    .csForeground(CSColor.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: 4)

                // Compact inline horizontal bar — fixedSize prevents vertical compression
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.cs(CSColor.borderSubtle).opacity(0.3))
                        .frame(width: 44, height: 4)
                    Capsule()
                        .fill(Color.accentColor.opacity(0.75))
                        .frame(width: max(3, 44 * CGFloat(sig.score.clamped(0.0, 1.0))), height: 4)
                }
                .fixedSize()

                Text("\(Int((sig.score * 100).rounded()))%")
                    .font(.csTiny.monospacedDigit().weight(.medium))
                    .csForeground(CSColor.textSecondary)
                    .frame(width: 30, alignment: .trailing)
                    .fixedSize()
            }

            Text(sig.explanation)
                .font(.csTiny)
                .csForeground(CSColor.textTertiary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }

    // MARK: - Episode

    private func episodeBox(_ ep: WorkEpisode) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("Work Episode")
                        .font(.csSmallLabel)
                        .csForeground(CSColor.textPrimary)
                    Text("·")
                        .csForeground(CSColor.textTertiary)
                    Text("\(ep.durationSeconds / 60)m active")
                        .font(.csTiny)
                        .csForeground(CSColor.textSecondary)
                }
                Text(ep.summary)
                    .font(.csTiny)
                    .csForeground(CSColor.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if ep.isResumable {
                Button {
                    onResumeEpisode?()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.uturn.forward")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Resume")
                            .font(.csTiny.weight(.medium))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            Color.accentColor.opacity(0.08),
            in: RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous)
        )
    }

    // MARK: - Suggestions

    private func suggestionsBox(_ suggestions: [WorkspaceSuggestion]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Suggestions")
                .font(.csSmallLabel)
                .csForeground(CSColor.textSecondary)

            ForEach(suggestions) { sug in
                HStack(alignment: .center, spacing: 7) {
                    Image(systemName: suggestionIcon(sug.actionType))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(sug.title)
                            .font(.csMetadata.weight(.medium))
                            .csForeground(CSColor.textPrimary)
                            .lineLimit(1)
                        Text(sug.description)
                            .font(.csTiny)
                            .csForeground(CSColor.textTertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    Button {
                        onExecuteSuggestion?(sug)
                    } label: {
                        Text(suggestionButtonLabel(sug.actionType))
                            .font(.csTiny.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    Color.cs(CSColor.hoverFill).opacity(0.2),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private func humanSignalName(_ key: String) -> String {
        switch key {
        case "temporal_recency": return "Temporal"
        case "activity_velocity": return "Activity"
        case "workspace_health": return "Health"
        case "session_continuity": return "Continuity"
        default: return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func suggestionIcon(_ actionType: String) -> String {
        switch actionType {
        case "resume_workspace": return "arrow.uturn.forward"
        case "review_health": return "heart.text.square"
        case "create_snapshot": return "camera.circle"
        default: return "sparkles"
        }
    }

    private func suggestionButtonLabel(_ actionType: String) -> String {
        switch actionType {
        case "resume_workspace": return "Resume"
        case "review_health": return "Review"
        case "create_snapshot": return "Snapshot"
        default: return "Execute"
        }
    }
}

private extension Double {
    func clamped(_ minVal: Double, _ maxVal: Double) -> Double {
        return Swift.max(minVal, Swift.min(self, maxVal))
    }
}
