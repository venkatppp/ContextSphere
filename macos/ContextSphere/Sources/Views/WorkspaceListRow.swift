import SwiftUI

struct WorkspaceListRow: View {
    let workspace: Workspace
    var isSelected = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.accentColor.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: workspace.status == .active ? "folder.fill" : "archivebox.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .primary : .primary)
                if let path = workspace.rootPath, !path.isEmpty {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if let description = workspace.description, !description.isEmpty {
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if workspace.status == .active {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(workspace.name), \(workspace.status.rawValue), \(workspace.rootPath ?? "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct StatusBadge: View {
    let status: WorkspaceStatus

    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(status == .active ? Color.green.opacity(0.14) : Color.secondary.opacity(0.12),
                        in: Capsule())
            .foregroundStyle(status == .active ? Color.green : Color.secondary)
            .overlay(
                Capsule().strokeBorder(status == .active ? Color.green.opacity(0.25) : Color.clear, lineWidth: 0.5)
            )
            .accessibilityLabel("Status \(status.rawValue)")
    }
}

struct StatTile: View {
    let label: String
    let value: String
    let symbol: String

    var body: some View {
        ContentCard(cornerRadius: Theme.cornerRegular) {
            VStack(alignment: .leading, spacing: 6) {
                Label(label, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
