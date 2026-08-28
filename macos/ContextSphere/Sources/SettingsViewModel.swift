import AppKit
import Foundation

// MARK: - Persistence state

/// Per-setting persistence state surfaced next to the controls. The
/// backend persists each domain immediately (no global Apply), so this
/// tracks the outcome of every individual save.
enum SettingsSaveState: Equatable {
    case idle
    case saving
    case saved
    case failed(String)
}

// MARK: - View model

/// Owns every Settings screen RPC. SwiftUI views bind to the published
/// state below and never talk to the bridge directly; the backend
/// (Rust core → SQLite) remains the single source of truth.
@MainActor
final class SettingsViewModel: ObservableObject {

    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    // MARK: Lifecycle

    @Published private(set) var phase: Phase = .loading

    // MARK: General — session inactivity threshold (seconds)

    static let thresholdRange = 60...14400
    static let thresholdDefault = 1800
    @Published var thresholdSeconds = SettingsViewModel.thresholdDefault
    @Published private(set) var thresholdSave: SettingsSaveState = .idle
    private var thresholdLoaded = SettingsViewModel.thresholdDefault
    private var thresholdDebounce: Task<Void, Never>?

    // MARK: Watched paths (merged into General)

    @Published private(set) var watchedPaths: [String] = []
    @Published var watchPathInput = ""
    @Published private(set) var watchAddState: SettingsSaveState = .idle
    @Published private(set) var watchPathErrors: [String: String] = [:]

    // MARK: Security policy

    static let monitorRange = 10...3600
    static let retentionRange = 1...3650
    static let monitorKey = "security.monitor_interval_seconds"
    static let auditKey = "security.audit_retention_days"
    static let findingsKey = "security.findings_retention_days"
    @Published var monitorIntervalSeconds = 300
    @Published var auditRetentionDays = 90
    @Published var findingsRetentionDays = 30
    @Published private(set) var securitySetKeys: Set<String> = []
    @Published private(set) var securitySave: [String: SettingsSaveState] = [:]
    private var monitorLoaded = 300
    private var auditLoaded = 90
    private var findingsLoaded = 30
    private var securityDebounces: [String: Task<Void, Never>] = [:]

    // MARK: Dirty state

    var thresholdDirty: Bool { thresholdSeconds != thresholdLoaded }
    var monitorDirty: Bool { monitorIntervalSeconds != monitorLoaded }
    var auditDirty: Bool { auditRetentionDays != auditLoaded }
    var findingsDirty: Bool { findingsRetentionDays != findingsLoaded }

    // MARK: Loading

    /// Loads every settings domain from the backend in parallel. Keeps
    /// the current content visible on re-entry; shows the loading state
    /// only on first load.
    func refresh() async {
        if phase != .loaded { phase = .loading }
        do {
            async let threshold: Int = CoreBridge.shared.request(
                "get_session_inactivity_threshold", as: Int.self)
            async let paths: [String] = CoreBridge.shared.request(
                "list_watch_paths", as: [String].self)
            async let security: [SecurityConfigEntry] = CoreBridge.shared.request(
                "security_config", as: [SecurityConfigEntry].self)
            let (loadedThreshold, loadedPaths, loadedSecurity) =
                try await (threshold, paths, security)
            apply(threshold: loadedThreshold,
                  paths: loadedPaths,
                  security: loadedSecurity)
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func apply(threshold: Int, paths: [String],
                       security: [SecurityConfigEntry]) {
        thresholdSeconds = threshold
        thresholdLoaded = threshold
        thresholdSave = .idle

        watchedPaths = paths
        watchPathErrors = [:]
        watchAddState = .idle

        let values = Dictionary(uniqueKeysWithValues: security.map { ($0.key, $0.value) })
        let monitor = values[Self.monitorKey].flatMap(Int.init)
        let audit = values[Self.auditKey].flatMap(Int.init)
        let findings = values[Self.findingsKey].flatMap(Int.init)
        monitorIntervalSeconds = monitor ?? 300
        auditRetentionDays = audit ?? 90
        findingsRetentionDays = findings ?? 30
        monitorLoaded = monitorIntervalSeconds
        auditLoaded = auditRetentionDays
        findingsLoaded = findingsRetentionDays
        securitySetKeys = Set(values.keys)
        securitySave = [:]
        securityDebounces.values.forEach { $0.cancel() }
        securityDebounces = [:]
    }

    // MARK: General — session threshold

    func scheduleThresholdSave() {
        thresholdDebounce?.cancel()
        thresholdDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.saveThreshold()
        }
    }

    func saveThreshold() async {
        let value = thresholdSeconds
        guard value != thresholdLoaded else {
            thresholdSave = .idle
            return
        }
        guard Self.thresholdRange.contains(value) else {
            thresholdSave = .failed(
                "Inactivity threshold must be between 60 and 14400 seconds.")
            return
        }
        thresholdSave = .saving
        do {
            try await CoreBridge.shared.call(
                "set_session_inactivity_threshold",
                params: ["threshold_seconds": value])
            thresholdLoaded = value
            thresholdSave = .saved
        } catch {
            thresholdSave = .failed(error.localizedDescription)
        }
    }

    func revertThreshold() {
        thresholdSeconds = thresholdLoaded
        thresholdSave = .idle
    }

    // MARK: Watched paths

    func chooseWatchPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a directory for ContextSphere to watch"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        watchPathInput = url.path
    }

    func addWatchPath() async {
        let path = watchPathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        watchAddState = .saving
        do {
            try await CoreBridge.shared.call("add_watch_path", params: ["path": path])
            watchPathInput = ""
            watchAddState = .saved
            watchedPaths = try await CoreBridge.shared.request(
                "list_watch_paths", as: [String].self)
        } catch {
            watchAddState = .failed(error.localizedDescription)
        }
    }

    func removeWatchPath(_ path: String) async {
        watchPathErrors[path] = nil
        do {
            try await CoreBridge.shared.call("remove_watch_path", params: ["path": path])
            watchedPaths = try await CoreBridge.shared.request(
                "list_watch_paths", as: [String].self)
        } catch {
            watchPathErrors[path] = error.localizedDescription
        }
    }

    // MARK: Security policy

    func scheduleSecuritySave(key: String, value: Int) {
        securityDebounces[key]?.cancel()
        securityDebounces[key] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.saveSecurity(key: key, value: value)
        }
    }

    func saveSecurity(key: String, value: Int) async {
        guard let range = Self.securityRange(for: key), range.contains(value) else {
            securitySave[key] = .failed("Value is outside the allowed range.")
            return
        }
        guard value != loadedValue(for: key) else {
            securitySave[key] = .idle
            return
        }
        securitySave[key] = .saving
        do {
            try await CoreBridge.shared.call(
                "security_set_config",
                params: ["key": key, "value": String(value)])
            switch key {
            case Self.monitorKey: monitorLoaded = value
            case Self.auditKey: auditLoaded = value
            case Self.findingsKey: findingsLoaded = value
            default: break
            }
            securitySave[key] = .saved
            securitySetKeys.insert(key)
        } catch {
            securitySave[key] = .failed(error.localizedDescription)
        }
    }

    func revertSecurity(key: String) {
        switch key {
        case Self.monitorKey: monitorIntervalSeconds = monitorLoaded
        case Self.auditKey: auditRetentionDays = auditLoaded
        case Self.findingsKey: findingsRetentionDays = findingsLoaded
        default: return
        }
        securitySave[key] = .idle
    }

    private func loadedValue(for key: String) -> Int {
        switch key {
        case Self.monitorKey: return monitorLoaded
        case Self.auditKey: return auditLoaded
        case Self.findingsKey: return findingsLoaded
        default: return 0
        }
    }

    private static func securityRange(for key: String) -> ClosedRange<Int>? {
        switch key {
        case Self.monitorKey: return Self.monitorRange
        case Self.auditKey, Self.findingsKey: return Self.retentionRange
        default: return nil
        }
    }
}
