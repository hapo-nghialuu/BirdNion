import Foundation

/// Minimal JSON-RPC client for the local Codex CLI's `app-server`.
///
/// Hand-ported from CodexBar (used as a **reference only** — BirdNion does not
/// link CodexBarCore). Launches `codex -s read-only -a untrusted app-server`,
/// performs the `initialize` handshake, then reads `account/rateLimits/read`
/// (plus `account/read` for identity). Messages are newline-delimited JSON over
/// the child's stdin/stdout. Calls are bounded by timeouts; on timeout the child
/// is terminated so the stdout reader unwinds instead of hanging a refresh.
///
/// This is the automatic fallback when the OAuth usage call fails. It replaces
/// the old bare-`codex` `/status` PTY scrape, which could start an interactive
/// auth flow and open browser tabs. `CodexStatusProbe` (the PTY parser) is kept
/// for explicit manual diagnostics only.
enum CodexAppServerRPC {
    private static let initializeTimeout: TimeInterval = 8
    private static let requestTimeout: TimeInterval = 3
    private static let arguments = ["-s", "read-only", "-a", "untrusted", "app-server"]

    /// Runs the RPC for the active Codex account and maps the result to
    /// BirdNion's model. Best-effort: returns nil on any failure.
    static func fetch(env: [String: String] = ProcessInfo.processInfo.environment) async -> CodexCLIUsage? {
        guard let binary = CodexAccountStore.codexBinary() else { return nil }
        // After a recent launch failure (e.g. macOS quarantined `codex`), skip
        // background relaunches for a cooldown; a manual refresh bypasses this.
        if CodexCLILaunchGate.shared.shouldSkipLaunch(binary: binary) { return nil }
        var environment = env
        // Scope the RPC to the active account's Codex home (system uses ~/.codex).
        environment["CODEX_HOME"] = CodexAccountStore.activeAuthURL()
            .deletingLastPathComponent().path
        environment["PATH"] = effectivePATH(environment["PATH"])

        let client: Client
        do {
            client = try Client(binary: binary, arguments: arguments, environment: environment)
        } catch {
            CodexCLILaunchGate.shared.recordFailure(binary: binary)
            return nil
        }
        CodexCLILaunchGate.shared.clearFailure(binary: binary)  // launch succeeded
        defer { client.shutdown() }
        do {
            try await client.initialize(timeout: initializeTimeout)
            let limits = try await client.rateLimits(timeout: requestTimeout)
            let account = try? await client.account(timeout: requestTimeout)
            return map(limits: limits, account: account)
        } catch {
            return nil
        }
    }

    /// Prepend the common Homebrew/node locations so `codex` can shell out to
    /// node-based tooling even when launched with a minimal PATH.
    private static func effectivePATH(_ existing: String?) -> String {
        let extras = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let current = (existing ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (extras + current).filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    // MARK: - Mapping

    /// Pure mapping (RPC wire → BirdNion model). Returns nil when there are no
    /// usable rate-limit windows.
    static func map(limits: RateLimitsResponse, account: AccountResponse?) -> CodexCLIUsage? {
        var windows: [QuotaWindow] = []
        if let primary = limits.rateLimits.primary {
            windows.append(window(primary, label: "5 giờ", fallbackSeconds: 5 * 3600))
        }
        if let secondary = limits.rateLimits.secondary {
            windows.append(window(secondary, label: "Tuần", fallbackSeconds: 7 * 24 * 3600))
        }
        guard !windows.isEmpty else { return nil }
        // Plan: prefer the account/read value, fall back to rateLimits.planType.
        let plan = account?.account?.planType ?? limits.rateLimits.planType
        // Credits balance arrives as a string; nil/unlimited stays nil.
        let credits = limits.rateLimits.credits?.balance.flatMap(Double.init)
        return CodexCLIUsage(
            windows: windows,
            planType: plan,
            credits: credits,
            email: account?.account?.email)
    }

    private static func window(_ w: Window, label: String, fallbackSeconds: Int) -> QuotaWindow {
        let used = max(0, min(100, Int(w.usedPercent.rounded())))
        return QuotaWindow(
            label: label,
            usedPct: used,
            remainingPct: 100 - used,
            resetDate: w.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            windowSeconds: w.windowDurationMins.map { $0 * 60 } ?? fallbackSeconds)
    }

    // MARK: - Wire model

    struct RateLimitsResponse: Decodable {
        let rateLimits: Snapshot
        struct Snapshot: Decodable {
            let primary: Window?
            let secondary: Window?
            let credits: Credits?
            let planType: String?
        }
        struct Credits: Decodable {
            let hasCredits: Bool?
            let unlimited: Bool?
            let balance: String?
        }
    }

    struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int?
        let resetsAt: Int?
    }

    struct AccountResponse: Decodable {
        let account: Details?
        struct Details: Decodable {
            let email: String?
            let planType: String?
        }
    }

    enum RPCError: Error {
        case startFailed
        case requestFailed(String)
        case malformed
        case timeout
    }

    /// Box so a `[String: Any]` reply can cross the task-group boundary.
    fileprivate struct SendableBox: @unchecked Sendable {
        let value: [String: Any]
        init(_ v: [String: Any]) { value = v }
    }
}

extension CodexAppServerRPC {
    /// Owns the child `codex app-server` process and the JSON-RPC framing.
    /// `@unchecked Sendable`: confined to the single `fetch` task that creates it.
    final class Client: @unchecked Sendable {
        private let process = Process()
        private let stdinPipe = Pipe()
        private let stdoutPipe = Pipe()
        private let stderrPipe = Pipe()
        private let lineStream: AsyncStream<Data>
        private let lineContinuation: AsyncStream<Data>.Continuation
        private var nextID = 1

        init(binary: String, arguments: [String], environment: [String: String]) throws {
            var continuation: AsyncStream<Data>.Continuation!
            self.lineStream = AsyncStream<Data> { continuation = $0 }
            self.lineContinuation = continuation

            // Launch via `/usr/bin/env` so the child resolves node tooling on PATH.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [binary] + arguments
            process.environment = environment
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let buffer = LineBuffer()
            let cont = lineContinuation
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    cont.finish()
                    return
                }
                for line in buffer.append(data) { cont.yield(line) }
            }
            // Drain stderr so a full pipe never blocks the child.
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                if handle.availableData.isEmpty { handle.readabilityHandler = nil }
            }

            do { try process.run() } catch { throw RPCError.startFailed }
        }

        func initialize(timeout: TimeInterval) async throws {
            _ = try await request(
                method: "initialize",
                params: ["clientInfo": ["name": "BirdNion", "version": "1"]],
                timeout: timeout)
            try sendNotification(method: "initialized")
        }

        func rateLimits(timeout: TimeInterval) async throws -> RateLimitsResponse {
            try decodeResult(from: try await request(method: "account/rateLimits/read", timeout: timeout))
        }

        func account(timeout: TimeInterval) async throws -> AccountResponse {
            try decodeResult(from: try await request(method: "account/read", timeout: timeout))
        }

        func shutdown() {
            if process.isRunning { process.terminate() }
            lineContinuation.finish()
        }

        // MARK: - JSON-RPC

        private func request(method: String,
                             params: [String: Any]? = nil,
                             timeout: TimeInterval) async throws -> [String: Any] {
            let id = nextID
            nextID += 1
            try send(["id": id, "method": method, "params": params ?? [:]])
            let box = try await withTimeout(timeout) { [self] in
                while true {
                    let message = try await readNextMessage()
                    // Skip notifications (no id) and replies to other ids.
                    guard let mid = intID(message["id"]), mid == id else { continue }
                    if let error = message["error"] as? [String: Any] {
                        throw RPCError.requestFailed((error["message"] as? String) ?? "unknown")
                    }
                    return SendableBox(message)
                }
            }
            return box.value
        }

        private func withTimeout<T: Sendable>(
            _ seconds: TimeInterval,
            _ body: @escaping @Sendable () async throws -> T) async throws -> T
        {
            try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await body() }
                group.addTask { [weak self] in
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    self?.terminateForTimeout()
                    throw RPCError.timeout
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw RPCError.timeout }
                return result
            }
        }

        private func terminateForTimeout() {
            if process.isRunning { process.terminate() }
        }

        private func sendNotification(method: String) throws {
            try send(["method": method, "params": [:]])
        }

        private func send(_ payload: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let handle = stdinPipe.fileHandleForWriting
            handle.write(data)
            handle.write(Data([0x0A]))
        }

        private func readNextMessage() async throws -> [String: Any] {
            for await line in lineStream {
                if line.isEmpty { continue }
                if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    return json
                }
            }
            throw RPCError.malformed
        }

        private func decodeResult<T: Decodable>(from message: [String: Any]) throws -> T {
            guard let result = message["result"] else { throw RPCError.malformed }
            let data = try JSONSerialization.data(withJSONObject: result)
            return try JSONDecoder().decode(T.self, from: data)
        }

        private func intID(_ value: Any?) -> Int? {
            switch value {
            case let i as Int: return i
            case let n as NSNumber: return n.intValue
            default: return nil
            }
        }
    }
}

/// Splits a byte stream into newline-delimited frames. Thread-safe: the
/// readability handler fires on a background queue.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        var out: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            out.append(Data(buffer[..<newline]))
            buffer.removeSubrange(...newline)
        }
        return out
    }
}
