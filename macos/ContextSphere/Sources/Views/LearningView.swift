import SwiftUI
import Charts

/// Learning activity for ContextSphere: how the core learns from the
/// user's behavior. Renders only what the backend's adaptive learning
/// system actually reports — statistics, preferences, behavioral
/// patterns, confidence trends, and recommendation accuracy.
struct LearningView: View {
    @ObservedObject var viewModel: LearningViewModel
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
    }

    // MARK: - Header

    private var header: some View {
        StandardPageHeader(
            section: .learning,
            title: "Learning",
            subtitle: subtitle,
            symbol: AppSection.learning.symbol,
            eyebrow: NavGroup.intelligence.title.uppercased()
        ) { refreshButton }
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
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .buttonStyle(.borderless)
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
        EmptyStateView(
            title: "Learning unavailable",
            message: message,
            symbol: "exclamationmark.triangle",
            primaryAction: ("Retry", { Task { await viewModel.refresh() } })
        )
    }

    private var emptyState: some View {
        EmptyStateView(
            title: "ContextSphere is still getting to know you",
            message: "Learning appears after ContextSphere observes repeated behavior and your feedback on its recommendations.",
            symbol: "graduationcap",
            primaryAction: ("Refresh", { Task { await viewModel.refresh() } }),
            details: [
                ("hand.thumbsup", "Accept or reject recommendations"),
                ("arrow.triangle.swap", "Switch workspaces — patterns become preferences"),
                ("doc.on.doc", "Open related files in sequence — sequential-file patterns"),
                ("clock", "Work at consistent times — time-of-day patterns emerge"),
            ]
        )
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
            ViewThatFits(in: .horizontal) {
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
                                    .csForeground(CSColor.textSecondary)
                                    .accessibilityLabel("Overall accuracy \(insights.recommendationAccuracy.overallAccuracy.percentString)")
                            }
                        } else {
                            Text("No feedback yet — accuracy readings appear once you act on recommendations.")
                                .font(.callout)
                                .csForeground(CSColor.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 16) {
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
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Recommendation accuracy", symbol: "target")
                        if insights.recommendationAccuracy.totalRecommendations > 0 {
                            HStack(spacing: 8) {
                                ProgressView(value: insights.recommendationAccuracy.overallAccuracy)
                                Text(insights.recommendationAccuracy.overallAccuracy.percentString)
                                    .font(.caption.monospacedDigit())
                                    .csForeground(CSColor.textSecondary)
                            }
                        } else {
                            Text("No feedback yet — accuracy readings appear once you act on recommendations.")
                                .font(.callout)
                                .csForeground(CSColor.textSecondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color.cs(CSColor.surface), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5)
        )
    }

    private func statColumn(_ rows: [(label: String, value: Int)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.label) { row in
                HStack(spacing: 8) {
                    Text(row.label)
                        .font(.callout)
                        .csForeground(CSColor.textSecondary)
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
        ContentCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Confidence over time",
                              subtitle: "Average confidence per day",
                              symbol: "waveform.path.ecg.rectangle")
                ConfidenceTrendChart(trends: trends)
                    .frame(height: 160)
                    .accessibilityLabel("Confidence over time. Orange dots mark days with confidence adjustments.")
            }
        }
    }

    // MARK: - Accuracy by category

    private func accuracySection(_ accuracy: RecommendationAccuracy) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Accuracy by category", symbol: "list.bullet.rectangle")
                if accuracy.categoryAccuracy.isEmpty {
                    Text("No category-level feedback yet.")
                        .font(.callout).csForeground(CSColor.textSecondary)
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
                                    .csForeground(CSColor.textSecondary)
                                    .frame(width: 42, alignment: .trailing)
                                    .accessibilityLabel("\(category.accuracy.percentString) accuracy")
                                Text("\(category.accepted) / \(category.total)")
                                    .font(.caption.monospacedDigit())
                                    .csForeground(CSColor.textTertiary)
                                    .frame(width: 56, alignment: .trailing)
                                    .accessibilityLabel("\(category.accepted) accepted of \(category.total)")
                            }
                        }
                    }
                }
            }
        }
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
                        .foregroundStyle(Color.cs(CSColor.warning))
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
                    .csForeground(CSColor.textTertiary)
            }
            Spacer()
            HStack(spacing: 6) {
                ProgressView(value: preference.confidence)
                    .frame(width: 70)
                    .accessibilityLabel("Confidence \(preference.confidence.percentString)")
                Text(preference.confidence.percentString)
                    .font(.caption.monospacedDigit())
                    .csForeground(CSColor.textSecondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cs(CSColor.surface), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                        .csForeground(CSColor.textSecondary)
                }
                Text(pattern.description)
                    .font(.callout)
                    .csForeground(CSColor.textSecondary)
                Text("First seen \(pattern.firstSeen.relativeTime) · Last seen \(pattern.lastSeen.relativeTime)")
                    .font(.caption2)
                    .csForeground(CSColor.textTertiary)
            }
            Spacer()
            HStack(spacing: 6) {
                ProgressView(value: pattern.confidence)
                    .frame(width: 70)
                    .accessibilityLabel("Confidence \(pattern.confidence.percentString)")
                Text(pattern.confidence.percentString)
                    .font(.caption.monospacedDigit())
                    .csForeground(CSColor.textSecondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cs(CSColor.surface), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pattern.patternType.title) pattern: \(pattern.description), \(pattern.occurrences) occurrences")
    }
}