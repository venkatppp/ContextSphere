import Foundation
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
