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
                    .foregroundStyle(isSelected ? Color.accentColor : Color.cs(CSColor.textSecondary))
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(workspace.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .csForeground(CSColor.textPrimary)
                    if workspace.status == .archived {
                        Text("Archived")
                            .font(.system(size: 9, weight: .semibold))
                            .csForeground(CSColor.textTertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.cs(CSColor.textTertiary).opacity(0.10),
                                        in: Capsule(style: .continuous))
                    }
                }
                if let path = workspace.rootPath, !path.isEmpty {
                    Text(path)
                        .font(.caption2)
                        .csForeground(CSColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if let description = workspace.description, !description.isEmpty {
                    Text(description)
                        .font(.caption2)
                        .csForeground(CSColor.textTertiary)
                        .lineLimit(1)
                } else {
                    Text("No folder set")
                        .font(.caption2)
                        .csForeground(CSColor.textTertiary)
                }
            }
            Spacer(minLength: 6)
            if workspace.status == .active {
                Circle()
                    .fill(Color.cs(CSColor.success))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                .fill(isSelected ? Color.cs(CSColor.selectionFill)
                      : (isHovered ? Color.cs(CSColor.hoverFill) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                .strokeBorder(isSelected ? Color.cs(CSColor.selectionBorder) : .clear, lineWidth: 0.5)
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
            .background(status == .active ? Color.cs(CSColor.success).opacity(0.14) : Color.cs(CSColor.textSecondary).opacity(0.12),
                        in: Capsule())
            .foregroundStyle(status == .active ? Color.cs(CSColor.success) : Color.cs(CSColor.textSecondary))
            .overlay(
                Capsule().strokeBorder(status == .active ? Color.cs(CSColor.success).opacity(0.25) : .clear, lineWidth: 0.5)
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
                    .csForeground(CSColor.textSecondary)
                Text(value)
                    .font(.callout.weight(.semibold))
                    .csForeground(CSColor.textPrimary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
