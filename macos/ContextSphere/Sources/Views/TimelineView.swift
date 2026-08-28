import SwiftUI
import AppKit

/// Chronological activity feed for a workspace, backed by the Rust
/// timeline engine. Newest first, grouped by day, filtered by workspace
/// and event type, with live updates from `timeline:event_added`.
struct TimelineView: View {
    @ObservedObject var viewModel: TimelineViewModel
    @FocusState private var focusedEventID: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
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
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.cornerXLarge, style: .continuous))
            }
        }
        .task { await viewModel.initialLoadIfNeeded() }
        .background {
            Button("") { moveFocus(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .hidden()
                .accessibilityHidden(true)
            Button("") { moveFocus(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .hidden()
                .accessibilityHidden(true)
            Button("") { activateFocusedRow() }
                .keyboardShortcut(.return, modifiers: [])
                .hidden()
                .accessibilityHidden(true)
            Button("") { focusedEventID = nil }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
                .accessibilityHidden(true)
        }
    }

    /// Moves row focus by one entry in the flattened visible feed.
    private func moveFocus(by direction: Int) {
        let flat = viewModel.groups.flatMap(\.events)
        guard !flat.isEmpty else { return }
        guard let current = focusedEventID,
            let index = flat.firstIndex(where: { $0.id == current }) else {
            focusedEventID = flat[0].id
            return
        }
        let next = max(0, min(flat.count - 1, index + direction))
        focusedEventID = flat[next].id
    }

    /// Return on a focused row acts like clicking a file-backed event.
    private func activateFocusedRow() {
        guard let id = focusedEventID,
            let event = viewModel.groups.flatMap(\.events).first(where: { $0.id == id }),
            let path = primaryPath(of: event) else { return }
        openFile(at: path)
    }

    private func primaryPath(of event: TimelineEvent) -> String? {
        event.metadata?.string("path")
            ?? event.metadata?.string("to")
            ?? event.metadata?.string("from")
    }

    // MARK: - Header

    private var header: some View {
        ScreenHeader("Timeline",
                     subtitle: subtitle,
                     symbol: "clock",
                     eyebrow: "Workspace") {
            HStack(spacing: 8) {
                workspacePicker
                typePicker
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    if viewModel.isFetching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.borderless)
                .help("Refresh timeline")
                .accessibilityLabel("Refresh timeline")
            }
        }
    }

    private var subtitle: String {
        var parts = ["Context: \(viewModel.selectedWorkspace?.name ?? "No workspace")"]
        if !viewModel.events.isEmpty {
            parts.append("\(viewModel.displayedEventCount) events")
        }
        return parts.joined(separator: " · ")
    }

    private var workspacePicker: some View {
        Picker("Workspace", selection: Binding(
            get: { viewModel.selectedWorkspaceId },
            set: { viewModel.selectWorkspace($0) }
        )) {
            ForEach(viewModel.workspaces) { workspace in
                Text(workspace.name).tag(Optional(workspace.id))
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel("Filter timeline by workspace")
    }

    private var typePicker: some View {
        Picker("Event type", selection: Binding(
            get: { viewModel.selectedType },
            set: { viewModel.selectType($0) }
        )) {
            Text("All types").tag(TimelineEventType?.none)
            ForEach(TimelineEventType.allCases, id: \.self) { type in
                Label(type.title, systemImage: type.symbol).tag(Optional(type))
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel("Filter timeline by event type")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            LoadingView(label: "Loading timeline…")
        case .failed(let message):
            if viewModel.events.isEmpty {
                errorState(message)
            } else {
                eventList
            }
        case .loaded:
            if viewModel.workspaces.isEmpty {
                emptyState(
                    title: "No workspaces yet",
                    message: "Create a workspace from the Workspaces section and ContextSphere will record its activity here.",
                    symbol: "folder.badge.plus")
            } else if viewModel.events.isEmpty {
                emptyState(
                    title: "No activity recorded",
                    message: "File changes in \(viewModel.selectedWorkspace?.name ?? "this workspace") will appear here automatically.",
                    symbol: "clock.badge.questionmark",
                    actionTitle: "Refresh",
                    action: { Task { await viewModel.refresh() } })
            } else if viewModel.groups.isEmpty {
                emptyState(
                    title: "No \(viewModel.selectedType?.title.lowercased() ?? "matching") activity",
                    message: "There are no \(viewModel.selectedType?.title.lowercased() ?? "") events in this workspace yet.",
                    symbol: "line.3.horizontal.decrease.circle",
                    actionTitle: "Show all types",
                    action: { viewModel.selectType(nil) })
            } else {
                eventList
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        EmptyStateView(
            title: "Timeline unavailable",
            message: message,
            symbol: "exclamationmark.triangle",
            primaryAction: ("Retry", { Task { await viewModel.refresh() } })
        )
    }

    private func emptyState(title: String, message: String, symbol: String,
                            actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        EmptyStateView(
            title: title,
            message: message,
            symbol: symbol,
            primaryAction: actionTitle.map { (label: $0, perform: action ?? {}) }
        )
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 0) {
            sessionsStrip
            if let lastError = viewModel.lastError {
                StatusBanner(
                    message: "Refresh failed",
                    style: .warning,
                    detail: lastError,
                    primaryAction: ("Retry", { Task { await viewModel.refresh() } })
                )
                .padding(.bottom, 12)
            }

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.groups.enumerated()), id: \.element.id) { groupIndex, group in
                    groupHeader(group)
                    ForEach(Array(group.events.enumerated()), id: \.element.id) { eventIndex, event in
                        TimelineEventRow(
                            event: event,
                            workspaceName: viewModel.workspaceName(for: event),
                            isLast: groupIndex == viewModel.groups.count - 1
                                && eventIndex == group.events.count - 1,
                            isFocused: focusedEventID == event.id,
                            onOpen: { path in
                                openFile(at: path)
                            }
                        )
                        .focusable()
                        .focused($focusedEventID, equals: event.id)
                    }
                }
                if viewModel.hasMore {
                    HStack {
                        Spacer()
                        Button("Load more") {
                            Task { await viewModel.loadMore() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isFetching)
                        .accessibilityLabel("Load more timeline events")
                        Spacer()
                    }
                    .padding(.vertical, 14)
                }
            }
        }
    }

    /// Recent work sessions (core SessionEngine) as filter chips.
    @ViewBuilder
    private var sessionsStrip: some View {
        if !viewModel.sessions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Sessions")
                        .font(.csEyebrow())
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.6)
                    Spacer()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.sessions) { session in
                            sessionChip(session)
                        }
                    }
                    .padding(.vertical, 2)
                }
                if viewModel.selectedSessionID != nil {
                    Button("Show all activity") { viewModel.clearSessionSelection() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .accessibilityLabel("Clear session filter")
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func sessionChip(_ session: WorkspaceSession) -> some View {
        let isSelected = viewModel.selectedSessionID == session.id
        let start = session.startedAt.isoDate ?? .distantPast
        return Button {
            viewModel.selectSession(session.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(start.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Label(Self.durationText(session.durationSeconds), systemImage: "clock")
                    Text("· \(session.eventCount) events")
                    Text("· \(session.fileCount) files")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: 200, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.25),
                                  lineWidth: isSelected ? 1 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Filter the feed to this work session")
        .accessibilityLabel("Session \(start.formatted(date: .abbreviated, time: .shortened)), \(session.eventCount) events, \(session.fileCount) files")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private static func durationText(_ seconds: Int) -> String {
        seconds >= 3600 ? "\(seconds / 3600)h \(seconds % 3600 / 60)m" : "\(seconds / 60)m"
    }

    private func groupHeader(_ group: TimelineViewModel.DayGroup) -> some View {
        HStack(spacing: 10) {
            Text(group.label)
                .font(.csEyebrow())
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
            Text("· \(group.events.count) events")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Rectangle()
                .fill(.quaternary.opacity(0.5))
                .frame(height: 0.5)
        }
        .padding(.top, 18)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(group.label), \(group.events.count) events")
    }

    private func openFile(at path: String) {
        let url = URL(fileURLWithPath: path)
        // NSWorkspace is the native macOS way; fallback to the Rust
        // `open_file` RPC (which shells out to `open`) if the URL is not
        // directly openable (e.g. stale path).
        if NSWorkspace.shared.open(url) { return }
        Task { await viewModel.openViaCoreFallback(path) }
    }
}

// MARK: - Row

/// One timeline entry: type marker, human-readable description, artifact,
/// workspace, and timestamp. File-backed events are tappable and vend a
/// native macOS context menu (Open / Reveal / Copy).
struct TimelineEventRow: View {
    let event: TimelineEvent
    let workspaceName: String?
    let isLast: Bool
    var isFocused: Bool = false
    var onOpen: ((String) -> Void)? = nil
    @State private var isHovered = false

    private var primaryPath: String? {
        event.metadata?.string("path")
            ?? event.metadata?.string("to")
            ?? event.metadata?.string("from")
    }

    private var isFileEvent: Bool {
        primaryPath != nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Rail with a node for the event
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(event.eventType.color.opacity(0.18))
                        .frame(width: 22, height: 22)
                    Circle()
                        .fill(event.eventType.color)
                        .frame(width: 8, height: 8)
                }
                .padding(.top, 6)
                if !isLast {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 22)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                rowHeader
                if let artifact = event.artifactName {
                    Text(artifact)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let detail = event.displayDetail, detail != event.artifactName {
                    Text(detail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let workspaceName {
                    Text(workspaceName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .overlay(rowOverlay)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            guard let path = primaryPath else { return }
            onOpen?(path)
        }
        .contextMenu {
            if let path = primaryPath {
                Button {
                    onOpen?(path)
                } label: {
                    Label("Open", systemImage: "arrow.up.forward.app")
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                Divider()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(accessibilityText, forType: .string)
            } label: {
                Label("Copy Details", systemImage: "doc.text")
            }
        }
        .help(isFileEvent ? "Click to open · Right-click for more actions" : "Timeline event")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(isFileEvent ? "Double-click to open file, right-click for more actions" : "Timeline event")
        .accessibilityAddTraits(isFileEvent ? .isButton : [])
    }

    private var rowHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: event.eventType.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(event.eventType.color)
                .accessibilityHidden(true)
            Text(event.displayTitle)
                .font(.callout.weight(.medium))
            Spacer()
            Text(event.occurredAtDate.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            if isFileEvent {
                Image(systemName: "arrow.up.forward.app")
                    .font(.caption2)
                    .foregroundStyle(isHovered ? .secondary : .tertiary)
                    .accessibilityHidden(true)
            }
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous)
            .fill(rowBackgroundStyle)
    }

    private var rowBackgroundStyle: AnyShapeStyle {
        if isHovered || isFocused {
            return AnyShapeStyle(.regularMaterial)
        }
        return AnyShapeStyle(Color.clear)
    }

    private var rowOverlay: some View {
        RoundedRectangle(cornerRadius: Theme.cornerRegular, style: .continuous)
            .strokeBorder(rowBorderColor, lineWidth: 0.5)
    }

    private var rowBorderColor: Color {
        if isFocused { return Color.accentColor.opacity(0.5) }
        if isHovered { return Color.secondary.opacity(0.25) }
        return Color.clear
    }

    private var accessibilityText: String {
        [
            event.displayTitle,
            event.artifactName,
            workspaceName,
            event.occurredAtDate.formatted(date: .abbreviated, time: .shortened),
            event.displayDetail,
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

// MARK: - Presentation

extension TimelineEvent {
    var occurredAtDate: Date {
        occurredAt.isoDate ?? .distantPast
    }

    private var activity: String? {
        metadata?.string("activity") ?? metadata?.string("reason")
    }

    /// "File modified", "Workspace renamed", … — the leading line of a row.
    var displayTitle: String {
        switch eventType {
        case .create: "File created"
        case .edit: "File modified"
        case .delete: "File deleted"
        case .move: "File moved"
        case .workspaceSwitch:
            switch activity {
            case "workspace_created": "Workspace created"
            case "workspace_opened": "Workspace opened"
            case "workspace_renamed": "Workspace renamed"
            case "project_imported": "Project imported"
            default: "Workspace switched"
            }
        default: eventType.title
        }
    }

    /// The artifact involved: file name, "from → to" for moves/renames.
    var artifactName: String? {
        switch eventType {
        case .create, .edit, .delete:
            return metadata?.string("path").map(lastPathComponent)
        case .move:
            let from = metadata?.string("from").map(lastPathComponent)
            let to = metadata?.string("to").map(lastPathComponent)
            if let from, let to { return "\(from) → \(to)" }
            return to ?? from
        case .workspaceSwitch:
            if activity == "workspace_renamed" {
                let previous = metadata?.string("previous_name")
                let renamed = metadata?.string("new_name")
                if let previous, let renamed { return "\(previous) → \(renamed)" }
            }
            return nil
        default:
            return nil
        }
    }

    /// Supporting detail: full path (or full from/to pair).
    var displayDetail: String? {
        switch eventType {
        case .create, .edit, .delete:
            return metadata?.string("path")
        case .move:
            let from = metadata?.string("from")
            let to = metadata?.string("to")
            if let from, let to { return "\(from) → \(to)" }
            return from ?? to
        default:
            return nil
        }
    }

    private func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

extension TimelineEventType {
    var color: Color {
        switch self {
        case .create: .green
        case .open: .blue
        case .close: .gray
        case .edit: .indigo
        case .move: .orange
        case .delete: .red
        case .commit: .teal
        case .visit: .cyan
        case .screenshot: .pink
        case .workspaceSwitch: .purple
        }
    }
}
