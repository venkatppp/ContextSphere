import SwiftUI
import Charts

/// Learning activity for ContextSphere: how the core learns from the
/// user's behavior. Renders only what the backend's adaptive learning
/// system actually reports — statistics, preferences, behavioral
/// patterns, confidence trends, and recommendation accuracy.
struct LearningView: View {
    @ObservedObject var viewModel: LearningViewModel

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
        ScreenHeader("Learning",
                     subtitle: subtitle,
                     symbol: "graduationcap") {
            refreshButton
        }
    }

    private var subtitle: String {
        var parts = ["How ContextSphere learns from your behavior."]
        if let stats = viewModel.insights?.stats {
            parts.append("Updated \(stats.lastLearningUpdate.relativeTime)")
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
        .help("Refresh learning activity")
        .accessibilityLabel("Refresh learning activity")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            LoadingView(label: "Loading learning activity…")
        case .failed(let message):
            if viewModel.insights == nil {
                errorState(message)
            } else {
                loadedContent
            }
        case .loaded:
            if hasAnyData {
                loadedContent
            } else {
                emptyState
            }
        }
    }

    private var hasAnyData: Bool {
        guard let insights = viewModel.insights else { return false }
        return insights.stats.totalFeedbackCount > 0
            || insights.stats.totalPreferences > 0
            || insights.stats.totalPatterns > 0
            || !insights.topPreferences.isEmpty
            || !insights.recentPatterns.isEmpty
            || !insights.confidenceTrends.isEmpty
            || insights.recommendationAccuracy.totalRecommendations > 0
            || !viewModel.preferences.isEmpty
            || !viewModel.patterns.isEmpty
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("Learning unavailable").font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Retry") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Retry loading learning activity")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "graduationcap")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("ContextSphere is still getting to know you")
                .font(.title3.weight(.semibold))
            VStack(spacing: 8) {
                Text("Learning appears after ContextSphere observes repeated behavior and your feedback on its recommendations.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                VStack(alignment: .leading, spacing: 4) {
                    Label("Accept or reject recommendations (memory, graph context)", systemImage: "hand.thumbsup")
                    Label("Switch workspaces — switching patterns become preferences", systemImage: "arrow.triangle.swap")
                    Label("Open related files in sequence — sequential-file patterns", systemImage: "doc.on.doc")
                    Label("Work at consistent times — time-of-day patterns emerge", systemImage: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420, alignment: .leading)
                .padding(.top, 4)
                Text("Each preference needs a few pieces of evidence before it is confident enough to show. Keep using workspaces normally — patterns will appear here.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            HStack(spacing: 10) {
                Button("Refresh") {
                    Task { await viewModel.refresh() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel("Refresh learning activity")
                if let err = viewModel.lastError {
                    Text(err).font(.caption2).foregroundStyle(.tertiary).lineLimit(2).frame(maxWidth: 200)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // MARK: - Loaded content

    private var loadedContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let insights = viewModel.insights {
                statsOverview(insights)
                if !insights.confidenceTrends.isEmpty {
                    confidenceTrendsSection(insights.confidenceTrends)
                }
                accuracySection(insights.recommendationAccuracy)
            }
            if !viewModel.preferences.isEmpty {
                preferencesSection
            }
            if !viewModel.patterns.isEmpty {
                behavioralPatternsSection
            }
        }
    }

    // MARK: - Statistics

    private func statsOverview(_ insights: LearningInsights) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Learning statistics", symbol: "chart.bar")
            HStack(alignment: .top, spacing: 24) {
                statColumn([
                    ("Feedback recorded", insights.stats.totalFeedbackCount),
                    ("Accepted", insights.stats.acceptedCount),
                    ("Rejected", insights.stats.rejectedCount),
                ])
                statColumn([
                    ("Learned preferences", insights.stats.totalPreferences),
                    ("Behavioral patterns", insights.stats.totalPatterns),
                    ("Recommendations", insights.recommendationAccuracy.totalRecommendations),
                ])
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Recommendation accuracy", symbol: "target")
                    if insights.recommendationAccuracy.totalRecommendations > 0 {
                        HStack(spacing: 8) {
                            ProgressView(value: insights.recommendationAccuracy.overallAccuracy)
                                .accessibilityLabel("Overall recommendation accuracy")
                            Text(insights.recommendationAccuracy.overallAccuracy.percentString)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Overall accuracy \(insights.recommendationAccuracy.overallAccuracy.percentString)")
                        }
                    } else {
                        Text("No feedback yet — accuracy readings appear once you act on recommendations.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
    }

    private func statColumn(_ rows: [(label: String, value: Int)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.label) { row in
                HStack(spacing: 8) {
                    Text(row.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(row.value)")
                        .font(.callout.weight(.semibold).monospacedDigit())
                }
                .frame(minWidth: 140)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.label): \(row.value)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Confidence trends

    private func confidenceTrendsSection(_ trends: [ConfidenceTrend]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Confidence over time",
                          subtitle: "Average confidence per day",
                          symbol: "waveform.path.ecg.rectangle")
            ConfidenceTrendChart(trends: trends)
                .frame(height: 160)
                .accessibilityLabel("Confidence over time. Orange dots mark days with confidence adjustments.")
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
    }

    // MARK: - Accuracy by category

    private func accuracySection(_ accuracy: RecommendationAccuracy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Accuracy by category", symbol: "list.bullet.rectangle")
            if accuracy.categoryAccuracy.isEmpty {
                Text("No category-level feedback yet.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(accuracy.categoryAccuracy, id: \.category) { category in
                        HStack(spacing: 8) {
                            Text(category.category)
                                .font(.callout)
                                .frame(width: 200, alignment: .leading)
                                .lineLimit(1)
                            ProgressView(value: category.accuracy)
                                .accessibilityLabel("Accuracy for \(category.category)")
                            Text(category.accuracy.percentString)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .trailing)
                                .accessibilityLabel("\(category.accuracy.percentString) accuracy")
                            Text("\(category.accepted) / \(category.total)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 56, alignment: .trailing)
                                .accessibilityLabel("\(category.accepted) accepted of \(category.total)")
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
    }

    // MARK: - Learned preferences

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Learned preferences",
                          subtitle: "\(viewModel.preferences.count)",
                          symbol: "slider.horizontal.3")
            LazyVStack(spacing: 6) {
                ForEach(viewModel.preferences, id: \.id) { preference in
                    PreferenceRow(preference: preference)
                }
            }
        }
    }

    // MARK: - Behavioral patterns

    private var behavioralPatternsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Behavioral patterns",
                          subtitle: "\(viewModel.patterns.count)",
                          symbol: "point.3.filled.connected.trianglepath.dotted")
            LazyVStack(spacing: 6) {
                ForEach(viewModel.patterns, id: \.id) { pattern in
                    BehavioralPatternRow(pattern: pattern)
                }
            }
        }
    }
}

// MARK: - Confidence trend chart

private struct ConfidenceTrendChart: View {
    let trends: [ConfidenceTrend]

    var body: some View {
        Chart {
            ForEach(trends, id: \.date) { trend in
                LineMark(x: .value("Date", trend.dateValue),
                         y: .value("Average confidence", trend.avgConfidence))
                    .interpolationMethod(.catmullRom)
            }
            ForEach(trends, id: \.date) { trend in
                if trend.adjustmentCount > 0 {
                    PointMark(x: .value("Date", trend.dateValue),
                              y: .value("Average confidence", trend.avgConfidence))
                        .symbolSize(18)
                        .foregroundStyle(.orange)
                }
            }
        }
        .chartYScale(domain: 0...1)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 0.25, 0.5, 0.75, 1.0])
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6))
        }
    }
}

// MARK: - Rows

private struct PreferenceRow: View {
    let preference: UserPreference

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(preference.preferenceType.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                    Text(preference.key)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                Text("\(preference.evidenceCount) piece\(preference.evidenceCount == 1 ? "" : "s") of evidence · updated \(preference.lastUpdated.relativeTime)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            HStack(spacing: 6) {
                ProgressView(value: preference.confidence)
                    .frame(width: 70)
                    .accessibilityLabel("Confidence \(preference.confidence.percentString)")
                Text(preference.confidence.percentString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(preference.preferenceType.title) preference: \(preference.key), confidence \(preference.confidence.percentString), \(preference.evidenceCount) pieces of evidence")
    }
}

private struct BehavioralPatternRow: View {
    let pattern: BehavioralPattern

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.hexagongrid.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pattern.patternType.title)
                        .font(.callout.weight(.medium))
                    Text("· \(pattern.occurrences) occurrence\(pattern.occurrences == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(pattern.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("First seen \(pattern.firstSeen.relativeTime) · Last seen \(pattern.lastSeen.relativeTime)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            HStack(spacing: 6) {
                ProgressView(value: pattern.confidence)
                    .frame(width: 70)
                    .accessibilityLabel("Confidence \(pattern.confidence.percentString)")
                Text(pattern.confidence.percentString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pattern.patternType.title) pattern: \(pattern.description), \(pattern.occurrences) occurrences")
    }
}