import SwiftUI

/// Native Canvas-based Context Field (prompt §6) — the living visual
/// representation of computer context.
///
/// Architecture: GraphVisualizationModel → GraphLayoutEngine → GraphRenderState
/// → GraphRenderer (Canvas) → GraphCamera → SwiftUI surface.
/// Each layer is separate; this file owns only the SwiftUI surface.
struct GraphScreen: View {
    @ObservedObject var viewModel: GraphViewModel
    @StateObject private var camera = GraphCamera()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var hoveredNodeID: String?
    @State private var canvasSize: CGSize = .zero
    @State private var panAnchor: CGPoint?
    @State private var magnifyBaseZoom: CGFloat?
    @State private var needsFit = true

    private let renderer = CanvasGraphRenderer()

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
                debugFooter
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(16)
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? .none : .spring(response: 0.45, dampingFraction: 0.85), value: viewModel.positions)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.25), value: viewModel.showInspector)
        .task { viewModel.initialLoadIfNeeded() }
        .onAppear { camera.setViewport(canvasSize) }
        .onChange(of: viewModel.layoutGeneration) { _, _ in needsFit = true }
        .onChange(of: canvasSize) { _, newSize in
            camera.setViewport(newSize)
            if needsFit, newSize.width > 0 { applyFit() }
        }
        .onChange(of: viewModel.focusNonce) { _, _ in focusOnRequestedNode() }
        .onChange(of: viewModel.contextFocusID) { _, _ in
            if viewModel.contextFocusID == nil { needsFit = true }
        }
    }

    private func canvasArea(_ size: CGSize) -> some View {
        Canvas { context, cSize in
            guard viewModel.state == .loaded, !viewModel.positions.isEmpty else { return }
            let model = viewModel.visualizationModel
            let density: GraphEdgeDensity = viewModel.edgeDensity == .all ? .all : .strong
            let state = GraphRenderStateBuilder.build(
                model: model,
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
        .background(Color.clear)
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
            // Screen-space slop so tiny far-apart nodes stay grabbable.
            let hr = max(node.nodeType.nodeRadius / camera.zoom, 6) + 6
            let dx = p.x - world.x, dy = p.y - world.y
            let d = sqrt(dx*dx + dy*dy)
            if d <= hr, best == nil || d < best!.d { best = (id, d) }
        }
        return best?.id
    }

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

    private var searchSurface: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Find in context…", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit { viewModel.submitSearch() }
                    .accessibilityLabel("Search graph nodes")
                if viewModel.isSearching { ProgressView().controlSize(.small).accessibilityLabel("Searching graph") }
                if !viewModel.searchQuery.isEmpty {
                    Button { viewModel.clearSearch() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear graph search")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(width: 300)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous))
            if let e = viewModel.searchError {
                Text(e).font(.caption).foregroundStyle(.red).padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                    .frame(width: 300, alignment: .leading)
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
                    Button { viewModel.focusSearchResult(node) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: node.nodeType.symbol).font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(node.nodeType.color).frame(width: 16).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(node.title).font(.callout.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
                                HStack(spacing: 6) {
                                    Text(node.nodeType.title).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                    if let ws = viewModel.workspaceName(for: node) {
                                        Text(ws).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                    }
                                }
                            }
                            Spacer(minLength: 4)
                        }.padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(6)
        }
        .frame(width: 300).frame(maxHeight: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .accessibilityLabel("Graph search results")
    }

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
                    Text("Using demo data").font(.caption2).foregroundStyle(.tertiary)
                }
#endif
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle").frame(width: 26, height: 26)
            }.menuStyle(.borderlessButton).fixedSize().help("Density & demo").accessibilityLabel("Graph options")
            glassControlButton(viewModel.showInspector ? "sidebar.right.fill" : "sidebar.right",
                               help: viewModel.showInspector ? "Hide inspector" : "Show inspector") {
                viewModel.showInspector.toggle()
            }
        }
        .padding(6)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous))
    }

    private func glassControlButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 26, height: 26)
        }.buttonStyle(.plain).contentShape(Rectangle()).help(help).accessibilityLabel(help)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("\(viewModel.nodes.count) nodes · \(viewModel.visibleEdges.count) relationships")
                    .font(.caption).foregroundStyle(.secondary)
                if viewModel.isTruncated {
                    Text("· showing first \(viewModel.nodes.count) of \(viewModel.totalNodeCount)")
                        .font(.caption2).foregroundStyle(.orange)
                }
                if viewModel.contextFocusID != nil { Text("· focused").font(.caption2).foregroundStyle(.orange) }
                if camera.semanticLevel == .overview { Text("· overview").font(.caption2).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .accessibilityLabel("\(viewModel.nodes.count) nodes, \(viewModel.visibleEdges.count) relationships")
            workspacePicker
        }
    }

    private var workspacePicker: some View {
        Picker("Graph context", selection: Binding(get: { viewModel.selectedWorkspaceId },
                                                    set: { viewModel.selectWorkspace($0) })) {
            Text("All workspaces").tag(String?.none)
            ForEach(viewModel.workspaces) { ws in Text(ws.name).tag(Optional(ws.id)) }
        }
        .pickerStyle(.menu).fixedSize()
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .accessibilityLabel("Graph context workspace")
    }

    private var expandingBadge: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Expanding…").font(.callout).foregroundStyle(.secondary)
        }.padding(.horizontal, 14).padding(.vertical, 8).glassEffect(.regular, in: Capsule())
    }

    private var debugFooter: some View {
        HStack(spacing: 8) {
            Text(String(format: "layout %.1f ms", viewModel.lastLayoutDurationMs))
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            Text("· zoom \(String(format: "%.2f", camera.zoom)) · \(camera.semanticLevel.rawValue)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.regularMaterial.opacity(0.7), in: Capsule())
        .opacity(viewModel.nodes.isEmpty ? 0 : 1)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var stateOverlay: some View {
        switch viewModel.state {
        case .idle, .loading:
            LoadingView(label: "Loading context field…")
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.background.opacity(0.35))
        case .failed(let m):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 32)).foregroundStyle(.orange)
                Text("Graph unavailable").font(.title3.weight(.semibold))
                Text(m).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                HStack(spacing: 10) {
                    Button("Retry") { viewModel.retry() }.buttonStyle(.borderedProminent).controlSize(.small)
#if DEBUG
                    Button("Load Demo") { viewModel.loadFixture() }.buttonStyle(.bordered).controlSize(.small)
#endif
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.background.opacity(0.45))
        case .loaded:
            if viewModel.nodes.isEmpty {
#if DEBUG
                EmptyStateView(title: "No graph data yet",
                               message: "ContextSphere builds the graph from your workspaces and files. Use the demo fixture to explore the Context Field.",
                               symbol: "point.3.connected.trianglepath.dotted")
                    .background(.background.opacity(0.3))
#else
                EmptyStateView(title: "No graph data yet",
                               message: "ContextSphere builds the graph from your workspaces and files. Add a workspace and files to see the context field’s relationships unfold.",
                               symbol: "point.3.connected.trianglepath.dotted")
                    .background(.background.opacity(0.3))
#endif
            }
        }
    }
}
