import SwiftUI

/// Deterministic, restrained application → color mapping for Activity.
/// Same app always maps to same muted color; rendering is stable.
/// Palette is deliberately muted to stay calm in the dark ContextSphere UI.
enum AppColorProvider {
    /// Muted, restrained palette — 10 distinct but desaturated tones that
    /// sit comfortably in the dark glass aesthetic. Not a rainbow.
    static let palette: [Color] = [
        Color(red: 0.42, green: 0.56, blue: 0.84), // muted blue (Xcode-like)
        Color(red: 0.52, green: 0.68, blue: 0.72), // muted teal-grey
        Color(red: 0.70, green: 0.58, blue: 0.68), // muted mauve
        Color(red: 0.78, green: 0.62, blue: 0.52), // warm sand / terra
        Color(red: 0.56, green: 0.70, blue: 0.62), // sage green
        Color(red: 0.68, green: 0.64, blue: 0.78), // muted periwinkle
        Color(red: 0.78, green: 0.62, blue: 0.60), // dusty rose
        Color(red: 0.62, green: 0.66, blue: 0.74), // steel blue-grey
        Color(red: 0.58, green: 0.72, blue: 0.68), // eucalyptus
        Color(red: 0.74, green: 0.68, blue: 0.52), // muted mustard
    ]

    /// Explicit overrides for stable, recognizable apps — ensures Xcode,
    /// Safari etc keep a sensible hue even if palette order changes.
    private static let known: [String: Color] = [
        "xcode":                 palette[0],
        "safari":                Color(red: 0.38, green: 0.64, blue: 0.86),
        "terminal":              Color(red: 0.38, green: 0.38, blue: 0.42),
        "finder":                Color(red: 0.58, green: 0.64, blue: 0.72),
        "opera gx":              Color(red: 0.82, green: 0.38, blue: 0.38), // muted red
        "opera":                 Color(red: 0.82, green: 0.38, blue: 0.38),
        "contextsphere":         Color(red: 0.58, green: 0.52, blue: 0.82), // muted indigo
        "context sphere":        Color(red: 0.58, green: 0.52, blue: 0.82),
        "chatgpt classic":       Color(red: 0.42, green: 0.68, blue: 0.58),
        "chatgpt":               Color(red: 0.42, green: 0.68, blue: 0.58),
        "vs code":               palette[0],
        "visual studio code":    palette[0],
        "code":                  palette[0],
        "chrome":                Color(red: 0.78, green: 0.60, blue: 0.48),
        "firefox":               Color(red: 0.84, green: 0.52, blue: 0.34),
        "slack":                 Color(red: 0.48, green: 0.68, blue: 0.62),
        "notes":                 Color(red: 0.78, green: 0.72, blue: 0.52),
        "preview":               Color(red: 0.72, green: 0.66, blue: 0.58),
        "system":                Color(red: 0.60, green: 0.62, blue: 0.66),
    ]

    /// Deterministic color for any app name/id. Stable across renders.
    static func color(for app: String) -> Color {
        let key = app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = known[key] { return exact }
        // Hash fallback: djb2 stable across runs
        var hash: UInt64 = 5381
        for scalar in key.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ UInt64(scalar.value)
        }
        let idx = Int(hash % UInt64(palette.count))
        return palette[idx]
    }

    /// Donut display helper: merges tiny slices (< threshold) into "Other"
    /// so the chart doesn't produce hairline artifacts with round caps.
    /// Keeps original percentages for calculations; only display is merged.
    static func displayDonut(_ segments: [ActivityDonutSegment], threshold: Double = 0.015) -> [ActivityDonutSegment] {
        // If all segments are already above threshold or count <= 4, keep as is
        let tiny = segments.filter { $0.percent > 0 && $0.percent < threshold }
        guard !tiny.isEmpty, segments.count > 3 else {
            // Still filter zero-percent artifacts
            let filtered = segments.filter { $0.percent >= 0.001 }
            return filtered.isEmpty ? segments : filtered
        }
        // Keep large segments
        let large = segments.filter { $0.percent >= threshold }
        let otherPercent = tiny.reduce(0.0) { $0 + $1.percent }
        let otherMinutes = tiny.reduce(0) { $0 + $1.minutes }
        guard otherPercent > 0 else { return large }
        // Only create Other if merged slice is still meaningful; otherwise drop tinies
        if otherPercent < 0.008 {
            return large
        }
        var result = large
        result.append(ActivityDonutSegment(id: "__other__", label: "Other", percent: otherPercent, minutes: otherMinutes))
        // Sort by percent desc for stable legend order
        result.sort { $0.percent > $1.percent }
        return result
    }

    /// Color for a donut segment, including the synthetic "Other" bucket.
    static func color(for segment: ActivityDonutSegment) -> Color {
        if segment.id == "__other__" {
            return Color(red: 0.62, green: 0.64, blue: 0.68).opacity(0.85)
        }
        // Prefer label (displayName) for user-visible mapping; fall back to id
        let key = segment.label.isEmpty ? segment.id : segment.label
        return color(for: key)
    }
}
