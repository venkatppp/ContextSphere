import AppKit
import Combine

/// Local-first application activity observation.
///
/// Observes foreground app switches via NSWorkspace (no extra permission).
/// Each switch closes the previous app interval and opens a new one,
/// persisted locally via `record_activity_event` (SQLite, WAL). No telemetry
/// leaves the device. Web activity is not yet observed — that path is
/// gated behind explicit permission and remains unavailable honestly.
///
/// The monitor is best-effort: if the daemon is not yet ready, the event is
/// dropped rather than queued indefinitely. This keeps the hot path cheap
/// and avoids unbounded memory growth.
@MainActor
final class ActivityMonitor: ObservableObject {
    static let shared = ActivityMonitor()

    private var lastAppName: String?
    private var lastBundleID: String?
    private var lastStartedAt: Date?
    private var observer: NSObjectProtocol?
    private var isStarted = false
    private var pendingTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
        // Prime with current foreground app
        if let current = NSWorkspace.shared.frontmostApplication {
            lastAppName = current.localizedName
            lastBundleID = current.bundleIdentifier
            lastStartedAt = Date()
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                self.handleActivation(notification)
            }
        }
        // Also handle sleep/wake: close current interval on sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSleep() }
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        isStarted = false
    }

    private func handleActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let newName = app.localizedName else { return }
        let newBundle = app.bundleIdentifier
        let now = Date()

        // If same app as before, ignore rapid re-activation (debounce)
        if newName == lastAppName, let last = lastStartedAt, now.timeIntervalSince(last) < 5 {
            return
        }

        // Close previous interval if we have one
        if let prevName = lastAppName, let prevStart = lastStartedAt {
            let duration = now.timeIntervalSince(prevStart)
            // Ignore sub-5-second foreground blips (focus flicker, alt-tab)
            if duration >= 5 {
                record(appName: prevName, bundleID: lastBundleID, startedAt: prevStart, endedAt: now, duration: Int(duration))
            }
        }

        // Open new interval
        lastAppName = newName
        lastBundleID = newBundle
        lastStartedAt = now
        // Record open interval with nil duration (still active) — not stored until closed,
        // so we only emit closed intervals to avoid storing open-ended rows.
    }

    private func handleSleep() {
        guard let prevName = lastAppName, let prevStart = lastStartedAt else { return }
        let now = Date()
        let duration = now.timeIntervalSince(prevStart)
        if duration >= 5 {
            record(appName: prevName, bundleID: lastBundleID, startedAt: prevStart, endedAt: now, duration: Int(duration))
        }
        lastAppName = nil
        lastBundleID = nil
        lastStartedAt = nil
    }

    private func record(appName: String, bundleID: String?, startedAt: Date, endedAt: Date, duration: Int) {
        // Sanitize: we never record window title or URL — only app name/bundle.
        // Privacy: app names are not sensitive beyond installed apps list.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let startedStr = iso.string(from: startedAt)
        let endedStr = iso.string(from: endedAt)

        pendingTask?.cancel()
        pendingTask = Task {
            do {
                // Determine active workspace for correlation (best-effort)
                let wsId: String? = await fetchActiveWorkspaceId()
                var params: [String: Any] = [
                    "app_name": appName,
                    "event_type": "app_foreground",
                    "started_at": startedStr,
                    "ended_at": endedStr,
                    "duration_seconds": duration,
                ]
                if let bid = bundleID { params["bundle_id"] = bid }
                if let wid = wsId { params["workspace_id"] = wid }

                try await CoreBridge.shared.call("record_activity_event", params: params)
            } catch {
                // Best-effort: silently drop if daemon not ready. No retry queue needed for MVP;
                // the next interval will succeed. Logging at debug level avoids noise.
            }
        }
    }

    private func fetchActiveWorkspaceId() async -> String? {
        // Best-effort: ask the core for active workspace(s). If unavailable, stay global (nil).
        do {
            let workspaces: [Workspace] = try await CoreBridge.shared.request("list_active_workspaces", as: [Workspace].self)
            return workspaces.first { $0.status == .active }?.id ?? workspaces.first?.id
        } catch {
            return nil
        }
    }
}
