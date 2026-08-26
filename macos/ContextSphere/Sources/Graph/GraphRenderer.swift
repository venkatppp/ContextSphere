import SwiftUI

// MARK: - Renderer abstraction (prompt §9)

protocol GraphRenderer {
    func render(state: GraphRenderState, in context: inout GraphicsContext, size: CGSize)
}

// MARK: - Canvas renderer

/// Native SwiftUI Canvas renderer. Receives a `GraphRenderState` and draws
/// edges then nodes. No SQLite, no layout, no gesture logic.
struct CanvasGraphRenderer: GraphRenderer {
    func render(state: GraphRenderState, in context: inout GraphicsContext, size: CGSize) {
        // Cluster halos (overview)
        for hull in state.clusterHulls {
            let rect = CGRect(x: hull.center.x - hull.radius, y: hull.center.y - hull.radius,
                              width: hull.radius * 2, height: hull.radius * 2)
            // Subtle cluster wash
            context.fill(Path(ellipseIn: rect), with: .color(hull.color.opacity(hull.opacity)))
            context.stroke(Path(ellipseIn: rect), with: .color(hull.color.opacity(0.18)), lineWidth: 0.8)
        }

        // Edges — drawn first, subordinate to nodes
        for edge in state.edges {
            var path = Path()
            path.move(to: edge.sourceScreen)
            path.addLine(to: edge.targetScreen)
            let color: Color = {
                if edge.isHighlighted { return .accentColor }
                if edge.isDimmed { return .gray.opacity(0.5) }
                return Color.gray
            }()
            switch edge.style {
            case .solid:
                context.stroke(path, with: .color(color.opacity(edge.opacity)), lineWidth: edge.lineWidth)
            case .dashed:
                context.stroke(path, with: .color(color.opacity(edge.opacity)),
                               style: StrokeStyle(lineWidth: edge.lineWidth, dash: [5, 4]))
            case .dotted:
                context.stroke(path, with: .color(color.opacity(edge.opacity)),
                               style: StrokeStyle(lineWidth: edge.lineWidth, dash: [1.5, 4], dashPhase: 1))
            }
            // Subtle highlight glow for focused edges
            if edge.isHighlighted {
                context.stroke(path, with: .color(.accentColor.opacity(0.18)), lineWidth: edge.lineWidth + 3)
            }
            // Temporal recent dot at midpoint — calm, not animated (prompt §11)
            if edge.isRecent && !edge.isDimmed && state.semanticLevel != .overview {
                let mid = CGPoint(x: (edge.sourceScreen.x + edge.targetScreen.x) / 2,
                                  y: (edge.sourceScreen.y + edge.targetScreen.y) / 2)
                let dotR: CGFloat = 2.0 + CGFloat(edge.activityIntensity * 1.2)
                let dot = Path(ellipseIn: CGRect(x: mid.x - dotR, y: mid.y - dotR, width: dotR*2, height: dotR*2))
                context.fill(dot, with: .color(.orange.opacity(0.50 * edge.activityIntensity)))
                context.stroke(dot, with: .color(.white.opacity(0.70)), lineWidth: 0.6)
            }
        }

        // Nodes
        for node in state.nodes {
            let r = node.radius
            let center = node.screen

            // Focus halo (outermost)
            if node.isFocused {
                let halo = Path(ellipseIn: CGRect(x: center.x - r - 9, y: center.y - r - 9,
                                                   width: (r + 9) * 2, height: (r + 9) * 2))
                context.fill(halo, with: .color(node.color.opacity(0.14)))
            }
            // Selection halo
            if node.isSelected {
                let halo = Path(ellipseIn: CGRect(x: center.x - r - 5.5, y: center.y - r - 5.5,
                                                   width: (r + 5.5) * 2, height: (r + 5.5) * 2))
                context.fill(halo, with: .color(.accentColor.opacity(0.20)))
            }
            // Temporal recent halo — calm, not flashing (prompt §10)
            if node.isRecent && !node.isSelected && !node.isFocused && state.semanticLevel != .overview {
                let pulseR = r + 4 + CGFloat(node.activityIntensity * 3)
                let halo = Path(ellipseIn: CGRect(x: center.x - pulseR, y: center.y - pulseR, width: pulseR*2, height: pulseR*2))
                context.stroke(halo, with: .color(node.color.opacity(0.18 * node.activityIntensity)), lineWidth: 1.1)
                let inner = Path(ellipseIn: CGRect(x: center.x - r - 2, y: center.y - r - 2, width: (r+2)*2, height: (r+2)*2))
                context.fill(inner, with: .color(node.color.opacity(0.07 * node.activityIntensity)))
            }
            // Relevance primary halo — subtle emphasis for what matters now (not neon)
            if node.relevance > 0.68 && !node.isSelected && !node.isFocused && !node.isRecent && state.semanticLevel != .overview {
                let relR = r + 3 + CGFloat((node.relevance - 0.68) * 5)
                let halo = Path(ellipseIn: CGRect(x: center.x - relR, y: center.y - relR, width: relR*2, height: relR*2))
                context.stroke(halo, with: .color(node.color.opacity(0.14 * (node.relevance - 0.5))), lineWidth: 0.9)
            }

            // Main disc
            let disc = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                              width: r * 2, height: r * 2))
            // Opacity implements focus/context dimming (§14)
            context.fill(disc, with: .color(node.color.opacity(node.isHovered ? 1.0 : max(0.82 * node.opacity, 0.22))))
            // Subtle material highlight (top-left gloss)
            if r >= 12 {
                let highlight = Path(ellipseIn: CGRect(x: center.x - r * 0.55, y: center.y - r * 0.65,
                                                       width: r * 0.9, height: r * 0.6))
                context.fill(highlight, with: .color(.white.opacity(0.16 * node.opacity)))
            }
            // Stroke
            let strokeColor: Color = node.isSelected ? .accentColor : .primary.opacity(0.28)
            let strokeWidth: CGFloat = node.isSelected ? 2 : (node.isFocused ? 1.6 : 0.85)
            context.stroke(disc, with: .color(strokeColor.opacity(node.opacity)), lineWidth: strokeWidth)

            // Symbol when large enough (semantic zoom gates this via radius anyway)
            if r >= 9.5 {
                let glyphSize = r * 0.92
                let symbol = context.resolve(
                    Text(Image(systemName: node.symbol))
                        .font(.system(size: glyphSize, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95 * node.opacity))
                )
                let glyphPos = CGPoint(x: center.x, y: center.y)
                context.draw(symbol, at: glyphPos)
            }

            // Label (semantic zoom)
            if node.labelVisible {
                let title = node.title.count > 28 ? String(node.title.prefix(27)) + "…" : node.title
                // Halo behind label for legibility without card noise
                let label = context.resolve(
                    Text(title)
                        .font(.caption2.weight(node.isSelected || node.isFocused ? .semibold : .regular))
                        .foregroundStyle(.primary.opacity(node.opacity))
                )
                let ms = label.measure(in: CGSize(width: 170, height: CGFloat.greatestFiniteMagnitude))
                let labelOrigin = CGPoint(x: center.x, y: center.y + r + ms.height / 2 + 5)
                // Soft backdrop
                let pad: CGFloat = 3
                let bgRect = CGRect(x: labelOrigin.x - ms.width / 2 - pad,
                                    y: labelOrigin.y - ms.height / 2 - pad / 2,
                                    width: ms.width + pad * 2, height: ms.height + pad)
                context.fill(Path(roundedRect: bgRect, cornerRadius: 4),
                             with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.72 * node.opacity)))
                context.draw(label, at: labelOrigin)
            }
        }
    }
}

// MARK: - Metal stub (future)

/// Placeholder so the abstraction is real (prompt §9 recommends
/// GraphRenderer → CanvasGraphRenderer | MetalGraphRenderer). Metal
/// is not instantiated until Canvas measurements justify it.
struct MetalGraphRenderer: GraphRenderer {
    private let fallback = CanvasGraphRenderer()
    func render(state: GraphRenderState, in context: inout GraphicsContext, size: CGSize) {
        // Today: Canvas is sufficient (see performance notes).
        // When a benchmark shows Canvas < 55 FPS at 1k nodes, replace
        // this with a MetalKit encoder that consumes the same RenderState.
        var ctx = context
        fallback.render(state: state, in: &ctx, size: size)
        context = ctx
    }
}
