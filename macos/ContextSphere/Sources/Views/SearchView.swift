import SwiftUI
import AppKit

/// Spotlight-style search across ContextSphere context (workspaces and
/// files), backed by the Rust search engine over JSON-RPC.
///
/// Hierarchy: background → glass search surface → results (material
/// content layer) → secondary metadata. Keyboard-first: Return submits,
/// Escape clears, arrows move through results, Return/click activates,
/// Cmd+C copies the selected result, Cmd+F refocuses the field.
struct SearchView: View {
    @ObservedObject var viewModel: SearchViewModel
    /// Switches the app to the Workspaces section (existing navigation).
    let onRevealWorkspace: (String) -> Void

    @FocusState private var searchFieldFocused: Bool
    @FocusState private var focusedRowID: String?
    @State private var containerWidth: CGFloat = 1024

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Theme.horizontalPadding(for: containerWidth))
                .padding(.vertical, Theme.pageHeaderVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            Hairline(opacity: Theme.pageHeaderDividerOpacity)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    searchField
                    if let notice = viewModel.notice {
                        Text(notice)
                            .font(.callout)
                            .csForeground(CSColor.textSecondary)
                            .padding(.horizontal, 4)
                            .accessibilityLabel(notice)
                    }
                    content
                }
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
        .task { await viewModel.loadInitialData() }
        .onChange(of: viewModel.state) { _, newState in
            if newState == .loaded {
                focusedRowID = viewModel.results.first?.id
                searchFieldFocused = false
            }
        }
        .background {
            Button("") { handleEscape() }
                .keyboardShortcut(.escape)
                .hidden()
                .accessibilityHidden(true)
            Button("") { moveSelection(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .hidden()
                .accessibilityHidden(true)
            Button("") { moveSelection(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .hidden()
                .accessibilityHidden(true)
            Button("") { activateSelected() }
                .keyboardShortcut(.defaultAction)
                .hidden()
                .accessibilityHidden(true)
            Button("") { searchFieldFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
            Button("") { if !searchFieldFocused { copySelectedResult() } }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(searchFieldFocused || viewModel.selectedResult == nil)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    // MARK: - Header

    private var header: some View {
        StandardPageHeader(
            section: .search,
            title: "Search",
            subtitle: "Find anything across your workspaces and files.",
            symbol: AppSection.search.symbol,
            eyebrow: NavGroup.intelligence.title.uppercased()
        ) {
            if !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    Task { await viewModel.saveCurrentQuery() }
                } label: {
                    Label("Save Search", systemImage: "bookmark")
                }
                .buttonStyle(.glass)
                .tint(Color.cs(CSColor.info))
                .help("Bookmark this query with the backend")
                .accessibilityLabel("Save current search")
            }
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .csForeground(CSColor.textSecondary)
                .accessibilityHidden(true)
            TextField("Search your context…", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFieldFocused)
                .defaultFocus($searchFieldFocused, true)
                .onSubmit { viewModel.submit() }
                .accessibilityLabel("Search your context")
            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Searching")
            }
            if !viewModel.query.isEmpty {
                Button {
                    viewModel.clearQuery()
                    searchFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .csForeground(CSColor.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            initialContent
        case .loading:
            LoadingView(label: "Searching your context…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
        case .loaded:
            if viewModel.results.isEmpty {
                noResultsState
            } else {
                resultsList
            }
        case .failed(let message):
            errorState(message)
        }
    }

    // MARK: - Initial state

    private var initialContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            recentSearchesSection
            savedSearchesSection
            if viewModel.history.isEmpty && viewModel.savedSearches.isEmpty {
                EmptyStateView(
                    title: "Search your context",
                    message: "Find workspaces and files across everything ContextSphere is watching. Recent searches and saved queries appear here.",
                    symbol: "magnifyingglass"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
        }
    }

    private var recentSearchesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .csForeground(CSColor.textSecondary)
                Text("Recent")
                    .font(.csEyebrow())
                    .csForeground(CSColor.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer()
                if !viewModel.history.isEmpty {
                    Button("Clear") {
                        Task { await viewModel.clearHistory() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Clear search history on the backend")
                    .accessibilityLabel("Clear search history")
                }
            }
            if !viewModel.history.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)],
                          alignment: .leading, spacing: 8) {
                    ForEach(viewModel.history, id: \.self) { item in
                        recentChip(item)
                    }
                }
            } else if let historyError = viewModel.historyError {
                Label("History unavailable: \(historyError)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .csForeground(CSColor.warning)
            } else {
                Text("No recent searches — your history appears here after you search.")
                    .font(.callout)
                    .csForeground(CSColor.textSecondary)
            }
        }
    }

    private func recentChip(_ item: String) -> some View {
        Button {
            viewModel.runQuery(item)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.caption2.weight(.medium))
                    .csForeground(CSColor.textSecondary)
                    .accessibilityHidden(true)
                Text(item)
                    .font(.callout)
                    .lineLimit(1)
                    .csForeground(CSColor.textPrimary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.cs(CSColor.surfaceElevated), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.cs(CSColor.separator), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Run search: \(item)")
        .accessibilityLabel("Run recent search: \(item)")
    }

    private var savedSearchesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !viewModel.savedSearches.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 11, weight: .semibold))
                        .csForeground(CSColor.textSecondary)
                    Text("Saved")
                        .font(.csEyebrow())
                        .csForeground(CSColor.textSecondary)
                        .textCase(.uppercase)
                        .tracking(0.6)
                }
            }
            if viewModel.savedSearches.isEmpty, let savedError = viewModel.savedError {
                Label("Saved searches unavailable: \(savedError)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .csForeground(CSColor.warning)
            } else if viewModel.savedSearches.isEmpty {
                Text("Save a search with the bookmark button to reuse it quickly.")
                    .font(.callout)
                    .csForeground(CSColor.textSecondary)
            }
            ForEach(viewModel.savedSearches) { saved in
                savedRow(saved)
            }
        }
    }

    private func savedRow(_ saved: SavedSearch) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Button {
                viewModel.runQuery(saved.query)
            } label: {
                Text(saved.query)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .csForeground(CSColor.textPrimary)
            }
            .buttonStyle(.plain)
            .help("Run saved search: \(saved.query)")
            .accessibilityLabel("Run saved search: \(saved.query)")
            Spacer()
            Text(saved.createdAt.relativeTime)
                .font(.caption2)
                .csForeground(CSColor.textTertiary)
                .accessibilityLabel("Saved \(saved.createdAt.relativeTime)")
            Button {
                Task { await viewModel.deleteSavedSearch(saved.id) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .csForeground(CSColor.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Delete saved search")
            .accessibilityLabel("Delete saved search: \(saved.query)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.cs(CSColor.surface), in: RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous)
                .strokeBorder(Color.cs(CSColor.separator), lineWidth: 0.5)
        )
    }

    // MARK: - Result states

    private var noResultsState: some View {
        EmptyStateView(
            title: "No matching context",
            message: "Nothing matched “\(viewModel.query)”. Try different keywords.",
            symbol: "magnifyingglass"
        )
    }

    private func errorState(_ message: String) -> some View {
        EmptyStateView(
            title: "Search unavailable",
            message: message,
            symbol: "exclamationmark.triangle",
            primaryAction: ("Retry", { viewModel.retry() })
        )
    }

    // MARK: - Results

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .csForeground(CSColor.textSecondary)
                Text("Results")
                    .font(.csEyebrow())
                    .csForeground(CSColor.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Text("· \(viewModel.results.count)")
                    .font(.caption)
                    .csForeground(CSColor.textTertiary)
                Spacer()
            }
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(viewModel.results) { result in
                    SearchResultRow(
                        result: result,
                        workspaceName: viewModel.workspaceName(for: result),
                        isSelected: viewModel.selectedResultID == result.id,
                        filePath: viewModel.filePath(for: result),
                        action: { activate(result) },
                        onOpenFile: {
                            viewModel.selectedResultID = result.id
                            Task { await viewModel.openFile(result) }
                        },
                        onRevealInFinder: {
                            viewModel.selectedResultID = result.id
                            viewModel.revealInFinder(result)
                        })
                    .focusable()
                    .focused($focusedRowID, equals: result.id)
                    .onChange(of: focusedRowID) { _, newID in
                        if let newID { viewModel.selectedResultID = newID }
                    }
                }
            }
        }
    }

    /// Select the result and act on it: workspaces switch the daemon's
    /// active workspace before revealing it in the Workspaces section;
    /// file hits open directly (native first, core fallback second).
    private func activate(_ result: SearchResult) {
        viewModel.selectedResultID = result.id
        if result.entityType == .workspace {
            let workspaceId = result.workspaceId
            Task {
                if await viewModel.switchToWorkspace(workspaceId) {
                    onRevealWorkspace(workspaceId)
                }
            }
            return
        }
        guard viewModel.filePath(for: result) != nil else { return }
        Task { await viewModel.openFile(result) }
    }

    /// Arrow-key navigation over the visible results.
    private func moveSelection(by direction: Int) {
        guard !viewModel.results.isEmpty else { return }
        let ids = viewModel.results.map(\.id)
        let current = focusedRowID ?? viewModel.selectedResultID
        guard let current, let index = ids.firstIndex(of: current) else {
            applySelection(ids[0])
            return
        }
        applySelection(ids[max(0, min(ids.count - 1, index + direction))])
    }

    private func applySelection(_ id: String) {
        viewModel.selectedResultID = id
        focusedRowID = id
    }

    /// Return on a selected result activates it (workspace switch or
    /// file open). No-ops while the query field has focus so Return
    /// keeps submitting the search there.
    private func activateSelected() {
        guard !searchFieldFocused, let result = viewModel.selectedResult else { return }
        activate(result)
    }

    // MARK: - Keyboard actions

    private func handleEscape() {
        if viewModel.selectedResultID != nil {
            viewModel.selectedResultID = nil
            searchFieldFocused = true
        } else if !viewModel.query.isEmpty {
            viewModel.clearQuery()
            searchFieldFocused = true
        }
    }

    private func copySelectedResult() {
        guard let result = viewModel.selectedResult else { return }
        copyToPasteboard(result.copyDetails(
            workspaceName: viewModel.workspaceName(for: result)))
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// One search hit: type marker, title, highlighted snippet, workspace.
struct SearchResultRow: View {
    let result: SearchResult
    let workspaceName: String?
    let isSelected: Bool
    let filePath: String?
    let action: () -> Void
    var onOpenFile: (() -> Void)? = nil
    var onRevealInFinder: (() -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: result.entityType.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(result.entityType.color)
                    .frame(width: 22)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    titleLine
                    result.snippetText
                        .font(.callout)
                        .csForeground(CSColor.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let workspaceName {
                        workspaceCaption(workspaceName)
                    }
                    if let filePath {
                        Text(filePath)
                            .font(.caption2.monospaced())
                            .csForeground(CSColor.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(filePath)
                    }
                }
                Spacer(minLength: 8)
                if filePath != nil {
                    HStack(spacing: 4) {
                        rowActionButton("arrow.up.forward.app", "Open") { onOpenFile?() }
                        rowActionButton("folder", "Reveal in Finder") { onRevealInFinder?() }
                    }
                    .opacity(isHovered || isSelected ? 1 : 0)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .overlay(rowOverlay)
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            if filePath != nil {
                Button("Open") { onOpenFile?() }
                Button("Reveal in Finder") { onRevealInFinder?() }
                Divider()
                Button("Copy Path") {
                    copyToPasteboard(filePath ?? "")
                }
                Divider()
            }
            Button("Copy Name") {
                copyToPasteboard(result.title)
            }
            Button("Copy Details") {
                copyToPasteboard(result.copyDetails(workspaceName: workspaceName))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(result.entityType == .workspace
                           ? "Opens the Workspaces section"
                           : filePath != nil
                             ? "Opens the file; press Return to open, Control-click for more actions"
                             : "Selects the result; press Command-C to copy")
    }

    private func rowActionButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 26)
                .background(Color.cs(CSColor.borderSubtle), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel("\(label) \(result.title)")
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(result.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Text(result.entityType.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(result.entityType.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(result.entityType.color.opacity(0.12), in: Capsule())
        }
    }

    private func workspaceCaption(_ name: String) -> some View {
        Label(name, systemImage: "folder")
            .font(.caption2)
            .csForeground(CSColor.textTertiary)
            .accessibilityLabel("In workspace \(name)")
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous)
            .fill(rowFill)
    }

    private var rowFill: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.accentColor.opacity(0.14)) }
        if isHovered { return AnyShapeStyle(Color.cs(CSColor.surface)) }
        return AnyShapeStyle(Color.clear)
    }

    private var rowOverlay: some View {
        RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous)
            .strokeBorder(
                isSelected ? Color.accentColor.opacity(0.5)
                : (isHovered ? Color.cs(CSColor.border) : .clear),
                lineWidth: 0.5
            )
    }

    private var accessibilityText: String {
        [
            result.title,
            result.entityType.title,
            workspaceName.map { "in workspace \($0)" },
            snippetPlainText,
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
    }

    private var snippetPlainText: String {
        result.snippet
            .replacingOccurrences(of: "<b>", with: "")
            .replacingOccurrences(of: "</b>", with: "")
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - Presentation

extension SearchEntityType {
    var title: String {
        switch self {
        case .workspace: "Workspace"
        case .file: "File"
        }
    }

    var symbol: String {
        switch self {
        case .workspace: "folder.fill"
        case .file: "doc.text"
        }
    }

    var color: Color {
        switch self {
        case .workspace: Color.cs(CSColor.info)
        case .file: Color.cs(CSColor.graphFile)
        }
    }
}

extension SearchResult {
    /// Renders the FTS5 snippet, turning the backend's `<b>…</b>` match
    /// markers into a subtle emphasis.
    var snippetText: Text {
        var text = Text("")
        var bold = false
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            text = Text("\(text)\(Text(buffer).fontWeight(bold ? .medium : .regular))")
            buffer = ""
        }
        var index = snippet.startIndex
        while index < snippet.endIndex {
            if snippet[index...].hasPrefix("<b>") {
                flush()
                bold = true
                index = snippet.index(index, offsetBy: 3)
            } else if snippet[index...].hasPrefix("</b>") {
                flush()
                bold = false
                index = snippet.index(index, offsetBy: 4)
            } else {
                buffer.append(snippet[index])
                index = snippet.index(after: index)
            }
        }
        flush()
        return text
    }

    /// Multi-line clipboard summary for ⌘C / Copy Details.
    func copyDetails(workspaceName: String?) -> String {
        [
            "Type: \(entityType.title)",
            "Title: \(title)",
            workspaceName.map { "Workspace: \($0)" },
            snippet.isEmpty ? nil : "Context: \(snippetPlainText)",
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }

    private var snippetPlainText: String {
        snippet
            .replacingOccurrences(of: "<b>", with: "")
            .replacingOccurrences(of: "</b>", with: "")
    }
}