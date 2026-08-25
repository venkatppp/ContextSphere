import SwiftUI

// MARK: - Graph camera (prompt §10)

/// Dedicated camera for the context graph. Owns pan, zoom, focus and
/// semantic-zoom state and the world↔screen transforms. The renderer and
/// view never compute transforms ad-hoc — they ask the camera.
///
/// Conceptually:
///   center = world point at viewport centre
///   zoom   = points per world unit (1.0 = 1:1)
///   viewport = canvas size in points
final class GraphCamera: ObservableObject {
    @Published var center: CGPoint = .zero
    @Published var zoom: CGFloat = 1.0
    @Published var viewport: CGSize = .zero

    let minZoom: CGFloat = 0.25
    let maxZoom: CGFloat = 5.0

    /// Semantic zoom derived from zoom (prompt §11).
    enum SemanticLevel: String {
        case overview   // clusters, important nodes, no labels
        case normal     // important labels, relationships visible
        case detailed   // all labels, icons, metadata, edge details
    }

    var semanticLevel: SemanticLevel {
        if zoom < 0.7 { return .overview }
        if zoom < 1.35 { return .normal }
        return .detailed
    }

    var transform: CGAffineTransform {
        CGAffineTransform.identity
            .translatedBy(x: viewport.width / 2 - center.x * zoom,
                          y: viewport.height / 2 - center.y * zoom)
            .scaledBy(x: zoom, y: zoom)
    }

    var inverseTransform: CGAffineTransform { transform.inverted() }

    func worldToScreen(_ world: CGPoint) -> CGPoint {
        CGPoint(x: world.x * zoom + viewport.width / 2 - center.x * zoom,
                y: world.y * zoom + viewport.height / 2 - center.y * zoom)
    }

    func screenToWorld(_ screen: CGPoint) -> CGPoint {
        CGPoint(x: (screen.x - viewport.width / 2) / zoom + center.x,
                y: (screen.y - viewport.height / 2) / zoom + center.y)
    }

    func visibleWorldRect(inset: CGFloat = 80) -> CGRect {
        let tl = screenToWorld(.zero)
        let br = screenToWorld(CGPoint(x: viewport.width, y: viewport.height))
        return CGRect(x: min(tl.x, br.x) - inset, y: min(tl.y, br.y) - inset,
                      width: abs(br.x - tl.x) + inset * 2,
                      height: abs(br.y - tl.y) + inset * 2)
    }

    // MARK: Mutations

    func setViewport(_ size: CGSize) { viewport = size }

    func pan(by translation: CGSize) {
        center.x -= translation.width / zoom
        center.y -= translation.height / zoom
    }

    func zoom(by factor: CGFloat, anchor: CGPoint? = nil) {
        let newZoom = min(max(zoom * factor, minZoom), maxZoom)
        guard let anchor else { zoom = newZoom; return }
        // Keep anchor stable in world space
        let before = screenToWorld(anchor)
        zoom = newZoom
        let after = screenToWorld(anchor)
        center.x += before.x - after.x
        center.y += before.y - after.y
    }

    func setZoom(_ value: CGFloat, anchor: CGPoint? = nil) {
        zoom(by: value / zoom, anchor: anchor)
    }

    /// Smoothly focuses on a world point.
    func focus(on world: CGPoint, zoom targetZoom: CGFloat? = nil, animated: Bool = true) {
        let z = targetZoom.map { min(max($0, minZoom), maxZoom) } ?? max(zoom, 1.2)
        if animated {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                self.center = world
                self.zoom = z
            }
        } else {
            center = world
            zoom = z
        }
    }

    /// Fits all positions into the viewport with padding.
    func fit(positions: [String: CGPoint], padding: CGFloat = 0.85, animated: Bool = true) {
        guard !positions.isEmpty, viewport.width > 0, viewport.height > 0 else { return }
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in positions.values {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let spanX = max(maxX - minX, 1)
        let spanY = max(maxY - minY, 1)
        let targetZoom = min(viewport.width / spanX, viewport.height / spanY) * padding
        let clamped = min(max(targetZoom, minZoom), maxZoom)
        let targetCenter = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        if animated {
            withAnimation(.easeOut(duration: 0.32)) {
                self.center = targetCenter
                self.zoom = clamped
            }
        } else {
            center = targetCenter
            zoom = clamped
        }
    }

    func clampZoom(_ value: CGFloat) -> CGFloat { min(max(value, minZoom), maxZoom) }
}
