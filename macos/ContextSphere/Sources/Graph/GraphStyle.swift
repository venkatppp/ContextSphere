import SwiftUI

// MARK: - Visual language (prompt §12, §13)

extension GraphNodeType {
    var title: String {
        switch self {
        case .workspace: "Workspace"
        case .file: "File"
        case .plannerReport: "Planner report"
        case .execution: "Execution"
        case .memoryRecord: "Memory record"
        case .autonomousSession: "Autonomous session"
        }
    }
    var symbol: String {
        switch self {
        case .workspace: "folder.fill"
        case .file: "doc.text.fill"
        case .plannerReport: "chart.bar.doc.horizontal"
        case .execution: "play.circle.fill"
        case .memoryRecord: "brain.head.profile"
        case .autonomousSession: "sparkles"
        }
    }
    var color: Color {
        switch self {
        case .workspace: .indigo
        case .file: .teal
        case .plannerReport: .purple
        case .execution: .orange
        case .memoryRecord: .pink
        case .autonomousSession: .cyan
        }
    }
    var nodeRadius: CGFloat {
        switch self {
        case .workspace: 22
        case .file: 9
        default: 13
        }
    }
}

extension GraphRelationshipType {
    var title: String {
        switch self {
        case .contains: "Contains"
        case .runsIn: "Runs in"
        case .reportsOn: "Reports on"
        case .derivedFrom: "Derived from"
        case .relatedTo: "Related to"
        }
    }
}
