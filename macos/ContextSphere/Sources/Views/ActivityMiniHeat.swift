import SwiftUI

/// Compact daily-intensity strip rendered below the KPI tiles —
/// backed by real `HourlyActivity` from `ActivityService::build_hourly_activity`.
/// Buckets are hourly, intensity 0..1 normalized, labels are logical hour
/// boundaries derived from actual activity window, never hard-coded.
struct ActivityMiniHeat: View {
    var hourlyActivity: HourlyActivity? = nil
    @State private var hoveredIndex: Int? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let ha = hourlyActivity, !ha.buckets.isEmpty {
                HStack(spacing: 3) {
                    ForEach(0..<ha.buckets.count, id: \.self) { idx in
                        let bucket = ha.buckets[idx]
                        let isHovered = hoveredIndex == idx
                        let fillColor: Color = bucket.intensity == 0
                            ? Color.cs(CSColor.textTertiary).opacity(0.10)
                            : Color.accentColor.opacity(0.18 + bucket.intensity * 0.72)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(fillColor)
                            .frame(height: isHovered ? 20 : 18)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .strokeBorder(isHovered ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 0.5)
                            )
                            .onHover { hovering in
                                hoveredIndex = hovering ? idx : nil
                            }
                            .help("\(bucket.label) — \(formatActive(bucket.activeSeconds)) — \(bucket.eventCount) events")
                            .accessibilityLabel("\(bucket.label), \(Int(bucket.intensity * 100))% intensity")
                    }
                }
                .frame(height: 20)
                .accessibilityHidden(false)
                .accessibilityLabel("Hourly activity from \(ha.startLabel) to \(ha.endLabel)")
                // Logical time-range labels — never hard-coded 09:00/17:00
                HStack {
                    if ha.buckets.count <= 6 {
                        // Few buckets: show every label
                        ForEach(ha.buckets) { b in
                            Text(b.label)
                                .font(.csTiny.monospacedDigit())
                                .csForeground(CSColor.textTertiary)
                            if b.id != ha.buckets.last?.id {
                                Spacer()
                            }
                        }
                    } else {
                        // Many buckets: show start, middle, end to avoid overlap
                        Text(ha.startLabel).font(.system(size: 12).monospacedDigit()).csForeground(CSColor.textTertiary)
                        Spacer()
                        if let mid = ha.buckets.dropFirst(ha.buckets.count / 3).first {
                            Text(mid.label).font(.system(size: 12).monospacedDigit()).csForeground(CSColor.textTertiary)
                            Spacer()
                        }
                        Text(ha.endLabel).font(.system(size: 12).monospacedDigit()).csForeground(CSColor.textTertiary)
                    }
                }
                if let idx = hoveredIndex, idx < ha.buckets.count {
                    let b = ha.buckets[idx]
                    Text("\(b.label) — \(formatActive(b.activeSeconds)) — \(b.eventCount) events")
                        .font(.csTiny)
                        .csForeground(CSColor.textSecondary)
                        .transition(.opacity)
                }
            } else {
                // No hourly data yet — honest empty, not fake 09:00–17:00
                HStack(spacing: 3) {
                    ForEach(0..<12, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.cs(CSColor.textTertiary).opacity(0.06))
                            .frame(height: 18)
                    }
                }
                .frame(height: 18)
                .accessibilityHidden(true)
                HStack {
                    Text("No hourly activity yet").font(.csTiny).csForeground(CSColor.textTertiary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 2)
        .animation(Theme.quick(reduceMotion), value: hoveredIndex)
    }

    private func formatActive(_ secs: Int) -> String {
        if secs <= 0 { return "0 min" }
        if secs < 60 { return "\(secs)s" }
        let m = secs / 60
        if m < 60 { return "\(m) min" }
        let h = m / 60
        let rem = m % 60
        return rem == 0 ? "\(h)h" : "\(h)h \(rem)m"
    }
}
