import AppKit
import Combine

/// Local-first application + web activity observation.
///
/// - App: observes foreground switches via NSWorkspace (no permission).
/// - Web: when the foreground app is a browser (Safari/Chrome/Edge/Firefox),
///   attempts to fetch the front-tab URL/title via AppleScript. This requires
///   the user-granted **Automation** permission (System Settings → Privacy &
///   Security → Automation → ContextSphere → Safari/Chrome). If denied,
///   web activity stays unavailable honestly — no silent history reading,
///   no full URL/query strings stored, only `url_domain` + `url_title`.
///
/// Each app switch closes the previous app interval and opens a new one,
/// persisted locally via `record_activity_event` (SQLite, WAL). No telemetry
/// leaves the device. Best-effort: if the daemon is not ready, the event
/// is dropped rather than queued.
@MainActor
final class ActivityMonitor: ObservableObject {
    static let shared = ActivityMonitor()

    private var lastAppName: String?
    private var lastBundleID: String?
    private var lastStartedAt: Date?
    private var observer: NSObjectProtocol?
    private var isStarted = false
    private var pendingTask: Task<Void, Never>?

    // Web interval tracking — duration-aware, deduplicated, workspace-associated
    private var lastWebDomain: String?
    private var lastWebTitle: String?
    private var lastWebStartedAt: Date?
    private var lastWebBrowser: String?
    private var lastWebBundleID: String?

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

        // Close previous app interval if we have one
        if let prevName = lastAppName, let prevStart = lastStartedAt {
            let duration = now.timeIntervalSince(prevStart)
            // Ignore sub-5-second foreground blips (focus flicker, alt-tab)
            if duration >= 5 {
                record(appName: prevName, bundleID: lastBundleID, startedAt: prevStart, endedAt: now, duration: Int(duration))
            }
        }
        // Close previous web interval if browser loses focus or switches
        if lastWebDomain != nil {
            let isNewBrowser = isBrowserApp(bundleID: newBundle, name: newName)
            // If switching away from a browser, or staying in same browser family but capturing new page later,
            // we close the interval here to calculate correct duration; duplicate handling below will dedup.
            if !isNewBrowser || newName != lastWebBrowser {
                closeWebInterval(at: now)
            }
        }

        // Open new interval
        lastAppName = newName
        lastBundleID = newBundle
        lastStartedAt = now

        // Privacy-first web capture: only when foreground is a browser and permission is available.
        if isBrowserApp(bundleID: newBundle, name: newName) {
            attemptWebCapture(for: newName, bundleID: newBundle, startedAt: now)
        }
    }

    private func handleSleep() {
        let now = Date()
        if let prevName = lastAppName, let prevStart = lastStartedAt {
            let duration = now.timeIntervalSince(prevStart)
            if duration >= 5 {
                record(appName: prevName, bundleID: lastBundleID, startedAt: prevStart, endedAt: now, duration: Int(duration))
            }
        }
        lastAppName = nil
        lastBundleID = nil
        lastStartedAt = nil
        closeWebInterval(at: now)
    }

    private func closeWebInterval(at now: Date) {
        guard let domain = lastWebDomain, let started = lastWebStartedAt, let browser = lastWebBrowser else { return }
        let duration = Int(now.timeIntervalSince(started))
        if duration >= 5 {
            recordWebVisit(browser: browser, bundleID: lastWebBundleID, domain: domain, title: lastWebTitle, startedAt: started, endedAt: now, duration: duration)
        }
        lastWebDomain = nil
        lastWebTitle = nil
        lastWebStartedAt = nil
        lastWebBrowser = nil
        lastWebBundleID = nil
    }

    private func isBrowserApp(bundleID: String?, name: String) -> Bool {
        let bid = (bundleID ?? "").lowercased()
        let n = name.lowercased()
        return bid.contains("safari") || bid.contains("chrome") || bid.contains("edge") || bid.contains("firefox") || bid.contains("brave")
            || n == "safari" || n == "google chrome" || n == "microsoft edge" || n == "firefox" || n == "brave browser"
    }

    private func attemptWebCapture(for appName: String, bundleID: String?, startedAt: Date) {
        // Throttle: don't hammer AppleScript if we just did (8s per browser)
        let key = "activity.webLastCapture.\(appName)"
        if let last = UserDefaults.standard.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 8 { return }

        Task.detached(priority: .utility) {
            let result = await self.fetchBrowserURL(appName: appName)
            await MainActor.run {
                UserDefaults.standard.set(Date(), forKey: key)
                switch result {
                case .success(let (url, title)):
                    guard let url, let host = URL(string: url)?.host, !host.isEmpty else { return }
                    // Store ONLY domain + title, never query strings / passwords / path params
                    let domain = host.lowercased()
                    let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120).description
                    // Deduplicate: same domain+title within 30s is same visit, just extend
                    if domain == self.lastWebDomain && cleanTitle == (self.lastWebTitle ?? ""), let start = self.lastWebStartedAt, Date().timeIntervalSince(start) < 30 {
                        return
                    }
                    // Close previous web interval before opening new one to calculate correct duration
                    if self.lastWebDomain != nil {
                        self.closeWebInterval(at: Date())
                    }
                    // Open new interval — persist on close (duration-aware)
                    self.lastWebDomain = domain
                    self.lastWebTitle = cleanTitle
                    self.lastWebStartedAt = Date()
                    self.lastWebBrowser = appName
                    self.lastWebBundleID = bundleID
                    UserDefaults.standard.removeObject(forKey: "activity.webPermissionDenied")
                case .failure(let error):
                    let msg = error.localizedDescription.lowercased()
                    if msg.contains("not allowed") || msg.contains("not authorized") || msg.contains("-1743") || msg.contains("1002") {
                        UserDefaults.standard.set(true, forKey: "activity.webPermissionDenied")
                        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "activity.webPermissionDeniedAt")
                    }
                }
            }
        }
    }

    private enum WebFetchResult {
        case success(url: String?, title: String?)
        case failure(Error)
    }

    private func fetchBrowserURL(appName: String) async -> Result<(String?, String?), Error> {
        // AppleScript is synchronous and must not block main thread — already on detached utility
        let source: String
        switch appName.lowercased() {
        case "safari":
            source = "tell application \"Safari\" to get {URL, name} of front document"
        case "google chrome", "chrome":
            source = "tell application \"Google Chrome\" to get {URL of active tab of front window, title of active tab of front window}"
        case "microsoft edge", "edge":
            source = "tell application \"Microsoft Edge\" to get {URL of active tab of front window, title of active tab of front window}"
        default:
            // Brave, Arc, etc. — try Chrome scripting
            source = "tell application \"\(appName)\" to get {URL of active tab of front window, title of active tab of front window}"
        }
        return await withCheckedContinuation { cont in
            var error: NSDictionary?
            if let script = NSAppleScript(source: source) {
                let result = script.executeAndReturnError(&error)
                if let err = error {
                    cont.resume(returning: .failure(NSError(domain: "AppleScript", code: -1, userInfo: [NSLocalizedDescriptionKey: err.description])))
                    return
                }
                // Result is a list of 2 items
                if result.descriptorType == typeAEList, let urlDesc = result.atIndex(1), let titleDesc = result.atIndex(2) {
                    cont.resume(returning: .success((urlDesc.stringValue, titleDesc.stringValue)))
                } else {
                    cont.resume(returning: .success((result.stringValue, nil)))
                }
            } else {
                cont.resume(returning: .failure(NSError(domain: "AppleScript", code: -2, userInfo: [NSLocalizedDescriptionKey: "Could not create script"])))
            }
        }
    }

    private func recordWebVisit(browser: String, bundleID: String?, domain: String, title: String?, startedAt: Date, endedAt: Date? = nil, duration: Int? = nil) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let startedStr = iso.string(from: startedAt)
        var endedStr: String?
        if let e = endedAt { endedStr = iso.string(from: e) }
        Task {
            do {
                let wsId: String? = await fetchActiveWorkspaceId()
                var params: [String: Any] = [
                    "app_name": browser,
                    "event_type": "web_visit",
                    "started_at": startedStr,
                    "url_domain": domain,
                ]
                if let t = title, !t.isEmpty { params["url_title"] = t }
                if let bid = bundleID { params["bundle_id"] = bid }
                if let wid = wsId { params["workspace_id"] = wid }
                if let es = endedStr { params["ended_at"] = es }
                if let d = duration { params["duration_seconds"] = d }
                try await CoreBridge.shared.call("record_activity_event", params: params)
            } catch {}
        }
    }

    private func record(appName: String, bundleID: String?, startedAt: Date, endedAt: Date, duration: Int) {
        // Sanitize: we never record window title with private content — only app name/bundle.
        // Web visits are handled separately via recordWebVisit with domain/title only.
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
