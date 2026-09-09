import Foundation
import SwiftUI
import UserNotifications

/// Delivers backend `proactive:notification` payloads as native macOS
/// notifications.
///
/// Policy:
/// - only `high` / `critical` priority items reach Notification Center;
///   lower priorities stay in the in-app surfaces (Dashboard resume row,
///   Memory/Learning insights),
/// - ids are deduplicated so a daemon restart or repeated detector hit
///   never double-posts,
/// - authorization is requested lazily on first eligible item; denial is
///   remembered and never re-prompted (the app keeps functioning without
///   system notifications).
@MainActor
final class ProactiveNotifier: ObservableObject {
    /// The most recent high-priority payload, for optional in-app echo.
    @Published private(set) var latest: ProactiveNotificationPayload?

    private var deliveredIds: Set<String> = []
    private var authorizationState: UNAuthorizationStatus?

    /// Routes one raw event payload. Returns whether a system notification
    /// was posted (used for debugging/QA).
    @discardableResult
    func deliver(_ data: Data?) async -> Bool {
        guard let data else { return false }
        let payload: ProactiveNotificationPayload
        do {
            payload = try JSONDecoder().decode(ProactiveNotificationPayload.self, from: data)
        } catch {
            return false
        }
        guard !deliveredIds.contains(payload.id) else { return false }
        deliveredIds.insert(payload.id)
        latest = payload

        guard payload.isHighPriority else { return false }
        guard await ensureAuthorization() else { return false }

        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.message
        if let action = payload.suggestedActions.first {
            content.subtitle = action
        }
        content.userInfo = [
            "workspaceId": payload.workspaceId ?? "",
            "notificationId": payload.id,
        ]
        content.sound = payload.priority == "critical" ? .defaultCritical : .default

        let request = UNNotificationRequest(
            identifier: "proactive.\(payload.id)", content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }

    private func ensureAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            authorizationState = granted ? .authorized : .denied
            return granted
        default:
            authorizationState = settings.authorizationStatus
            return false
        }
    }
}

// MARK: - Proactive Action Banner (Phase D, minimal)

/// Minimal in-app banner for the latest `ProactiveNotificationPayload.actions`.
/// Uses existing `csPalette`/`CSColor` and `ContentCard` styling; no new
/// visual system. Shows title/description/confidence and an Execute button
/// that goes through `CoreBridge.executeProactiveAction` → `ToolExecutor`.
struct ProactiveActionBanner: View {
    let payload: ProactiveNotificationPayload
    @State private var executingId: String?
    @State private var resultMessage: String?
    @State private var showConfirmation: ProactiveAction?

    init(payload: ProactiveNotificationPayload) {
        self.payload = payload
    }

    var body: some View {
        // Defense-in-depth: actionable already filters unsupported at the model
        // layer, but re-filter here so a stale daemon payload never renders a
        // runnable Run button for an unsupported executor.
        let visible = payload.actionable.filter { $0.actionType.isSupported }
        if visible.isEmpty {
            EmptyView()
        } else {
            ContentCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Color.accentColor)
                        Text(payload.title).font(.headline)
                        Spacer()
                        Text(payload.notificationType.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.caption2).csForeground(CSColor.textTertiary)
                    }
                    Text(payload.message).font(.callout).csForeground(CSColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(visible, id: \.id) { action in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.title).font(.callout.weight(.medium))
                                Text(action.description).font(.caption).csForeground(CSColor.textSecondary).lineLimit(2)
                                HStack(spacing: 6) {
                                    Text(String(format: "%.0f%%", action.confidence * 100))
                                        .font(.caption2.monospacedDigit()).csForeground(CSColor.textTertiary)
                                    if let exp = action.expiresAt { Text(exp.relativeTime).font(.caption2).csForeground(CSColor.textTertiary) }
                                }
                            }
                            Spacer()
                            Button {
                                Task { await execute(action) }
                            } label: {
                                if executingId == action.id {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text(action.requiresConfirmation ? "Confirm" : "Run")
                                        .font(.caption.weight(.semibold))
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(executingId != nil)
                        }
                        .padding(8)
                        .background(Color.cs(CSColor.surfaceElevated).opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    if let msg = resultMessage {
                        Text(msg).font(.caption).csForeground(CSColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: 520)
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
            .confirmationDialog(
                "Confirm Action",
                isPresented: Binding(
                    get: { showConfirmation != nil },
                    set: { if !$0 { showConfirmation = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let action = showConfirmation {
                    Button("Confirm \(action.title)") { Task { await executeConfirmed(action) } }
                    Button("Cancel", role: .cancel) { showConfirmation = nil }
                }
            } message: {
                if let action = showConfirmation {
                    Text("Tool '\(action.actionType.toolName)' requires confirmation. Allow once?")
                }
            }
        }
    }

    private func execute(_ action: ProactiveAction) async {
        // Check if action itself says it needs confirmation (from backend) or if it's a tool that requires confirmation
        // The backend will return RequiresConfirmation status if needed, but we can also pre-check.
        if action.requiresConfirmation {
            showConfirmation = action
            return
        }
        await executeConfirmed(action)
    }

    private func executeConfirmed(_ action: ProactiveAction) async {
        executingId = action.id
        defer { executingId = nil; showConfirmation = nil }
        // NoOp never needs a permission grant — it is handled entirely in
        // Rust without a ToolExecutor invocation. Granting allow_once for
        // "noop" would create a spurious persisted policy.
        if case .noOp = action.actionType {
            // Direct execution without permission hop
        } else {
            // Confirmation retry: grant AllowOnce for the underlying tool via the
            // existing ToolPermissionService, then the backend will allow the
            // ToolExecutor to run. This is the correct permission boundary — no bypass.
            do {
                try await CoreBridge.shared.setToolPermission(
                    toolName: action.actionType.toolName,
                    workspaceId: payload.workspaceId,
                    decision: "allow_once"
                )
            } catch {
                resultMessage = "Failed to grant permission: \(error.localizedDescription)"
                return
            }
        }
        do {
            let result = try await CoreBridge.shared.executeProactiveAction(actionId: action.id, workspaceId: payload.workspaceId)
            switch result.status {
            case "executed":
                resultMessage = "✓ \(result.message)"
            case "requiresConfirmation":
                // Prompt for permission then retry
                showConfirmation = action
                resultMessage = "Requires confirmation — tap Confirm."
            case "permissionDenied":
                resultMessage = "Permission denied for \(result.toolName ?? "tool")"
            case "expired", "dismissed":
                resultMessage = result.message
            case "unsupported":
                // Filter should have prevented this from ever being runnable;
                // treat as a non-user-facing diagnostic (log) with a generic UI.
                // Never expose "Unsupported action: Scan for duplicate files".
                resultMessage = "This action is not available."
            case "notFound":
                resultMessage = "Action not found — it may have expired."
            case "workspaceMismatch":
                resultMessage = "Workspace mismatch — action belongs to another workspace."
            case "failed":
                resultMessage = result.error ?? result.message
            default:
                resultMessage = result.message
            }
        } catch {
            resultMessage = error.localizedDescription
        }
    }
}

// `ProactiveActionType.toolName` / `isSupported` / `allowedTools` are
// defined in `RPCModels.swift` (single source of truth mirroring the Rust
// `ToolRegistry`). This file reuses that definition — no duplication.
