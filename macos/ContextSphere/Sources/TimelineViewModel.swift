import SwiftUI
import AppKit

/// Chronological activity feed for a workspace, backed by the Rust
/// timeline engine. Newest first, grouped by day, filtered by workspace
/// and event type, with live updates from `timeline:event_added`.
struct TimelineView: View {
    @ObservedObject var viewModel: TimelineViewModel

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
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .task { await viewModel.initialLoadIfNeeded() }
    }

    // MARK: - Header

    private var header: some View {
        ScreenHeader("Timeline",
                     subtitle: subtitle,
                     symbol: "clock") {
            HStack(spacing: 10) {
                workspacePicker
                typePicker
                refreshButton
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

    private var refreshButton: some View {
        Button {
            Task { await viewModel.refresh() }
        } label: {
            if viewModel.isFetching {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(viewModel.isFetching)
        .help("Refresh timeline")
        .accessibilityLabel("Refresh timeline")
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
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("Timeline unavailable").font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Retry") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Retry loading the timeline")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func emptyState(title: String, message: String, symbol: String,
                            actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .accessibilityLabel(actionTitle)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lastError = viewModel.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Refresh failed: \(lastError)").lineLimit(1)
                    Spacer()
                    Button("Retry") {
                        Task { await viewModel.refresh() }
                    }
                    .font(.callout)
                }
                .font(.callout)
                .padding(10)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.bottom, 12)
                .accessibilityLabel("Refresh failed: \(lastError)")
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
                            onOpen: { path in
                                openFile(at: path)
                            }
                        )
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

    private func groupHeader(_ group: TimelineViewModel.DayGroup) -> some View {
        HStack(spacing: 10) {
            Text(group.label)
                .font(.headline)
                .foregroundStyle(.primary)
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
        }
        .padding(.top, 18)
        .padding(.bottom, 8)
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

/// One timeline entry: type marker, human-readable description, artifact,
/// workspace, and timestamp. File-backed events are tappable and vend a
/// native macOS context menu (Open / Reveal / Copy).
struct TimelineEventRow: View {
    let event: TimelineEvent
    let workspaceName: String?
    let isLast: Bool
    var onOpen: ((String) -> Void)? = nil

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
            VStack(spacing: 3) {
                Circle()
                    .fill(event.eventType.color)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(.background.opacity(0.6), lineWidth: 1))
                if !isLast {
                    Rectangle()
                        .fill(Color.primary.opacity(0.09))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 8)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: event.eventType.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(event.eventType.color)
                        .accessibilityHidden(true)
                    Text(event.displayTitle)
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(event.occurredAtDate.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if isFileEvent {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                if let artifact = event.artifactName {
                    Text(artifact)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let workspaceName {
                        Text(workspaceName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let detail = event.displayDetail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )
        }
        .contentShape(Rectangle())
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