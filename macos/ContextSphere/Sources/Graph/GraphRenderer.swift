import SwiftUI

// MARK: - Renderer abstraction

protocol GraphRenderer {
    func render(state: GraphRenderState, in context: inout GraphicsContext, size: CGSize)
}

// MARK: - Canvas renderer

/// Native SwiftUI Canvas renderer. Receives a `GraphRenderState` and
/// draws edges then nodes. No SQLite, no layout, no gesture logic.
struct CanvasGraphRenderer: GraphRenderer {
    func render(state: GraphRenderState, in context: inout GraphicsContext, size: CGSize) {
        // Cluster halos (overview)
        for hull in state.clusterHulls {
            let rect = CGRect(x: hull.center.x - hull.radius, y: hull.center.y - hull.radius,
                              width: hull.radius * 2, height: hull.radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(hull.color.opacity(hull.opacity)))
            context.stroke(Path(ellipseIn: rect),
                           with: .color(hull.color.opacity(0.15)),
                           lineWidth: 0.7)
        }

        // Edges — drawn first, subordinate to nodes
        for edge in state.edges {
            var path = Path()
            path.move(to: edge.sourceScreen)
            path.addLine(to: edge.targetScreen)
            let color: Color = {
                if edge.isHighlighted { return Color.cs(CSColor.graphEdgeHighlight) }
                if edge.isDimmed { return Color.cs(CSColor.graphEdgeAmbient).opacity(0.5) }
                return Color.cs(CSColor.graphEdge)
            }()
            switch edge.style {
            case .solid:
                context.stroke(path, with: .color(color.opacity(edge.opacity)),
                               lineWidth: edge.lineWidth)
            case .dashed:
                context.stroke(path, with: .color(color.opacity(edge.opacity)),
                               style: StrokeStyle(lineWidth: edge.lineWidth, dash: [5, 4]))
            case .dotted:
                context.stroke(path, with: .color(color.opacity(edge.opacity)),
                               style: StrokeStyle(lineWidth: edge.lineWidth, dash: [1.5, 4], dashPhase: 1))
            }
            if edge.isHighlighted {
                context.stroke(path, with: .color(Color.cs(CSColor.graphEdgeHighlight).opacity(0.18)),
                               lineWidth: edge.lineWidth + 3)
            }
            // Calm recent dot
            if edge.isRecent && !edge.isDimmed && state.semanticLevel != .overview {
                let mid = CGPoint(x: (edge.sourceScreen.x + edge.targetScreen.x) / 2,
                                  y: (edge.sourceScreen.y + edge.targetScreen.y) / 2)
                let dotR: CGFloat = 2.0 + CGFloat(edge.activityIntensity * 1.2)
                let dot = Path(ellipseIn: CGRect(x: mid.x - dotR, y: mid.y - dotR,
                                                 width: dotR * 2, height: dotR * 2))
                context.fill(dot, with: .color(Color.cs(CSColor.warning).opacity(0.50 * edge.activityIntensity)))
                context.stroke(dot, with: .color(Color.cs(CSColor.textOnAccent).opacity(0.65)), lineWidth: 0.6)
            }
        }

        // Nodes
        for node in state.nodes {
            let r = node.radius
            let center = node.screen

            // Focus halo
            if node.isFocused {
                let outer = Path(ellipseIn: CGRect(x: center.x - r - 11, y: center.y - r - 11,
                                                   width: (r + 11) * 2, height: (r + 11) * 2))
                context.fill(outer, with: .color(Color.cs(CSColor.graphHalo)))
                context.stroke(outer, with: .color(Color.cs(CSColor.graphFocus).opacity(0.32)),
                               lineWidth: 1.2)
                let inner = Path(ellipseIn: CGRect(x: center.x - r - 6, y: center.y - r - 6,
                                                   width: (r + 6) * 2, height: (r + 6) * 2))
                context.fill(inner, with: .color(Color.cs(CSColor.textOnAccent).opacity(0.06)))
            }
            if node.isSelected {
                let halo = Path(ellipseIn: CGRect(x: center.x - r - 5.5, y: center.y - r - 5.5,
                                                  width: (r + 5.5) * 2, height: (r + 5.5) * 2))
                context.fill(halo, with: .color(Color.cs(CSColor.graphFocus).opacity(0.20)))
            }
            if node.isRecent && !node.isSelected && !node.isFocused && state.semanticLevel != .overview {
                let pulseR = r + 4 + CGFloat(node.activityIntensity * 3)
                let halo = Path(ellipseIn: CGRect(x: center.x - pulseR, y: center.y - pulseR,
                                                  width: pulseR * 2, height: pulseR * 2))
                context.stroke(halo, with: .color(node.color.opacity(0.18 * node.activityIntensity)),
                               lineWidth: 1.1)
                let inner = Path(ellipseIn: CGRect(x: center.x - r - 2, y: center.y - r - 2,
                                                   width: (r + 2) * 2, height: (r + 2) * 2))
                context.fill(inner, with: .color(node.color.opacity(0.07 * node.activityIntensity)))
            }
            if node.relevance > 0.68 && !node.isSelected && !node.isFocused && !node.isRecent
                && state.semanticLevel != .overview {
                let relR = r + 3 + CGFloat((node.relevance - 0.68) * 5)
                let halo = Path(ellipseIn: CGRect(x: center.x - relR, y: center.y - relR,
                                                  width: relR * 2, height: relR * 2))
                context.stroke(halo,
                               with: .color(node.color.opacity(0.14 * (node.relevance - 0.5))),
                               lineWidth: 0.9)
            }

            // Main disc
            let disc = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                              width: r * 2, height: r * 2))
            context.fill(disc,
                         with: .color(node.color.opacity(node.isHovered ? 1.0 :
                                                          max(0.82 * node.opacity, 0.22))))
            // Gloss
            if r >= 12 {
                let highlight = Path(ellipseIn: CGRect(x: center.x - r * 0.55, y: center.y - r * 0.65,
                                                       width: r * 0.9, height: r * 0.6))
                context.fill(highlight,
                             with: .color(Color.cs(CSColor.textOnAccent).opacity(0.14 * node.opacity)))
            }
            // Stroke
            let strokeColor: Color = node.isSelected
                ? Color.cs(CSColor.graphFocus)
                : Color.cs(CSColor.textPrimary).opacity(0.22)
            let strokeWidth: CGFloat = node.isSelected ? 2 : (node.isFocused ? 1.6 : 0.7)
            context.stroke(disc, with: .color(strokeColor.opacity(node.opacity)),
                           lineWidth: strokeWidth)

            // Symbol
            if r >= 9.5 {
                let glyphSize = r * 0.92
                let symbol = context.resolve(
                    Text(Image(systemName: node.symbol))
                        .font(.system(size: glyphSize, weight: .semibold))
                        .foregroundStyle(Color.cs(CSColor.textOnAccent).opacity(0.95 * node.opacity))
                )
                context.draw(symbol, at: center)
            }

            // Label (post-collision gate)
            if node.labelVisible {
                let title = node.displayTitle
                let label = context.resolve(
                    Text(title)
                        .font(.system(size: 11,
                                      weight: node.isSelected || node.isFocused
                                        ? .semibold : .regular))
                        .foregroundStyle(Color.cs(CSColor.textPrimary).opacity(node.opacity))
                )
                let ms = label.measure(in: CGSize(width: 170, height: CGFloat.greatestFiniteMagnitude))
                let labelOrigin = CGPoint(x: center.x, y: center.y + r + ms.height / 2 + 4)
                let pad: CGFloat = 3
                let bgRect = CGRect(x: labelOrigin.x - ms.width / 2 - pad,
                                    y: labelOrigin.y - ms.height / 2 - pad / 2,
                                    width: ms.width + pad * 2, height: ms.height + pad)
                context.fill(Path(roundedRect: bgRect, cornerRadius: 4),
                             with: .color(Color.cs(CSColor.surface).opacity(0.78 * node.opacity)))
                context.draw(label, at: labelOrigin)
            }
        }
    }
}

// MARK: - Metal stub

/// Placeholder so the abstraction is real. Metal is not instantiated
/// until Canvas measurements justify it.
struct MetalGraphRenderer: GraphRenderer {
    private let fallback = CanvasGraphRenderer()
    func render(state: GraphRenderState, in context: inout GraphicsContext, size: CGSize) {
        var ctx = context
        fallback.render(state: state, in: &ctx, size: size)
        context = ctx
    }
}
