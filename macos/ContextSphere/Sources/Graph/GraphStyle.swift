import SwiftUI

// MARK: - Visual language

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

    /// System symbol used as a node glyph. Distinct icon per type so the
    /// user can read the graph at a glance.
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

    /// Semantic color token, resolved through the design system.
    var colorToken: String {
        switch self {
        case .workspace:        CSColor.graphWorkspace
        case .file:             CSColor.graphFile
        case .plannerReport:    CSColor.graphIntelligence
        case .execution:        CSColor.graphExecution
        case .memoryRecord:     CSColor.graphMemory
        case .autonomousSession: CSColor.graphSession
        }
    }

    /// Visual radius in world space (before camera zoom).
    var nodeRadius: CGFloat {
        switch self {
        case .workspace: 18
        case .file: 8
        case .plannerReport: 11
        case .execution: 10
        case .memoryRecord: 11
        case .autonomousSession: 12
        }
    }

    /// Compact label (used in legend chips & inspector).
    var shortTitle: String {
        switch self {
        case .workspace: "Workspace"
        case .file: "File"
        case .plannerReport: "Planner"
        case .execution: "Execution"
        case .memoryRecord: "Memory"
        case .autonomousSession: "Session"
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

    /// Token for the inspector breakdown dot.
    var colorToken: String {
        switch self {
        case .contains:     CSColor.textTertiary
        case .runsIn:       CSColor.textTertiary
        case .reportsOn:    CSColor.warning
        case .derivedFrom:  CSColor.graphIntelligence
        case .relatedTo:    CSColor.info
        }
    }
}
