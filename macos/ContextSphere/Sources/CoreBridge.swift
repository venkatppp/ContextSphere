import Foundation

// MARK: - RPC protocol

/// Incoming message from the daemon (stdout is a JSON-RPC stream).
enum RpcIncoming: Decodable {
    case response(id: Int, result: JSONValue?, error: RpcError?)
    case notification(event: String, payload: JSONValue?)

    private enum CodingKeys: String, CodingKey { case id, result, error, event, payload }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.event) {
            self = .notification(event: try c.decode(String.self, forKey: .event),
                                 payload: try c.decodeIfPresent(JSONValue.self, forKey: .payload))
        } else {
            self = .response(id: try c.decode(Int.self, forKey: .id),
                             result: try c.decodeIfPresent(JSONValue.self, forKey: .result),
                             error: try c.decodeIfPresent(RpcError.self, forKey: .error))
        }
    }
}

struct RpcError: Decodable {
    let message: String
}

/// Minimal JSON value tree so raw payloads can be passed through to typed
/// decoders without forcing every request to pre-declare its result type.
enum JSONValue: Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown JSON value")
    }

    func toData() throws -> Data {
        switch self {
        case .null: return Data("null".utf8)
        case .bool(let b): return Data(b ? "true".utf8 : "false".utf8)
        case .number(let n): return Data(String(format: "%.17g", n).utf8)
        case .string(let s): return try JSONSerialization.data(withJSONObject: s)
        case .array(let a): return try JSONSerialization.data(withJSONObject: a.map(\.jsonObject))
        case .object(let o): return try JSONSerialization.data(withJSONObject: o.mapValues(\.jsonObject))
        }
    }

    var jsonObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.jsonObject)
        case .object(let o): return o.mapValues(\.jsonObject)
        }
    }
}

extension JSONValue: Equatable, Hashable {
    /// The object member of a JSON value, or `nil` when not an object.
    var objectValue: [String: JSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case (.bool(let a), .bool(let b)): a == b
        case (.number(let a), .number(let b)): a == b
        case (.string(let a), .string(let b)): a == b
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)): a == b
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let b): hasher.combine(1); hasher.combine(b)
        case .number(let n): hasher.combine(2); hasher.combine(n)
        case .string(let s): hasher.combine(3); hasher.combine(s)
        case .array(let a): hasher.combine(4); hasher.combine(a)
        case .object(let o): hasher.combine(5); hasher.combine(o)
        }
    }
}

// MARK: - Core bridge

/// Spawns the `contextsphere_core` daemon and speaks line-delimited JSON-RPC
/// over its stdin/stdout. Responses are matched to pending requests by id;
/// daemon events arrive as notifications.
///
/// Reliability contract:
/// - every request carries a timeout; timed-out ids never wedge the bridge,
/// - an unexpected daemon exit fails all pending requests and schedules an
///   automatic restart with capped exponential backoff (`isReconnecting`),
/// - after `maxRestartAttempts` consecutive failures the bridge stays
///   offline; `reconnect()` (Command Palette / status footer) retries,
/// - a stable run resets the attempt counter so a one-off crash never
///   exhausts the budget.
@MainActor
final class CoreBridge: ObservableObject {
    static let shared = CoreBridge()

    @Published var isRunning = false
    /// An automatic restart cycle is in progress after a daemon crash.
    @Published private(set) var isReconnecting = false
    @Published var backendVersion: String?
    @Published var lastError: String?

    var onEvent: ((String, Data?) -> Void)?

    /// Default per-request ceiling. Long-running commands (benchmarks)
    /// override this at the call site. `nonisolated` so it can be used
    /// as a default argument value.
    nonisolated static let defaultTimeout: TimeInterval = 60
    private static let maxRestartAttempts = 5
    /// A daemon that stays up this long is considered stable again.
    private static let stabilityWindow: UInt64 = 30_000_000_000

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Data?, Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var buffer = Data()
    private var intentionalStop = false
    private var restartAttempts = 0
    private var stabilityTask: Task<Void, Never>?

    private init() {}

    func start() {
        intentionalStop = false
        spawnDaemon()
    }

    /// User-facing recovery path: restarts the daemon even when the auto
    /// retry budget is exhausted.
    func reconnect() {
        intentionalStop = false
        restartAttempts = 0
        if process != nil {
            // Termination handler respawns via the reconnect path.
            process?.terminate()
            return
        }
        spawnDaemon()
    }

    func stop() {
        intentionalStop = true
        process?.terminate()
    }

    /// Finds the daemon: bundled `Contents/MacOS/contextsphere_core`, else the
    /// `CONTEXTSPHERE_CORE` env override (dev builds use the cargo target dir).
    private func resolveDaemonURL() -> URL {
        if let env = ProcessInfo.processInfo.environment["CONTEXTSPHERE_CORE"] {
            return URL(fileURLWithPath: env)
        }
        let bundle = Bundle.main
        if let bundled = bundle.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("contextsphere_core"),
            FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: "src-tauri/target/debug/contextsphere_core")
    }

    private func spawnDaemon() {
        guard process == nil, !intentionalStop else { return }
        let daemonURL = resolveDaemonURL()
        guard FileManager.default.isExecutableFile(atPath: daemonURL.path) else {
            lastError = "core daemon not found at \(daemonURL.path)"
            isReconnecting = false
            return
        }

        let p = Process()
        p.executableURL = daemonURL
        p.standardInput = Pipe()
        p.standardOutput = Pipe()
        p.standardError = FileHandle.standardError
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.handleTermination() }
        }

        stdinPipe = p.standardInput as? Pipe
        stdoutPipe = p.standardOutput as? Pipe
        stdoutPipe?.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }

        do {
            try p.run()
            process = p
            isRunning = true
            scheduleStabilityReset()
        } catch {
            process = nil
            isRunning = false
            attemptReconnect(reason: "failed to launch daemon: \(error.localizedDescription)")
        }
    }

    private func handleTermination() {
        guard process != nil else { return }
        process = nil
        isRunning = false
        stdinPipe = nil
        stdoutPipe = nil
        buffer.removeAll()
        failAllPending("daemon exited")
        guard !intentionalStop else { return }
        attemptReconnect(reason: "core daemon exited unexpectedly")
    }

    private func attemptReconnect(reason: String) {
        lastError = reason
        guard restartAttempts < Self.maxRestartAttempts else {
            isReconnecting = false
            lastError = "\(reason). Gave up after \(Self.maxRestartAttempts) attempts — use Refresh Core to retry."
            return
        }
        restartAttempts += 1
        isReconnecting = true
        let delay = min(pow(2.0, Double(restartAttempts)), 10)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !self.intentionalStop, self.process == nil else { return }
            self.spawnDaemon()
        }
    }

    private func scheduleStabilityReset() {
        stabilityTask?.cancel()
        stabilityTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.stabilityWindow)
            guard !Task.isCancelled else { return }
            self?.restartAttempts = 0
            self?.isReconnecting = false
        }
    }

    /// Sends a request and decodes the result into `T`. Errors (RPC-level,
    /// decode-level, or timeout) throw `CoreError`.
    func request<T: Decodable>(_ method: String, params: [String: Any] = [:],
                               as type: T.Type,
                               timeout: TimeInterval = CoreBridge.defaultTimeout) async throws -> T {
        let data = try await rawRequest(method, params: params, timeout: timeout)
        guard let data else { throw CoreError.emptyResult }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CoreError.decode("\(method): \(error.localizedDescription)")
        }
    }

    /// Convenience for commands that return no meaningful payload. The
    /// daemon serializes `Ok(())` as a JSON `null` result, which counts
    /// as success here (typed requests still reject it).
    func call(_ method: String, params: [String: Any] = [:],
              timeout: TimeInterval = CoreBridge.defaultTimeout) async throws {
        _ = try await rawRequest(method, params: params, timeout: timeout)
    }

    private func rawRequest(_ method: String, params: [String: Any],
                            timeout: TimeInterval) async throws -> Data? {
        let id = nextId
        nextId += 1
        let payload = try JSONSerialization.data(withJSONObject: [
            "id": id, "method": method, "params": params,
        ])
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            pending[id] = cont
            guard let stdin = stdinPipe?.fileHandleForWriting else {
                pending.removeValue(forKey: id)
                cont.resume(throwing: CoreError.notRunning)
                return
            }
            var line = payload
            line.append(0x0A)
            do {
                try stdin.write(contentsOf: line)
            } catch {
                pending.removeValue(forKey: id)
                cont.resume(throwing: CoreError.transport(error.localizedDescription))
                return
            }
            // Watchdog: a daemon that never answers must not wedge the
            // caller. Canceled when the response arrives first.
            timeoutTasks[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let self, let cont = self.pending.removeValue(forKey: id) else { return }
                self.timeoutTasks.removeValue(forKey: id)
                cont.resume(throwing: CoreError.timeout(method, timeout))
            }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let obj = try? JSONDecoder().decode(RpcIncoming.self, from: line) else {
                let preview = String(data: line.prefix(120), encoding: .utf8) ?? "<binary>"
                lastError = "malformed daemon line dropped: \(preview)"
                continue
            }
            switch obj {
            case .response(let id, let result, let error):
                if let cont = pending.removeValue(forKey: id) {
                    timeoutTasks.removeValue(forKey: id)?.cancel()
                    if let error {
                        cont.resume(throwing: CoreError.rpc(error.message))
                    } else {
                        do {
                            cont.resume(returning: try result?.toData())
                        } catch {
                            cont.resume(throwing: CoreError.decode(error.localizedDescription))
                        }
                    }
                }
            case .notification(let event, let payload):
                do {
                    onEvent?(event, try payload?.toData())
                } catch {
                    lastError = "event \(event) payload serialization failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func failAllPending(_ reason: String) {
        for (_, cont) in pending {
            cont.resume(throwing: CoreError.transport(reason))
        }
        pending.removeAll()
        for (_, task) in timeoutTasks { task.cancel() }
        timeoutTasks.removeAll()
    }
}

enum CoreError: LocalizedError {
    case notRunning
    case transport(String)
    case rpc(String)
    case emptyResult
    case decode(String)
    case timeout(String, TimeInterval)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "core daemon is not running"
        case .transport(let s): return s
        case .rpc(let s): return s
        case .emptyResult: return "empty result"
        case .decode(let s): return s
        case .timeout(let method, let t): return "\(method) timed out after \(Int(t))s"
        }
    }
}
