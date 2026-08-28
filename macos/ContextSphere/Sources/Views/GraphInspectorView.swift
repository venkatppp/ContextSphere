import SwiftUI

/// Floating glass inspector for the selected graph node. Shows identity,
/// context, timestamps, and the relationship breakdown of the selection,
/// plus an action to expand the subgraph around it.
struct GraphInspectorView: View {
    @ObservedObject var viewModel: GraphViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let node = viewModel.selectedNode {
                Divider()
                identitySection(node)
                Divider()
                relationshipSection(node)
                Divider()
                actionRow(node)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 280)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 24, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Graph inspector")
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Inspector")
                    .font(.csEyebrow())
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
            Spacer()
            Button {
                viewModel.showInspector = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.quaternary.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close inspector")
            .accessibilityLabel("Close inspector")
        }
    }

    private func identitySection(_ node: KgNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: node.nodeType.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(node.nodeType.color)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(node.title)
                    .font(.headline)
                    .lineLimit(3)
                    .accessibilityLabel("Name: \(node.title)")
            }
            typeBadge(node)
            if let workspace = viewModel.workspaceName(for: node) {
                Label(workspace, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Workspace: \(workspace)")
            }
            if let summary = node.summary, !summary.isEmpty, summary != node.title {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .accessibilityLabel("Summary: \(summary)")
            }
            if let metadata = node.metadata.objectValue, !metadata.isEmpty {
                metadataBlock(metadata)
            }
            HStack(spacing: 12) {
                if !node.createdAt.isEmpty {
                    Text("Created \(relative(node.createdAt))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Created \(relative(node.createdAt))")
                }
                if !node.updatedAt.isEmpty {
                    Text("Updated \(relative(node.updatedAt))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Updated \(relative(node.updatedAt))")
                }
            }
        }
    }

    @ViewBuilder
    private func metadataBlock(_ metadata: [String: JSONValue]) -> some View {
        ContentCard(cornerRadius: Theme.cornerSmall) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Details", systemImage: "info.circle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.3)
                ForEach(metadata.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    HStack(alignment: .top, spacing: 8) {
                        Text(key)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 88, alignment: .leading)
                            .accessibilityLabel("\(key)")
                        Text(metadataString(value))
                            .font(.caption2)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .accessibilityLabel("\(key): \(metadataString(value))")
                    }
                }
            }
        }
    }

    private func relationshipSection(_ node: KgNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Relationships", symbol: "point.3.connected.trianglepath.dotted")
            let breakdown = viewModel.relationshipBreakdown(for: node.id)
            if breakdown.isEmpty {
                Text("No relationships — expand to discover more.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("No relationships")
            } else {
                ContentCard(cornerRadius: Theme.cornerSmall) {
                    VStack(spacing: 6) {
                        ForEach(breakdown, id: \.type) { row in
                            HStack {
                                Label(row.type.title, systemImage: row.type.color == .gray ? "link" : "arrow.triangle.branch")
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .accessibilityLabel(row.type.title)
                                Spacer()
                                Text("\(row.count)")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(row.type.color)
                                    .accessibilityLabel("\(row.count) relationships")
                            }
                            if row.type != breakdown.last?.type {
                                Divider().opacity(0.4)
                            }
                        }
                    }
                }
            }
        }
    }

    private func actionRow(_ node: KgNode) -> some View {
        HStack(spacing: 8) {
            Button {
                viewModel.expand(node)
            } label: {
                Label("Expand", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .buttonStyle(.glassProminent)
            .disabled(viewModel.isExpanding)
            .accessibilityLabel("Expand subgraph around \(node.title)")
            .accessibilityHint("Loads relationships connected to this node")

            Spacer()

            Menu {
                Button("Copy name") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.title, forType: .string)
                }
                Button("Copy details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyDetails(node), forType: .string)
                }
            } label: {
                Image(systemName: "square.on.square")
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Copy node details")
            .accessibilityLabel("Copy node details")
        }
    }

    private func typeBadge(_ node: KgNode) -> some View {
        Text(node.nodeType.title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(node.nodeType.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(node.nodeType.color.opacity(0.14),
                        in: Capsule())
            .accessibilityLabel("Type: \(node.nodeType.title)")
    }

    private func relative(_ isoDate: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoDate) ?? ISO8601DateFormatter().date(from: isoDate) else {
            return isoDate
        }
        let formatter2 = RelativeDateTimeFormatter()
        formatter2.unitsStyle = .abbreviated
        return formatter2.localizedString(for: date, relativeTo: Date())
    }

    private func metadataString(_ value: JSONValue) -> String {
        switch value {
        case .string(let string): string
        case .number(let double): String(double)
        case .bool(let bool): bool ? "true" : "false"
        case .null: ""
        case .object(let object): object.map { "\($0.key): \(metadataString($0.value))" }.joined(separator: ", ")
        case .array(let array): array.map(metadataString).joined(separator: ", ")
        }
    }

    private func copyDetails(_ node: KgNode) -> String {
        var lines: [String] = [node.title]
        lines.append("Type: \(node.nodeType.title)")
        if let workspace = viewModel.workspaceName(for: node) {
            lines.append("Workspace: \(workspace)")
        }
        if let summary = node.summary, !summary.isEmpty {
            lines.append("Summary: \(summary)")
        }
        if let metadata = node.metadata.objectValue, !metadata.isEmpty {
            for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
                lines.append("\(key): \(metadataString(value))")
            }
        }
        let breakdown = viewModel.relationshipBreakdown(for: node.id)
        for row in breakdown {
            lines.append("\(row.type.title): \(row.count)")
        }
        return lines.joined(separator: "\n")
    }
}

private extension GraphRelationshipType {
    var color: Color {
        switch self {
        case .contains: .gray
        case .runsIn: .gray
        case .reportsOn: .orange
        case .derivedFrom: .purple
        case .relatedTo: .teal
        }
    }
}