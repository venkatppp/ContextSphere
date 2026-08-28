import SwiftUI

/// Native contextual inspector for the selected graph node. Shows
/// identity, status, details, relationships and relevant activity with
/// clear hierarchy. Slides in from the trailing edge and stays out of
/// the canvas (RC-9 §12).
struct GraphInspectorView: View {
    @ObservedObject var viewModel: GraphViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let node = viewModel.selectedNode {
                Divider().opacity(0.4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        identitySection(node)
                        actionRow(node)
                        if let workspace = viewModel.workspaceName(for: node) {
                            metadataRow(icon: "folder", label: "Workspace", value: workspace)
                        }
                        relationshipSection(node)
                        if let metadata = node.metadata.objectValue, !metadata.isEmpty {
                            metadataSection(metadata)
                        }
                        activitySection(node)
                    }
                    .padding(16)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(width: 324)
        .frame(maxHeight: .infinity)
        .lgInspector()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Graph inspector")
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 11, weight: .semibold))
                    .csForeground(CSColor.textSecondary)
                Text("Inspector")
                    .font(.csEyebrow())
                    .csForeground(CSColor.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
            Spacer()
            Button {
                viewModel.showInspector = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .csForeground(CSColor.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(
                        Color.cs(CSColor.textTertiary).opacity(0.10),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .help("Close inspector")
            .accessibilityLabel("Close inspector")
        }
        .padding(16)
    }

    private func identitySection(_ node: KgNode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: node.nodeType.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .csForeground(node.nodeType.colorToken)
                    .frame(width: 32, height: 32)
                    .background(
                        Color.cs(node.nodeType.colorToken).opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title)
                        .font(.headline)
                        .csForeground(CSColor.textPrimary)
                        .lineLimit(3)
                        .accessibilityLabel("Name: \(node.title)")
                    typeBadge(node)
                }
            }
            if let summary = node.summary, !summary.isEmpty, summary != node.title {
                Text(summary)
                    .font(.callout)
                    .csForeground(CSColor.textSecondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .accessibilityLabel("Summary: \(summary)")
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
            .buttonStyle(.borderedProminent)
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

    private func metadataRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .csForeground(CSColor.textSecondary)
                .frame(width: 16)
            Text(label)
                .font(.caption2)
                .csForeground(CSColor.textTertiary)
                .textCase(.uppercase)
                .tracking(0.4)
            Text(value)
                .font(.caption)
                .csForeground(CSColor.textPrimary)
                .lineLimit(2)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private func relationshipSection(_ node: KgNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Relationships", symbol: "point.3.connected.trianglepath.dotted")
            let breakdown = viewModel.relationshipBreakdown(for: node.id)
            if breakdown.isEmpty {
                Text("No relationships — expand to discover more.")
                    .font(.callout)
                    .csForeground(CSColor.textSecondary)
                    .accessibilityLabel("No relationships")
            } else {
                VStack(spacing: 0) {
                    ForEach(breakdown, id: \.type) { row in
                        HStack {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.cs(row.type.colorToken))
                                    .frame(width: 6, height: 6)
                                Text(row.type.title)
                                    .font(.caption)
                                    .csForeground(CSColor.textPrimary)
                            }
                            .accessibilityLabel(row.type.title)
                            Spacer()
                            Text("\(row.count)")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .csForeground(row.type.colorToken)
                                .accessibilityLabel("\(row.count) relationships")
                        }
                        .padding(.vertical, 5)
                        if row.type != breakdown.last?.type {
                            Divider().opacity(0.3)
                        }
                    }
                }
                .padding(10)
                .background(
                    Color.cs(CSColor.surfaceElevated).opacity(0.5),
                    in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                        .strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5)
                )
            }
        }
    }

    private func metadataSection(_ metadata: [String: JSONValue]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Details", symbol: "info.circle")
            VStack(spacing: 0) {
                ForEach(metadata.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    HStack(alignment: .top, spacing: 8) {
                        Text(key)
                            .font(.caption2.weight(.medium))
                            .csForeground(CSColor.textSecondary)
                            .frame(width: 96, alignment: .leading)
                        Text(metadataString(value))
                            .font(.caption2)
                            .csForeground(CSColor.textPrimary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                    if key != metadata.keys.sorted().last {
                        Divider().opacity(0.25)
                    }
                }
            }
            .padding(10)
            .background(
                Color.cs(CSColor.surfaceElevated).opacity(0.5),
                in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                    .strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5)
            )
        }
    }

    private func activitySection(_ node: KgNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Relevant activity", symbol: "clock.arrow.circlepath")
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Created")
                        .font(.caption2)
                        .csForeground(CSColor.textTertiary)
                    Spacer()
                    Text(relative(node.createdAt))
                        .font(.caption2)
                        .csForeground(CSColor.textSecondary)
                }
                HStack {
                    Text("Updated")
                        .font(.caption2)
                        .csForeground(CSColor.textTertiary)
                    Spacer()
                    Text(relative(node.updatedAt))
                        .font(.caption2)
                        .csForeground(CSColor.textSecondary)
                }
            }
            .padding(10)
            .background(
                Color.cs(CSColor.surfaceElevated).opacity(0.5),
                in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                    .strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5)
            )
        }
    }

    private func typeBadge(_ node: KgNode) -> some View {
        Text(node.nodeType.title)
            .font(.caption2.weight(.semibold))
            .csForeground(node.nodeType.colorToken)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Color.cs(node.nodeType.colorToken).opacity(0.14),
                in: Capsule()
            )
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
