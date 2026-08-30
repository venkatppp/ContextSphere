import SwiftUI

/// Native Canvas-based Context Field — the living visual representation
/// of computer context.
///
/// Architecture: GraphVisualizationModel → GraphLayoutEngine → GraphRenderState
/// → GraphRenderer (Canvas) → GraphCamera → SwiftUI surface.
/// Each layer is separate; this file owns only the SwiftUI surface.
///
/// Escape behavior (RC-9 §13):
///   1. If the search field is focused, Escape dismisses keyboard focus
///      and clears the search field if it has content. The graph and
///      inspector are NEVER torn down.
///   2. If no field is focused, Escape clears the current node selection
///      (so the inspector closes) but stays on the graph view.
///   3. Escape NEVER navigates away from the graph screen.
struct GraphScreen: View {
    @ObservedObject var viewModel: GraphViewModel
    @StateObject private var camera = GraphCamera()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var searchFieldFocused: Bool

    @State private var hoveredNodeID: String?
    @State private var canvasSize: CGSize = .zero
    @State private var panAnchor: CGPoint?
    @State private var magnifyBaseZoom: CGFloat?
    @State private var needsFit = true
    @State private var containerWidth: CGFloat = 1024

    private let renderer = CanvasGraphRenderer()

    var body: some View {
        VStack(spacing: 0) {
            StandardPageHeader(
                section: .graph,
                activeWorkspace: viewModel.workspaces.first { $0.id == viewModel.selectedWorkspaceId } ?? viewModel.workspaces.first,
                title: "Graph",
                subtitle: headerSubtitle,
                symbol: AppSection.graph.symbol,
                eyebrow: NavGroup.intelligence.title.uppercased()
            ) { workspacePicker }
                .padding(.horizontal, Theme.horizontalPadding(for: containerWidth))
                .padding(.vertical, Theme.pageHeaderVerticalPadding)
            Hairline(opacity: Theme.pageHeaderDividerOpacity)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    canvasArea(geo.size)
                    // Lenses (top-center, compact)
                    lensBar
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 16)
                    // Search surface
                    searchSurface
                        .padding(20)
                    if viewModel.isExpanding {
                        expandingBadge
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 22)
                    }
                    statusBar
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(20)
                    controls
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(20)
                    if viewModel.showInspector {
                        GraphInspectorView(viewModel: viewModel)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                            .padding(20)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    stateOverlay
                }
            }
        }
        .animation(reduceMotion ? .none : .spring(response: 0.45, dampingFraction: 0.85),
                   value: viewModel.positions)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.25), value: viewModel.showInspector)
        .task { viewModel.initialLoadIfNeeded() }
        .onAppear { camera.setViewport(canvasSize) }
        .onChange(of: viewModel.layoutGeneration) { _, _ in needsFit = true }
        .onChange(of: viewModel.lens) { _, _ in
            // Lenses don't change layout, but the render state needs a refresh.
            viewModel.objectWillChange.send()
        }
        .onChange(of: canvasSize) { _, newSize in
            camera.setViewport(newSize)
            if needsFit, newSize.width > 0 { applyFit() }
        }
        .onChange(of: viewModel.focusNonce) { _, _ in focusOnRequestedNode() }
        .onChange(of: viewModel.contextFocusID) { _, _ in
            if viewModel.contextFocusID == nil { needsFit = true }
        }
        .overlay {
            GeometryReader { geo in
                Color.clear
                    .onAppear { containerWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in containerWidth = new }
            }
            .allowsHitTesting(false)
        }
        // Escape handles BOTH the search field and the selection, in that
        // order. It never leaves the Graph view (§13).
        .background {
            Button("") { handleEscape() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
                .accessibilityHidden(true)
        }
    }

    private var headerSubtitle: String {
        if let name = viewModel.contextName {
            return "\(viewModel.nodes.count) nodes · \(viewModel.visibleEdges.count) relationships · \(name)"
        }
        return "\(viewModel.nodes.count) nodes · \(viewModel.visibleEdges.count) relationships"
    }

    // MARK: - Lens bar

    private var lensBar: some View {
        HStack(spacing: 4) {
            ForEach(GraphViewModel.Lens.allCases) { lens in
                Button {
                    viewModel.lens = lens
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: lens.symbol)
                            .font(.system(size: 10, weight: .semibold))
                        Text(lens.title)
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        viewModel.lens == lens
                            ? Color.cs(CSColor.selectionFill)
                            : Color.clear,
                        in: Capsule(style: .continuous)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                viewModel.lens == lens
                                    ? Color.cs(CSColor.selectionBorder)
                                    : Color.cs(CSColor.border),
                                lineWidth: 0.5
                            )
                    )
                }
                .buttonStyle(.plain)
                .csForeground(viewModel.lens == lens
                              ? CSColor.sidebarSelectedTint
                              : CSColor.textPrimary)
                .accessibilityLabel("Lens: \(lens.title)")
                .accessibilityAddTraits(viewModel.lens == lens ? .isSelected : [])
            }
        }
        .padding(5)
        .lgChrome(cornerRadius: Theme.cornerLarge)
    }

    // MARK: - Canvas

    private func canvasArea(_ size: CGSize) -> some View {
        Canvas { context, cSize in
            guard viewModel.state == .loaded, !viewModel.positions.isEmpty else { return }
            let model = viewModel.visualizationModel
            let density: GraphEdgeDensity = viewModel.edgeDensity == .all ? .all : .strong
            // Apply lens: filtered nodes/edges for this view
            let (filteredNodes, filteredEdges) = applyLens(model: model)
            let filteredModel = GraphVisualizationModel(
                nodes: filteredNodes, edges: filteredEdges,
                clusters: model.clusters, workspaceLens: model.workspaceLens,
                adjacency: model.adjacency)
            let state = GraphRenderStateBuilder.build(
                model: filteredModel,
                positions: viewModel.positions,
                camera: camera,
                selectedID: viewModel.selectedNodeID,
                hoveredID: hoveredNodeID,
                focusedID: viewModel.contextFocusID ?? viewModel.focusedNodeID,
                edgeDensity: density,
                relevance: viewModel.relevanceScores
            )
            var ctx = context
            renderer.render(state: state, in: &ctx, size: cSize)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .background(Color.cs(CSColor.surfaceField).opacity(0.45))
        .gesture(panGesture)
        .gesture(magnifyGesture)
        .gesture(ExclusiveGesture(doubleTapGesture, tapGesture))
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let loc): hoveredNodeID = hitTest(loc)
            case .ended: hoveredNodeID = nil
            }
        }
        .onAppear { canvasSize = size }
        .onChange(of: size) { _, s in canvasSize = s }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context graph")
        .accessibilityValue(accessibilitySummary)
    }

    /// Returns a (nodes, edges) tuple restricted by the current lens.
    /// The lens is purely visual: the underlying data is never mutated.
    private func applyLens(model: GraphVisualizationModel) -> ([GraphVisualizationModel.VisualNode],
                                                              [GraphVisualizationModel.VisualEdge]) {
        if let lens = viewModel.lensHighlightedNodeIDs() {
            if lens.isEmpty {
                return (model.nodes, model.edges)
            }
            // Always include the highlighted nodes and their first-degree
            // neighbours so the lens never produces an unreadable isolation.
            var keep = lens
            for edge in model.edges {
                if keep.contains(edge.sourceID) { keep.insert(edge.targetID) }
                if keep.contains(edge.targetID) { keep.insert(edge.sourceID) }
            }
            let nodes = model.nodes.filter { keep.contains($0.id) }
            let edges = model.edges.filter { keep.contains($0.sourceID) && keep.contains($0.targetID) }
            return (nodes, edges)
        }
        return (model.nodes, model.edges)
    }

    private var accessibilitySummary: String {
        var t = "Context field: \(viewModel.nodes.count) nodes, \(viewModel.visibleEdges.count) relationships"
        if let s = viewModel.selectedNode {
            t += ". Selected: \(s.title), \(s.nodeType.title)"
            if let ws = viewModel.workspaceName(for: s) { t += ", in workspace \(ws)" }
        }
        if let f = viewModel.contextFocusID, let n = viewModel.nodes.first(where: { $0.id == f }) {
            t += ". Focused on \(n.title)"
        }
        return t
    }

    private func hitTest(_ screen: CGPoint) -> String? {
        let world = camera.screenToWorld(screen)
        var best: (id: String, d: CGFloat)?
        for (id, p) in viewModel.positions {
            guard let node = viewModel.node(for: id) else { continue }
            let hr = max(node.nodeType.nodeRadius / camera.zoom, 6) + 6
            let dx = p.x - world.x, dy = p.y - world.y
            let d = sqrt(dx * dx + dy * dy)
            if d <= hr, best == nil || d < best!.d { best = (id, d) }
        }
        return best?.id
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if panAnchor == nil { panAnchor = camera.center }
                guard let anchor = panAnchor else { return }
                camera.center = CGPoint(x: anchor.x - v.translation.width / camera.zoom,
                                        y: anchor.y - v.translation.height / camera.zoom)
            }
            .onEnded { _ in panAnchor = nil }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if magnifyBaseZoom == nil { magnifyBaseZoom = camera.zoom }
                camera.setZoom(min(max(magnifyBaseZoom! * v.magnification, camera.minZoom), camera.maxZoom))
            }
            .onEnded { _ in magnifyBaseZoom = nil }
    }

    private var tapGesture: some Gesture {
        SpatialTapGesture(count: 1, coordinateSpace: .local)
            .onEnded { v in
                guard let id = hitTest(v.location) else { return }
                if viewModel.selectedNodeID == id {
                    viewModel.toggleContextFocus(id)
                } else {
                    viewModel.selectNode(id)
                }
            }
    }

    private var doubleTapGesture: some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .local)
            .onEnded { v in
                guard let id = hitTest(v.location),
                      let node = viewModel.nodes.first(where: { $0.id == id }) else { return }
                viewModel.selectNode(id)
                viewModel.expand(node)
                viewModel.setContextFocus(id)
            }
    }

    private func applyFit() {
        needsFit = false
        camera.fit(positions: viewModel.positions, padding: 0.85, animated: !reduceMotion)
    }

    private func zoom(by factor: CGFloat) {
        if reduceMotion {
            camera.zoom(by: factor)
        } else {
            withAnimation(.easeOut(duration: 0.15)) { camera.zoom(by: factor) }
        }
    }

    private func focusOnRequestedNode() {
        guard let id = viewModel.selectedNodeID ?? viewModel.focusedNodeID,
              let pos = viewModel.positions[id] else {
            viewModel.consumeFocusRequest()
            return
        }
        camera.focus(on: pos, zoom: max(camera.zoom, 1.3), animated: !reduceMotion)
        viewModel.consumeFocusRequest()
    }

    // MARK: - Escape handling (RC-9 §13)

    /// Escape must never dismiss the graph. It performs one of:
    /// 1. If the search field is focused → clear focus + clear query.
    /// 2. Else if a node is selected → clear selection (closes inspector).
    /// 3. Else if a focus is active → clear focus.
    /// The graph view, layout, camera and all data remain untouched.
    private func handleEscape() {
        if searchFieldFocused {
            searchFieldFocused = false
            if !viewModel.searchQuery.isEmpty {
                viewModel.clearSearch()
            }
            return
        }
        if viewModel.selectedNodeID != nil {
            viewModel.selectNode(nil)
            return
        }
        if viewModel.contextFocusID != nil {
            viewModel.clearContextFocus()
            return
        }
    }

    // MARK: - Search surface

    private var searchSurface: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .csForeground(CSColor.textSecondary)
                    .accessibilityHidden(true)
                TextField("Find in context…", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFieldFocused)
                    .onSubmit { viewModel.submitSearch() }
                    .accessibilityLabel("Search graph nodes")
                if viewModel.isSearching {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Searching graph")
                }
                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.clearSearch()
                        searchFieldFocused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .csForeground(CSColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear graph search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(width: 320)
            .lgChrome(cornerRadius: Theme.cornerRegular, interactive: true)
            if let e = viewModel.searchError {
                Text(e)
                    .font(.caption)
                    .csForeground(CSColor.error)
                    .padding(10)
                    .background(Color.cs(CSColor.surface), in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                            .strokeBorder(Color.cs(CSColor.border), lineWidth: 0.5)
                    )
                    .frame(width: 320, alignment: .leading)
            }
            if !viewModel.searchQuery.isEmpty && !viewModel.isSearching && !viewModel.searchResults.isEmpty {
                searchResultsList
            }
        }
    }

    private var searchResultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(viewModel.searchResults) { node in
                    Button { viewModel.focusSearchResult(node) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: node.nodeType.symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .csForeground(CSColor.textSecondary)
                                .frame(width: 16)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(node.title)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                    .csForeground(CSColor.textPrimary)
                                HStack(spacing: 6) {
                                    Text(node.nodeType.title)
                                        .font(.caption2.weight(.medium))
                                        .csForeground(CSColor.textSecondary)
                                    if let ws = viewModel.workspaceName(for: node) {
                                        Text("· \(ws)")
                                            .font(.caption2)
                                            .csForeground(CSColor.textTertiary)
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
                }
            }
            .padding(6)
        }
        .frame(width: 320)
        .frame(maxHeight: 320)
        .lgChrome(cornerRadius: Theme.cornerRegular)
        .accessibilityLabel("Graph search results")
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 4) {
            glassControlButton("minus", help: "Zoom out") { zoom(by: 0.8) }
            glassControlButton("plus", help: "Zoom in") { zoom(by: 1.25) }
            Divider().frame(height: 16)
            glassControlButton("arrow.counterclockwise", help: "Reset view") {
                needsFit = true
                viewModel.resetLayout()
            }
            glassControlButton("arrow.clockwise", help: "Refresh graph") { viewModel.refresh() }
            Divider().frame(height: 16)
            if viewModel.contextFocusID != nil {
                glassControlButton("scope", help: "Clear focus — show full field") {
                    viewModel.clearContextFocus()
                }
            } else if let sel = viewModel.selectedNodeID {
                glassControlButton("scope", help: "Focus on selection") {
                    viewModel.setContextFocus(sel)
                }
            }
            Menu {
                Picker("Relationship density", selection: $viewModel.edgeDensity) {
                    ForEach(GraphViewModel.EdgeDensity.allCases) { d in Text(d.title).tag(d) }
                }
#if DEBUG
                Divider()
                Button("Load demo fixture") { viewModel.loadFixture() }
                Button("Clear demo") { viewModel.refresh() }
                if viewModel.isUsingFixture {
                    Text("Using demo data").font(.caption2).csForeground(CSColor.textTertiary)
                }
#endif
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Density & demo")
            .accessibilityLabel("Graph options")
            glassControlButton(viewModel.showInspector ? "sidebar.right.fill" : "sidebar.right",
                               help: viewModel.showInspector ? "Hide inspector" : "Show inspector") {
                viewModel.showInspector.toggle()
            }
        }
        .padding(6)
        .lgChrome(cornerRadius: Theme.cornerRegular)
    }

    private func glassControlButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(Color.cs(CSColor.textSecondary))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            statusPill
        }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Text("\(viewModel.nodes.count) nodes · \(viewModel.visibleEdges.count) relationships")
                .font(.caption)
                .csForeground(CSColor.textSecondary)
            if viewModel.isTruncated {
                Text("· showing first \(viewModel.nodes.count) of \(viewModel.totalNodeCount)")
                    .font(.caption2)
                    .csForeground(CSColor.warning)
            }
            if viewModel.contextFocusID != nil {
                Text("· focused")
                    .font(.caption2)
                    .csForeground(CSColor.warning)
            }
            if camera.semanticLevel == .overview {
                Text("· overview")
                    .font(.caption2)
                    .csForeground(CSColor.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .lgChrome(cornerRadius: 999)
        .accessibilityLabel("\(viewModel.nodes.count) nodes, \(viewModel.visibleEdges.count) relationships")
    }

    private var workspacePicker: some View {
        Picker("Graph context", selection: Binding(get: { viewModel.selectedWorkspaceId },
                                                    set: { viewModel.selectWorkspace($0) })) {
            Text("All workspaces").tag(String?.none)
            ForEach(viewModel.workspaces) { ws in Text(ws.name).tag(Optional(ws.id)) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel("Graph context workspace")
    }

    private var expandingBadge: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Expanding…")
                .font(.callout)
                .csForeground(CSColor.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .lgChrome(cornerRadius: 999)
    }

    // MARK: - State overlay

    @ViewBuilder private var stateOverlay: some View {
        switch viewModel.state {
        case .idle, .loading:
            LoadingView(label: "Loading context field…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.cs(CSColor.surface).opacity(0.35))
        case .failed(let m):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32, weight: .light))
                    .csForeground(CSColor.warning)
                Text("Graph unavailable").font(.title3.weight(.semibold))
                    .csForeground(CSColor.textPrimary)
                Text(humanGraphError(m))
                    .font(.callout)
                    .csForeground(CSColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                if humanGraphError(m) != m {
                    Text(m)
                        .font(.caption)
                        .csForeground(CSColor.textTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .textSelection(.enabled)
                }
                HStack(spacing: 10) {
                    Button("Retry") { viewModel.retry() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityLabel("Retry loading graph")
                    Button("Refresh") { viewModel.refresh() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
#if DEBUG
                    Button("Load Demo") { viewModel.loadFixture() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
#endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.cs(CSColor.surface).opacity(0.45))
        case .loaded:
            if viewModel.nodes.isEmpty {
                EmptyStateView(
                    title: "No graph data yet",
                    message: "ContextSphere builds the graph from your workspaces and files. Add a workspace and open files; the knowledge graph syncs automatically.",
                    symbol: "point.3.connected.trianglepath.dotted",
                    primaryAction: ("Retry", { viewModel.retry() })
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.cs(CSColor.surface).opacity(0.30))
            } else if let hint = viewModel.lastError {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .csForeground(CSColor.textSecondary)
                        Text(hint)
                            .font(.caption)
                            .csForeground(CSColor.textSecondary)
                            .lineLimit(2)
                        Button("Dismiss") { viewModel.clearTransientError() }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Color.cs(CSColor.surfaceChrome).opacity(0.92),
                        in: Capsule()
                    )
                    .padding(.bottom, 64)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    private func humanGraphError(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("graph node with id") && lower.contains("was not found") {
            return "That item is no longer available. It may have been deleted or not yet synced. Retry to reload the current graph."
        }
        if lower.contains("not found") { return "Some graph data could not be found. The rest of the graph is shown. Retry to refresh." }
        if lower.contains("timed out") { return "The graph request timed out. Try Retry." }
        if lower.contains("core daemon is not running") { return "Connection unavailable. Use Retry to reconnect." }
        return raw
    }
}
