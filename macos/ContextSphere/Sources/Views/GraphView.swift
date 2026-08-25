import SwiftUI

/// Native Canvas-based context graph for ContextSphere.
///
/// Hierarchy: macOS background → Canvas → floating glass search →
/// floating glass controls → glass inspector. Interaction: drag to pan,
/// pinch to zoom, click to select, double-click to expand, hover for
/// feedback. All data comes from the Rust graph engine via `CoreBridge`.
struct GraphScreen: View {
    @ObservedObject var viewModel: GraphViewModel

    private let minScale: CGFloat = 0.25
    private let maxScale: CGFloat = 4.0
    private let labelCharLimit = 30

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var hoveredNodeID: String?
    @State private var canvasSize: CGSize = .zero
    @State private var panAnchor: CGSize?
    @State private var magnifyBaseScale: CGFloat?
    @State private var needsFit = true

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                canvasArea(geo.size)
                searchSurface
                    .padding(16)
                if viewModel.isExpanding {
                    expandingBadge
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 18)
                }
                statusBar
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(16)
                controls
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(16)
                if viewModel.showInspector {
                    GraphInspectorView(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .padding(16)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                stateOverlay
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: viewModel.positions)
        .animation(.easeOut(duration: 0.25), value: viewModel.showInspector)
        .task { viewModel.initialLoadIfNeeded() }
        .onChange(of: viewModel.layoutGeneration) { _, _ in
            needsFit = true
        }
        .onChange(of: canvasSize) { _, newSize in
            if needsFit, newSize.width > 0 {
                applyFit()
            }
        }
        .onChange(of: viewModel.focusNonce) { _, _ in
            focusOnRequestedNode()
        }
    }

    // MARK: - Canvas

    private func canvasArea(_ size: CGSize) -> some View {
        Canvas { context, canvasSize in
            drawGraph(in: &context, size: canvasSize)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .background(Color.clear)
        .gesture(panGesture)
        .gesture(magnifyGesture)
        .gesture(ExclusiveGesture(doubleTapGesture, tapGesture))
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                hoveredNodeID = hitTest(location, size: canvasSize)
            case .ended:
                hoveredNodeID = nil
            }
        }
        .onAppear { canvasSize = size }
        .onChange(of: size) { _, newSize in
            canvasSize = newSize
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context graph")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let nodeCount = viewModel.nodes.count
        let edgeCount = viewModel.visibleEdges.count
        var text = "Context graph: \(nodeCount) nodes and \(edgeCount) relationships"
        if let selected = viewModel.selectedNode {
            text += ". Selected: \(selected.title), \(selected.nodeType.title)"
            if let workspace = viewModel.workspaceName(for: selected) {
                text += ", in workspace \(workspace)"
            }
        }
        return text
    }

    private func drawGraph(in context: inout GraphicsContext, size: CGSize) {
        guard viewModel.state == .loaded else { return }

        let visibleWorld = visibleWorldRect(size: size)
        let nodes = viewModel.nodes
        let positions = viewModel.positions

        // Edges stay visually subordinate: hairline strokes, opacity
        // scaled by weight.
        for edge in viewModel.visibleEdges {
            guard let source = positions[edge.sourceID],
                  let target = positions[edge.targetID],
                  visibleWorld.intersects(worldRect(source, target)) else { continue }
            var path = Path()
            path.move(to: screenPoint(source, size: size))
            path.addLine(to: screenPoint(target, size: size))
            context.stroke(path,
                           with: .color(edgeColor(edge)),
                           lineWidth: max(0.5, edge.weight * 1.1))
        }

        // Nodes.
        let showLabels = (scale >= 0.5 && nodes.count <= 250) || scale >= 1.2
        for node in nodes {
            guard let world = positions[node.id],
                  visibleWorld.contains(world) else { continue }
            drawNode(node, at: world, size: size,
                     in: &context, showLabel: showLabels)
        }
    }

    private func drawNode(_ node: KgNode, at world: CGPoint, size: CGSize,
                          in context: inout GraphicsContext, showLabel: Bool) {
        let point = screenPoint(world, size: size)
        let baseRadius = node.nodeType.nodeRadius
        let radius = baseRadius * scale
        let isSelected = node.id == viewModel.selectedNodeID
        let isFocused = node.id == viewModel.focusedNodeID
        let isHovered = node.id == hoveredNodeID
        let color = node.nodeType.color

        if isFocused {
            context.fill(Path(ellipseIn: CGRect(x: point.x - radius - 7,
                                                y: point.y - radius - 7,
                                                width: (radius + 7) * 2,
                                                height: (radius + 7) * 2)),
                         with: .color(color.opacity(0.18)))
        }
        if isSelected {
            context.fill(Path(ellipseIn: CGRect(x: point.x - radius - 5,
                                                y: point.y - radius - 5,
                                                width: (radius + 5) * 2,
                                                height: (radius + 5) * 2)),
                         with: .color(Color.accentColor.opacity(0.25)))
        }

        let circle = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                            width: radius * 2, height: radius * 2))
        context.fill(circle, with: .color(color.opacity(isHovered ? 1 : 0.85)))
        context.stroke(circle,
                       with: .color(isSelected ? Color.accentColor : Color.primary.opacity(0.3)),
                       lineWidth: isSelected ? 2 : 0.8)

        // Symbol for nodes big enough to carry one.
        if radius >= 10 {
            let symbol = Text(Image(systemName: node.nodeType.symbol))
                .font(.system(size: radius * 0.95, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
            context.draw(symbol, at: point)
        }

        if showLabel {
            let title = node.title.count > labelCharLimit
                ? String(node.title.prefix(labelCharLimit - 1)) + "…"
                : node.title
            let label = context.resolve(Text(title)
                .font(.caption2)
                .foregroundStyle(.primary))
            let labelSize = label.measure(in: CGSize(width: 160, height: CGFloat.greatestFiniteMagnitude))
            context.draw(label, at: CGPoint(x: point.x, y: point.y + radius + labelSize.height / 2 + 4))
        }
    }

    // MARK: - Transform helpers

    private func screenPoint(_ world: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: world.x * scale + offset.width + size.width / 2,
                y: world.y * scale + offset.height + size.height / 2)
    }

    private func worldPoint(_ screen: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: (screen.x - offset.width - size.width / 2) / scale,
                y: (screen.y - offset.height - size.height / 2) / scale)
    }

    private func visibleWorldRect(size: CGSize) -> CGRect {
        let topLeft = worldPoint(.zero, size: size)
        let bottomRight = worldPoint(CGPoint(x: size.width, y: size.height), size: size)
        return CGRect(x: min(topLeft.x, bottomRight.x) - 80,
                      y: min(topLeft.y, bottomRight.y) - 80,
                      width: abs(bottomRight.x - topLeft.x) + 160,
                      height: abs(bottomRight.y - topLeft.y) + 160)
    }

    private func worldRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func hitTest(_ screen: CGPoint, size: CGSize) -> String? {
        let world = worldPoint(screen, size: size)
        var best: (id: String, distance: CGFloat)?
        for node in viewModel.nodes {
            guard let position = viewModel.positions[node.id] else { continue }
            let hitRadius = max(node.nodeType.nodeRadius, 12) + 8
            let dx = position.x - world.x
            let dy = position.y - world.y
            let distance = sqrt(dx * dx + dy * dy)
            if distance <= hitRadius, best == nil || distance < best!.distance {
                best = (node.id, distance)
            }
        }
        return best?.id
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if panAnchor == nil { panAnchor = offset }
                offset = CGSize(width: panAnchor!.width + value.translation.width,
                                height: panAnchor!.height + value.translation.height)
            }
            .onEnded { _ in
                panAnchor = nil
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if magnifyBaseScale == nil { magnifyBaseScale = scale }
                scale = clampScale(magnifyBaseScale! * value.magnification)
            }
            .onEnded { _ in
                magnifyBaseScale = nil
            }
    }

    private var tapGesture: some Gesture {
        SpatialTapGesture(count: 1, coordinateSpace: .local)
            .onEnded { value in
                if let id = hitTest(value.location, size: canvasSize) {
                    viewModel.selectNode(id)
                }
            }
    }

    private var doubleTapGesture: some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .local)
            .onEnded { value in
                if let id = hitTest(value.location, size: canvasSize),
                   let node = viewModel.nodes.first(where: { $0.id == id }) {
                    viewModel.selectNode(id)
                    viewModel.expand(node)
                }
            }
    }

    // MARK: - Zoom / fit

    private func clampScale(_ value: CGFloat) -> CGFloat {
        min(max(value, minScale), maxScale)
    }

    private func applyFit() {
        needsFit = false
        let positions = viewModel.positions
        guard !positions.isEmpty, canvasSize.width > 0 else { return }
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for point in positions.values {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let spanX = max(maxX - minX, 1)
        let spanY = max(maxY - minY, 1)
        withAnimation(.easeOut(duration: 0.3)) {
            scale = clampScale(min(canvasSize.width / spanX, canvasSize.height / spanY) * 0.85)
            offset = CGSize(width: canvasSize.width / 2 - (minX + maxX) / 2 * scale,
                            height: canvasSize.height / 2 - (minY + maxY) / 2 * scale)
        }
    }

    private func zoom(by factor: CGFloat) {
        withAnimation(.easeOut(duration: 0.15)) {
            scale = clampScale(scale * factor)
        }
    }

    private func focusOnRequestedNode() {
        guard let id = viewModel.selectedNodeID,
              let position = viewModel.positions[id],
              canvasSize.width > 0 else {
            viewModel.consumeFocusRequest()
            return
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            scale = clampScale(max(scale, 1.3))
            offset = CGSize(width: canvasSize.width / 2 - position.x * scale,
                            height: canvasSize.height / 2 - position.y * scale)
        }
        viewModel.consumeFocusRequest()
    }

    // MARK: - Floating search

    private var searchSurface: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Find in graph…", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit { viewModel.submitSearch() }
                    .accessibilityLabel("Search graph nodes")
                if viewModel.isSearching {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Searching graph")
                }
                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear graph search")
                    .accessibilityLabel("Clear graph search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 300)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous))

            if let error = viewModel.searchError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                    .frame(width: 300, alignment: .leading)
                    .accessibilityLabel("Search error: \(error)")
            }

            if !viewModel.searchQuery.isEmpty && !viewModel.isSearching && !viewModel.searchResults.isEmpty {
                searchResultsList
            }
        }
    }

    private var searchResultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(viewModel.searchResults) { node in
                    Button {
                        viewModel.focusSearchResult(node)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: node.nodeType.symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(node.nodeType.color)
                                .frame(width: 16)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(node.title)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                HStack(spacing: 6) {
                                    Text(node.nodeType.title)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                    if let workspace = viewModel.workspaceName(for: node) {
                                        Text(workspace)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            Spacer(minLength: 4)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(node.title), \(node.nodeType.title)")
                    .accessibilityHint("Focuses this node in the graph")
                }
            }
            .padding(6)
        }
        .frame(width: 300)
        .frame(maxHeight: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous)
            .strokeBorder(.separator, lineWidth: 0.5))
        .accessibilityLabel("Graph search results")
    }

    // MARK: - Floating controls

    private var controls: some View {
        HStack(spacing: 4) {
            glassControlButton("minus", help: "Zoom out") { zoom(by: 0.8) }
            glassControlButton("plus", help: "Zoom in") { zoom(by: 1.25) }
            Divider().frame(height: 16)
            glassControlButton("arrow.counterclockwise", help: "Reset view and layout") {
                needsFit = true
                viewModel.resetLayout()
            }
            glassControlButton("arrow.clockwise", help: "Refresh graph") {
                viewModel.refresh()
            }
            Divider().frame(height: 16)
            Menu {
                Picker("Relationship density", selection: $viewModel.edgeDensity) {
                    ForEach(GraphViewModel.EdgeDensity.allCases) { density in
                        Text(density.title).tag(density)
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Relationship density")
            .accessibilityLabel("Relationship density")
            glassControlButton(viewModel.showInspector ? "sidebar.right.fill" : "sidebar.right",
                               help: viewModel.showInspector ? "Hide inspector" : "Show inspector") {
                viewModel.showInspector.toggle()
            }
        }
        .padding(6)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous))
    }

    private func glassControlButton(_ symbol: String, help: String,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text("\(viewModel.nodes.count) nodes · \(viewModel.visibleEdges.count) relationships")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .accessibilityLabel("\(viewModel.nodes.count) nodes, \(viewModel.visibleEdges.count) relationships")
            workspacePicker
        }
    }

    private var workspacePicker: some View {
        Picker("Graph context", selection: Binding(
            get: { viewModel.selectedWorkspaceId },
            set: { viewModel.selectWorkspace($0) }
        )) {
            Text("All workspaces").tag(String?.none)
            ForEach(viewModel.workspaces) { workspace in
                Text(workspace.name).tag(Optional(workspace.id))
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .accessibilityLabel("Graph context workspace")
    }

    private var expandingBadge: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Expanding…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    // MARK: - States

    @ViewBuilder
    private var stateOverlay: some View {
        switch viewModel.state {
        case .idle, .loading:
            LoadingView(label: "Loading context graph…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background.opacity(0.35))
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text("Graph unavailable")
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Retry") {
                    viewModel.retry()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel("Retry loading the graph")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background.opacity(0.45))
            .accessibilityElement(children: .combine)
        case .loaded:
            if viewModel.nodes.isEmpty {
                EmptyStateView(
                    title: "No graph data yet",
                    message: "ContextSphere builds the graph from your workspaces and files. Switch workspace context or search to start exploring.",
                    symbol: "point.3.connected.trianglepath.dotted"
                )
                .background(.background.opacity(0.3))
            }
        }
    }

    // MARK: - Edge presentation

    private func edgeColor(_ edge: KgEdge) -> Color {
        let base: Color
        switch edge.relationshipType {
        case .contains, .runsIn: base = .gray
        case .relatedTo: base = .teal
        case .reportsOn: base = .orange
        case .derivedFrom: base = .purple
        }
        let alpha = min(0.05 + edge.weight * 0.35, 0.5)
        return base.opacity(alpha)
    }
}

// MARK: - Presentation

extension GraphNodeType {
    var title: String {
        switch self {
        case .workspace: "Workspace"
        case .file: "File"
        case .plannerReport: "Planner report"
        case .execution: "Execution"
        case .memoryRecord: "Memory record"
        case .autonomousSession: "Autonomous session"
        }
    }

    var symbol: String {
        switch self {
        case .workspace: "folder.fill"
        case .file: "doc.text.fill"
        case .plannerReport: "chart.bar.doc.horizontal"
        case .execution: "play.circle.fill"
        case .memoryRecord: "brain.head.profile"
        case .autonomousSession: "sparkles"
        }
    }

    var color: Color {
        switch self {
        case .workspace: .indigo
        case .file: .teal
        case .plannerReport: .purple
        case .execution: .orange
        case .memoryRecord: .pink
        case .autonomousSession: .cyan
        }
    }

    /// Drawn radius in world units.
    var nodeRadius: CGFloat {
        switch self {
        case .workspace: 22
        case .file: 9
        default: 13
        }
    }
}

extension GraphRelationshipType {
    var title: String {
        switch self {
        case .contains: "Contains"
        case .runsIn: "Runs in"
        case .reportsOn: "Reports on"
        case .derivedFrom: "Derived from"
        case .relatedTo: "Related to"
        }
    }
}