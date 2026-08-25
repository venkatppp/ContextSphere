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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                searchField
                if let notice = viewModel.notice {
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .accessibilityLabel(notice)
                }
                content
            }
            .frame(maxWidth: Theme.contentMaxWidth)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .safeAreaInset(edge: .top, spacing: 8) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
            Button("") { searchFieldFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
            Button("") { copySelectedResult() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(viewModel.selectedResult == nil)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    // MARK: - Header

    private var header: some View {
        ScreenHeader("Search",
                     subtitle: "Find anything across your workspaces and files.",
                     symbol: "magnifyingglass") {
            if !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    Task { await viewModel.saveCurrentQuery() }
                } label: {
                    Label("Save Search", systemImage: "bookmark")
                }
                .buttonStyle(.glass)
                .tint(.indigo)
                .help("Bookmark this query with the backend")
                .accessibilityLabel("Save current search")
            }
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search your context…", text: $viewModel.query)
                .textFieldStyle(.plain)
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
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            initialContent
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Searching your context…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
            .accessibilityElement(children: .combine)
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
        VStack(alignment: .leading, spacing: 24) {
            recentSearchesSection
            savedSearchesSection
            if viewModel.history.isEmpty && viewModel.savedSearches.isEmpty {
                greeting
            }
        }
    }

    private var recentSearchesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionHeader(title: "Recent", symbol: "clock.arrow.circlepath")
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)],
                          alignment: .leading, spacing: 8) {
                    ForEach(viewModel.history, id: \.self) { item in
                        Button {
                            viewModel.runQuery(item)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "clock")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text(item)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.regularMaterial,
                                        in: Capsule())
                            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .help("Run search: \(item)")
                        .accessibilityLabel("Run recent search: \(item)")
                    }
                }
            } else {
                Text("No recent searches — your history appears here after you search.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var savedSearchesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !viewModel.savedSearches.isEmpty {
                SectionHeader(title: "Saved", symbol: "bookmark")
            }
            if viewModel.savedSearches.isEmpty {
                Text("Save a search with the bookmark button to reuse it quickly.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.savedSearches) { saved in
                HStack(spacing: 10) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Button {
                        viewModel.runQuery(saved.query)
                    } label: {
                        Text(saved.query)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .help("Run saved search: \(saved.query)")
                    .accessibilityLabel("Run saved search: \(saved.query)")
                    Spacer()
                    Text(saved.createdAt.relativeTime)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Saved \(saved.createdAt.relativeTime)")
                    Button {
                        Task { await viewModel.deleteSavedSearch(saved.id) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete saved search")
                    .accessibilityLabel("Delete saved search: \(saved.query)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5))
            }
        }
    }

    private var greeting: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("Search your context")
                .font(.title3.weight(.semibold))
            Text("Find workspaces and files across everything ContextSphere is watching. Recent searches and saved queries appear here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Result states

    private var noResultsState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("No matching context")
                .font(.title3.weight(.semibold))
            Text("Nothing matched “\(viewModel.query)”. Try different keywords.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityElement(children: .combine)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("Search unavailable")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Retry") {
                viewModel.retry()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Retry search")
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }

    // MARK: - Results

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Results",
                subtitle: "\(viewModel.results.count)",
                symbol: "magnifyingglass"
            )
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(viewModel.results) { result in
                    SearchResultRow(
                        result: result,
                        workspaceName: viewModel.workspaceName(for: result),
                        isSelected: viewModel.selectedResultID == result.id,
                        action: { activate(result) })
                    .focusable()
                    .focused($focusedRowID, equals: result.id)
                    .onChange(of: focusedRowID) { _, newID in
                        viewModel.selectedResultID = newID
                    }
                }
            }
        }
    }

    /// Select the result; workspace results also navigate to the
    /// Workspaces section (the existing app navigation).
    private func activate(_ result: SearchResult) {
        viewModel.selectedResultID = result.id
        if result.entityType == .workspace {
            onRevealWorkspace(result.workspaceId)
        }
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
    let action: () -> Void

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
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let workspaceName {
                        workspaceCaption(workspaceName)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected
                                  ? AnyShapeStyle(Color.accentColor.opacity(0.5))
                                  : AnyShapeStyle(.quaternary),
                                  lineWidth: isSelected ? 1 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
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
                           : "Selects the result; press Command-C to copy")
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(result.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Spacer()
            Text(result.entityType.title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.quaternary.opacity(0.6)))
        }
    }

    private func workspaceCaption(_ name: String) -> some View {
        Label(name, systemImage: "folder")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("In workspace \(name)")
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.regularMaterial)
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
        case .workspace: .indigo
        case .file: .teal
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