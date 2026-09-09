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

    /// Dismisses the current in-app tray without deleting the underlying
    /// notification from the backend — collapse vs dismiss are separate.
    /// Collapse hides temporarily; this dismiss clears the tray and calls
    /// `copilot_dismiss_notification` so the backend marks it dismissed.
    func dismissCurrent() async {
        guard let payload = latest else { return }
        latest = nil
        deliveredIds.remove(payload.id)
        do {
            try await CoreBridge.shared.call(
                "copilot_dismiss_notification",
                params: ["notification_id": payload.id]
            )
        } catch {
            // Non-fatal: the UI already cleared, backend will expire it.
        }
    }

    func clearTray() {
        latest = nil
    }
}

// MARK: - Proactive Action Banner (Phase D, minimal)

/// Minimal in-app banner for the latest `ProactiveNotificationPayload.actions`.
/// Uses existing `csPalette`/`CSColor` and `ContentCard` styling; no new
/// visual system. Shows title/description/confidence and an Execute button
/// that goes through `CoreBridge.executeProactiveAction` → `ToolExecutor`.
struct ProactiveActionBanner: View {
    let payload: ProactiveNotificationPayload
    var onCollapse: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil
    @State private var executingId: String?
    @State private var resultMessage: String?
    @State private var showConfirmation: ProactiveAction?

    init(payload: ProactiveNotificationPayload, onCollapse: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil) {
        self.payload = payload
        self.onCollapse = onCollapse
        self.onDismiss = onDismiss
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
                        if onCollapse != nil {
                            Button {
                                onCollapse?()
                            } label: {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 12, weight: .semibold))
                                    .csForeground(CSColor.textTertiary)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(Color.cs(CSColor.textTertiary).opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                            .help("Collapse suggestions")
                            .accessibilityLabel("Collapse suggestions")
                        }
                        if onDismiss != nil {
                            Button {
                                onDismiss?()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .csForeground(CSColor.textTertiary)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(Color.cs(CSColor.textTertiary).opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                            .help("Dismiss suggestion")
                            .accessibilityLabel("Dismiss suggestion")
                        }
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
            case "requires_confirmation":
                // Prompt for permission then retry
                showConfirmation = action
                resultMessage = "Requires confirmation — tap Confirm."
            case "permission_denied":
                resultMessage = "Permission denied for \(result.toolName ?? "tool")"
            case "expired", "dismissed":
                resultMessage = result.message
            case "unsupported":
                // Filter should have prevented this from ever being runnable;
                // treat as a non-user-facing diagnostic (log) with a generic UI.
                // Never expose "Unsupported action: Scan for duplicate files".
                resultMessage = "This action is not available."
            case "not_found":
                resultMessage = "Action not found — it may have expired."
            case "workspace_mismatch":
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

// MARK: - Collapsible Suggestion Tray

/// Compact, collapsible container for the proactive banner.
/// Expanded: full `ProactiveActionBanner` anchored top-right.
/// Collapsed: small pill trigger with icon + count, tap to re-expand.
/// Collapse is local UI state only — it never dismisses the underlying
/// `ProactiveNotification`. Dismiss is a separate explicit action.
struct ProactiveSuggestionTray: View {
    @ObservedObject var notifier: ProactiveNotifier
    @State private var isCollapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let payload = notifier.latest, !payload.actionable.isEmpty {
                let visible = payload.actionable.filter { $0.actionType.isSupported }
                if visible.isEmpty {
                    EmptyView()
                } else if isCollapsed {
                    collapsedView(count: visible.count, payload: payload)
                } else {
                    ProactiveActionBanner(
                        payload: payload,
                        onCollapse: { withAnimation(Theme.spring(reduceMotion, response: 0.28)) { isCollapsed = true } },
                        onDismiss: {
                            Task { await notifier.dismissCurrent() }
                        }
                    )
                    .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
                }
            }
        }
        .onChange(of: notifier.latest?.id) { old, new in
            // New suggestion should re-expand so the user sees it; collapse
            // is explicitly local and transient.
            if new != nil, new != old {
                withAnimation(Theme.spring(reduceMotion, response: 0.28)) { isCollapsed = false }
            }
        }
    }

    private func collapsedView(count: Int, payload: ProactiveNotificationPayload) -> some View {
        Button {
            withAnimation(Theme.spring(reduceMotion, response: 0.28)) { isCollapsed = false }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(count == 1 ? "1 suggestion" : "\(count) suggestions")
                    .font(.system(size: 13, weight: .semibold))
                    .csForeground(CSColor.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .csForeground(CSColor.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.cs(CSColor.surface).opacity(0.96))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.cs(CSColor.borderSubtle), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .help("Show suggestions")
        .accessibilityLabel("\(count) suggestions, collapsed. Tap to expand.")
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }
}

// `ProactiveActionType.toolName` / `isSupported` / `allowedTools` are
// defined in `RPCModels.swift` (single source of truth mirroring the Rust
// `ToolRegistry`). This file reuses that definition — no duplication.
