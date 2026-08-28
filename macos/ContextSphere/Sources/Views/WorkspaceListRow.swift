import SwiftUI

struct WorkspaceListRow: View {
    let workspace: Workspace
    var isSelected = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.accentColor.opacity(0.12))
                Image(systemName: workspace.status == .active ? "folder.fill" : "archivebox.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(workspace.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if workspace.status == .archived {
                        Text("Archived")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary.opacity(0.4), in: Capsule(style: .continuous))
                    }
                }
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
                } else {
                    Text("No folder set")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 6)
            if workspace.status == .active {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16)
                      : (isHovered ? Color.primary.opacity(0.05) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
        .onHover { isHovered = $0 }
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
                Capsule().strokeBorder(status == .active ? Color.green.opacity(0.25) : .clear, lineWidth: 0.5)
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
