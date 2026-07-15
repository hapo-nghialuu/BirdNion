import Darwin
import Foundation

/// Kiro (AWS) quota provider.
///
/// Resolves the usage CLI by scanning PATH + well-known install dirs,
/// preferring `kiro-cli` and skipping the Kiro IDE launcher (see
/// `resolveBinary`). Subcommands (mirrors CodexBar's KiroStatusProbe):
///   - `kiro-cli whoami` — verifies login; parses email + auth method. Runs in
///     parallel with the usage command; its not-logged-in verdict upgrades a
///     usage parse error into a clearer "not logged in" message.
///   - `kiro-cli chat --no-interactive /usage` — usage output with credits %,
///     plan, reset date, bonus credits, overage status/cost.
///   - `kiro-cli chat --no-interactive /context` — context-window breakdown
///     (best-effort; failures are non-fatal).
///   - `kiro-cli --version` — CLI version for the info grid (best-effort).
///
/// Transport: recent Kiro CLIs can keep their TUI alive indefinitely under a
/// PTY even with `--no-interactive`, while older releases emit no output
/// through pipes. So each command prefers plain pipes (with an idle cutoff
/// once output starts) and races a bounded PTY fallback that only spawns when
/// the pipe stays silent past `pipeFallbackCap` or returns unusable output.
/// ANSI codes are stripped before parsing.
final class KiroProvider: QuotaProvider {
    let id = "kiro"
    let displayName = "Kiro"

    private let binaryResolver: () -> String?
    private let usageTimeout: TimeInterval
    private let whoamiTimeout: TimeInterval
    private let contextTimeout: TimeInterval
    /// How long the pipe transport may stay silent before the PTY fallback
    /// spawns (capped at half the command timeout).
    private let pipeFallbackCap: TimeInterval

    init(timeout: TimeInterval = 20) {
        self.usageTimeout = timeout
        self.whoamiTimeout = 3
        self.contextTimeout = 8
        self.pipeFallbackCap = 5
        self.binaryResolver = { KiroProvider.resolveBinary() }
    }

    /// Testable init — inject a custom binary resolver.
    init(binaryResolver: @escaping () -> String?,
         timeout: TimeInterval = 20,
         whoamiTimeout: TimeInterval = 3,
         contextTimeout: TimeInterval = 8,
         pipeFallbackCap: TimeInterval = 5) {
        self.binaryResolver = binaryResolver
        self.usageTimeout = timeout
        self.whoamiTimeout = whoamiTimeout
        self.contextTimeout = contextTimeout
        self.pipeFallbackCap = pipeFallbackCap
    }

    func fetch() async throws -> ProviderStatus {
        do {
            return try await fetchInternal()
        } catch let err as KiroProviderError {
            return failure(err.localizedMessage)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return failure(error.localizedDescription)
        }
    }

    // MARK: - Testing hook

    /// Parse raw CLI text (post ANSI-strip) into ProviderStatus (for unit tests).
    static func _parseForTesting(usageOutput: String,
                                 whoamiOutput: String?,
                                 contextOutput: String? = nil,
                                 version: String? = nil) -> ProviderStatus {
        let account = whoamiOutput.map { parseWhoami(stripANSI($0)) }
        let context = contextOutput.flatMap { parseContextUsage(stripANSI($0)) }
        do {
            return try parseUsage(
                stripped: stripANSI(usageOutput),
                accountEmail: account?.email,
                authMethod: account?.authMethod,
                contextUsage: context,
                version: version)
        } catch let err as KiroProviderError {
            return ProviderStatus(id: "kiro", displayName: "Kiro", windows: [],
                                  lastUpdated: Date(), error: err.localizedMessage)
        } catch {
            return ProviderStatus(id: "kiro", displayName: "Kiro", windows: [],
                                  lastUpdated: Date(), error: error.localizedDescription)
        }
    }

    // MARK: - Core fetch

    private enum AccountProbe: Equatable {
        case account(email: String?, authMethod: String?)
        case notLoggedIn
        case unavailable

        var email: String? {
            if case let .account(email, _) = self { return email }
            return nil
        }

        var authMethod: String? {
            if case let .account(_, method) = self { return method }
            return nil
        }
    }

    private func fetchInternal() async throws -> ProviderStatus {
        guard let binary = binaryResolver() else {
            throw KiroProviderError.binaryNotFound
        }

        // whoami + version run concurrently with the usage command.
        let accountTask = Task { await self.fetchAccount(binary: binary) }
        let versionTask = Task.detached(priority: .utility) { Self.cachedVersion(binary: binary) }

        let usageResult: KiroCLIResult
        do {
            usageResult = try await runCommand(
                binary: binary, arguments: ["chat", "--no-interactive", "/usage"],
                timeout: usageTimeout, idleTimeout: 4.0, kind: .usage)
        } catch is CancellationError {
            accountTask.cancel()
            versionTask.cancel()
            throw CancellationError()
        } catch {
            versionTask.cancel()
            // A silent/failed usage probe on a logged-out CLI should read as
            // "not logged in", not as a timeout.
            if await accountTask.value == .notLoggedIn {
                throw KiroProviderError.notLoggedIn
            }
            throw error
        }

        let usageOut = usageResult.output
        if Self.isLoginRequired(usageOut) {
            accountTask.cancel()
            versionTask.cancel()
            throw KiroProviderError.notLoggedIn
        }
        let strippedUsage = Self.stripANSI(usageOut)
        try Self.validateCompletion(
            usageResult, command: "usage",
            allowIdleOutput: Self.usageLooksParseable(strippedUsage))

        // Context breakdown is best-effort; never fails the fetch.
        let contextUsage = await fetchContext(binary: binary)

        let account = await accountTask.value
        let version = await versionTask.value

        do {
            return try Self.parseUsage(
                stripped: strippedUsage,
                accountEmail: account.email,
                authMethod: account.authMethod,
                contextUsage: contextUsage,
                version: version)
        } catch KiroProviderError.parseError where account == .notLoggedIn {
            throw KiroProviderError.notLoggedIn
        }
    }

    private func fetchAccount(binary: String) async -> AccountProbe {
        do {
            let result = try await runCommand(
                binary: binary, arguments: ["whoami"],
                timeout: whoamiTimeout, idleTimeout: 1.5, kind: .whoami)
            let output = result.output
            if Self.isLoginRequired(output) { return .notLoggedIn }
            if result.stoppedAfterOutput { return .unavailable }
            guard result.terminationStatus == 0,
                  !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return .unavailable }
            let info = Self.parseWhoami(Self.stripANSI(output))
            return .account(email: info.email, authMethod: info.authMethod)
        } catch {
            return .unavailable
        }
    }

    private func fetchContext(binary: String) async -> KiroContextUsage? {
        guard let result = try? await runCommand(
            binary: binary, arguments: ["chat", "--no-interactive", "/context"],
            timeout: contextTimeout, idleTimeout: 3.0, kind: .context)
        else { return nil }
        return Self.parseContextUsage(Self.stripANSI(result.output))
    }

    // MARK: - CLI transport (pipe + bounded PTY fallback)

    struct KiroCLIResult: Sendable {
        let stdout: String
        let stderr: String
        let terminationStatus: Int32
        /// The process was cut off by the idle/deadline watchdog after it had
        /// produced output — the text is usable but the exit status is not.
        let stoppedAfterOutput: Bool

        var output: String {
            let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    private enum CommandKind { case whoami, usage, context }

    private enum TransportOutcome: Sendable {
        case result(KiroCLIResult)
        case failure(KiroProviderError)
        case cancelled
    }

    private enum TransportEvent: Sendable {
        case pipe(TransportOutcome)
        case pty(TransportOutcome)
        case fallbackReady
    }

    /// Marks pipe output activity across tasks (drives idle cutoff + decides
    /// whether the PTY fallback is needed).
    private final class PipeActivity: @unchecked Sendable {
        private let lock = NSLock()
        private var lastActivity = Date()
        private var receivedOutput = false

        var lastActivityAt: Date { lock.withLock { lastActivity } }
        var hasReceivedOutput: Bool { lock.withLock { receivedOutput } }

        func markActivity() {
            lock.withLock {
                lastActivity = Date()
                receivedOutput = true
            }
        }
    }

    /// Lets the async race cancel the synchronous PTY loop running in a
    /// detached task (Task cancellation does not propagate into it).
    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    /// Runs a kiro-cli subcommand: pipe transport first; a PTY fallback spawns
    /// when the pipe stays silent past `pipeFallbackCap` or finishes with
    /// unusable output, all bounded by one shared deadline.
    private func runCommand(binary: String, arguments: [String],
                            timeout: TimeInterval, idleTimeout: TimeInterval,
                            kind: CommandKind) async throws -> KiroCLIResult {
        let deadline = Date().addingTimeInterval(timeout)
        let fallbackDelay = min(max(0, pipeFallbackCap), max(0, timeout / 2))
        let activity = PipeActivity()
        let ptyCancel = CancellationFlag()

        return try await withThrowingTaskGroup(of: TransportEvent.self) { group in
            defer {
                ptyCancel.cancel()
                group.cancelAll()
            }
            group.addTask {
                await .pipe(Self.pipeOutcome(
                    binary: binary, arguments: arguments,
                    timeout: timeout, idleTimeout: idleTimeout, activity: activity))
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(fallbackDelay * 1_000_000_000))
                return .fallbackReady
            }

            func startPTY() {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return }
                group.addTask {
                    await .pty(Self.ptyOutcome(
                        binary: binary, arguments: arguments,
                        timeout: remaining, idleTimeout: min(idleTimeout, remaining),
                        cancel: ptyCancel))
                }
            }

            var ptyStarted = false
            var pipeDoneUnaccepted = false
            var pendingPTY: TransportOutcome?

            while let event = try await group.next() {
                try Task.checkCancellation()
                switch event {
                case .fallbackReady:
                    // Only fall back when the pipe has stayed completely silent.
                    guard !ptyStarted, !activity.hasReceivedOutput,
                          deadline.timeIntervalSinceNow > 0 else { continue }
                    ptyStarted = true
                    startPTY()

                case let .pipe(.result(result)):
                    if try shouldReturnPipeResult(result, kind: kind, deadline: deadline) {
                        return result
                    }
                    pipeDoneUnaccepted = true
                    if let pending = try Self.resolvePending(pendingPTY, deadline: deadline) {
                        return pending
                    }
                    if !ptyStarted {
                        guard deadline.timeIntervalSinceNow > 0 else { throw KiroProviderError.timeout }
                        ptyStarted = true
                        startPTY()
                    }

                case .pipe(.failure(.timeout)):
                    pipeDoneUnaccepted = true
                    if let pending = try Self.resolvePending(pendingPTY, deadline: deadline) {
                        return pending
                    }

                case let .pipe(.failure(error)):
                    throw error

                case .pipe(.cancelled), .pty(.cancelled):
                    throw CancellationError()

                case let .pty(.result(result)):
                    guard acceptPTYResult(result, kind: kind) else {
                        if pipeDoneUnaccepted {
                            guard Date() <= deadline else { throw KiroProviderError.timeout }
                            return result
                        }
                        pendingPTY = .result(result)
                        continue
                    }
                    guard Date() <= deadline else { throw KiroProviderError.timeout }
                    return result

                case let .pty(.failure(error)):
                    if pipeDoneUnaccepted { throw error }
                    pendingPTY = .failure(error)
                }
            }
            if let pending = try Self.resolvePending(pendingPTY, deadline: deadline) {
                return pending
            }
            throw KiroProviderError.timeout
        }
    }

    private static func resolvePending(_ pending: TransportOutcome?,
                                       deadline: Date) throws -> KiroCLIResult? {
        guard let pending else { return nil }
        guard Date() <= deadline else { throw KiroProviderError.timeout }
        switch pending {
        case let .result(result): return result
        case let .failure(error): throw error
        case .cancelled: throw CancellationError()
        }
    }

    /// A pipe result is usable when it is a definitive login prompt or when the
    /// command's parser recognises it.
    private func acceptPipeResult(_ result: KiroCLIResult, kind: CommandKind) -> Bool {
        let output = result.output
        if Self.isLoginRequired(output) { return true }
        switch kind {
        case .whoami:
            let info = Self.parseWhoami(Self.stripANSI(output))
            return info.email != nil || info.authMethod != nil
        case .usage:
            return Self.usageLooksParseable(Self.stripANSI(output))
        case .context:
            if Self.parseContextUsage(Self.stripANSI(output)) != nil { return true }
            // A clean, silent exit is a valid "no context yet" answer.
            return result.terminationStatus == 0 && !result.stoppedAfterOutput && output.isEmpty
        }
    }

    private func shouldReturnPipeResult(_ result: KiroCLIResult, kind: CommandKind,
                                        deadline: Date) throws -> Bool {
        guard acceptPipeResult(result, kind: kind) else { return false }
        if !Self.isLoginRequired(result.output), Date() > deadline {
            throw KiroProviderError.timeout
        }
        return true
    }

    private func acceptPTYResult(_ result: KiroCLIResult, kind: CommandKind) -> Bool {
        if Self.isLoginRequired(result.output) { return true }
        return result.terminationStatus == 0 && acceptPipeResult(result, kind: kind)
    }

    private static func pipeOutcome(binary: String, arguments: [String],
                                    timeout: TimeInterval, idleTimeout: TimeInterval,
                                    activity: PipeActivity) async -> TransportOutcome {
        do {
            return try await .result(runViaPipe(
                binary: binary, arguments: arguments,
                timeout: timeout, idleTimeout: idleTimeout, activity: activity))
        } catch is CancellationError {
            return .cancelled
        } catch let error as KiroProviderError {
            return .failure(error)
        } catch {
            return .failure(.cliFailed(error.localizedDescription))
        }
    }

    private static func ptyOutcome(binary: String, arguments: [String],
                                   timeout: TimeInterval, idleTimeout: TimeInterval,
                                   cancel: CancellationFlag) async -> TransportOutcome {
        let task = Task.detached(priority: .userInitiated) {
            try runViaPTY(binary: binary, arguments: arguments,
                          timeout: timeout, idleTimeout: idleTimeout, cancel: cancel)
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                cancel.cancel()
            }
            return .result(result)
        } catch is CancellationError {
            return .cancelled
        } catch let error as KiroProviderError {
            return .failure(error)
        } catch {
            return .failure(.cliFailed(error.localizedDescription))
        }
    }

    /// Pipe transport: non-blocking reads with a 100ms poll; cuts off after
    /// `idleTimeout` of silence once output has started, or at the deadline.
    private static func runViaPipe(binary: String, arguments: [String],
                                   timeout: TimeInterval, idleTimeout: TimeInterval,
                                   activity: PipeActivity) async throws -> KiroCLIResult {
        let outPipe = Pipe()
        let errPipe = Pipe()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = arguments
        // Pass TERM so interactive prompts don't stall
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        proc.environment = env
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            throw KiroProviderError.cliFailed("Không khởi động được kiro-cli: \(error.localizedDescription)")
        }

        // Move to a process group so we can kill all descendants
        let pid = proc.processIdentifier
        let pgid: pid_t? = (setpgid(pid, pid) == 0) ? pid : nil
        let outFD = outPipe.fileHandleForReading.fileDescriptor
        let errFD = errPipe.fileHandleForReading.fileDescriptor
        _ = fcntl(outFD, F_SETFL, O_NONBLOCK)
        _ = fcntl(errFD, F_SETFL, O_NONBLOCK)

        var stdoutData = Data()
        var stderrData = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var stoppedAfterOutput = false

        func drain() {
            readAvailable(outFD, into: &stdoutData, activity: activity)
            readAvailable(errFD, into: &stderrData, activity: activity)
        }

        do {
            while proc.isRunning {
                try Task.checkCancellation()
                drain()
                let now = Date()
                if now >= deadline {
                    stoppedAfterOutput = true
                    break
                }
                if activity.hasReceivedOutput,
                   now.timeIntervalSince(activity.lastActivityAt) >= max(0, idleTimeout) {
                    stoppedAfterOutput = true
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            terminateGroup(pgid: pgid, proc: proc)
            throw error
        }

        if proc.isRunning {
            terminateGroup(pgid: pgid, proc: proc)
            guard !proc.isRunning else { throw KiroProviderError.timeout }
            guard activity.hasReceivedOutput else { throw KiroProviderError.timeout }
        }
        drain()

        return KiroCLIResult(
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self),
            terminationStatus: proc.terminationStatus,
            stoppedAfterOutput: stoppedAfterOutput)
    }

    /// PTY transport for older Kiro CLIs that emit nothing through plain
    /// pipes. One-shot: spawn on a pseudo-terminal, capture until natural
    /// exit / idle cutoff / deadline, kill the process group on the way out.
    private static func runViaPTY(binary: String, arguments: [String],
                                  timeout: TimeInterval, idleTimeout: TimeInterval,
                                  cancel: CancellationFlag) throws -> KiroCLIResult {
        var pFD: Int32 = -1
        var sFD: Int32 = -1
        var win = winsize(ws_row: 50, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&pFD, &sFD, nil, nil, &win) == 0 else {
            throw KiroProviderError.cliFailed("openpty failed: \(String(cString: strerror(errno)))")
        }
        _ = fcntl(pFD, F_SETFL, O_NONBLOCK)
        let pHandle = FileHandle(fileDescriptor: pFD, closeOnDealloc: true)
        let sHandle = FileHandle(fileDescriptor: sFD, closeOnDealloc: true)
        defer {
            try? pHandle.close()
            try? sHandle.close()
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        proc.environment = env
        proc.standardInput = sHandle
        proc.standardOutput = sHandle
        proc.standardError = sHandle

        do {
            try proc.run()
        } catch {
            throw KiroProviderError.cliFailed("Không khởi động được kiro-cli: \(error.localizedDescription)")
        }
        let pid = proc.processIdentifier
        let pgid: pid_t? = (setpgid(pid, pid) == 0) ? pid : nil

        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var lastOutput = Date()
        var exitedNaturally = false
        var stoppedForIdle = false

        while true {
            if cancel.isCancelled {
                terminateGroup(pgid: pgid, proc: proc)
                throw CancellationError()
            }
            var chunk = Data()
            readAvailable(pFD, into: &chunk, activity: nil)
            if !chunk.isEmpty {
                buffer.append(chunk)
                lastOutput = Date()
            }
            if !proc.isRunning {
                exitedNaturally = true
                var final = Data()
                readAvailable(pFD, into: &final, activity: nil)
                buffer.append(final)
                break
            }
            let now = Date()
            if now >= deadline { break }
            if !buffer.isEmpty, now.timeIntervalSince(lastOutput) >= max(0, idleTimeout) {
                stoppedForIdle = true
                break
            }
            usleep(50_000)
        }

        if proc.isRunning {
            terminateGroup(pgid: pgid, proc: proc)
        }
        if stoppedForIdle {
            return KiroCLIResult(
                stdout: String(decoding: buffer, as: UTF8.self),
                stderr: "", terminationStatus: 0, stoppedAfterOutput: true)
        }
        guard exitedNaturally else { throw KiroProviderError.timeout }
        return KiroCLIResult(
            stdout: String(decoding: buffer, as: UTF8.self),
            stderr: "", terminationStatus: proc.terminationStatus,
            stoppedAfterOutput: false)
    }

    /// Non-blocking read of everything currently available on `fd`.
    private static func readAvailable(_ fd: Int32, into buffer: inout Data,
                                      activity: PipeActivity?) {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { break }
            buffer.append(buf, count: n)
            activity?.markActivity()
        }
    }

    private static func terminateGroup(pgid: pid_t?, proc: Process) {
        if let g = pgid {
            killpg(g, SIGTERM)
        } else {
            proc.terminate()
        }
        Thread.sleep(forTimeInterval: 0.2)
        if proc.isRunning {
            if let g = pgid { killpg(g, SIGKILL) } else { proc.terminate() }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// An idle-stopped result is fine when the parser already understands it;
    /// a naturally-exited result must have exit code 0.
    static func validateCompletion(_ result: KiroCLIResult, command: String,
                                   allowIdleOutput: Bool) throws {
        if result.stoppedAfterOutput {
            guard allowIdleOutput else { throw KiroProviderError.timeout }
            return
        }
        guard result.terminationStatus == 0 else {
            let message = stripANSI(result.output).trimmingCharacters(in: .whitespacesAndNewlines)
            throw KiroProviderError.cliFailed(
                message.isEmpty
                    ? "kiro-cli \(command) thoát với code \(result.terminationStatus)"
                    : message)
        }
    }

    // MARK: - Binary resolution + version

    /// Resolves the Kiro usage CLI for both Terminal and GUI launches.
    ///
    /// macOS menu-bar apps inherit a thin PATH (no shell profile), so
    /// `which kiro-cli` alone misses installs under `~/.local/bin`. Scan PATH
    /// plus well-known dirs, prefer `kiro-cli` over `kiro`, and skip the IDE
    /// launcher (`/usr/local/bin/kiro` → `Kiro.app/.../bin/code`).
    static func resolveBinary(
        home: String = NSHomeDirectory(),
        pathEnv: String? = ProcessInfo.processInfo.environment["PATH"],
        fileManager: FileManager = .default
    ) -> String? {
        var dirs: [String] = []
        if let pathEnv {
            dirs += pathEnv.split(separator: ":").map(String.init)
        }
        // Always include install locations that shell profiles usually add.
        dirs += [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        var seen = Set<String>()
        let uniqueDirs = dirs.filter { !$0.isEmpty && seen.insert($0).inserted }

        // Prefer kiro-cli (usage tool) over kiro (often the IDE shim).
        for name in ["kiro-cli", "kiro"] {
            for dir in uniqueDirs {
                let candidate = (dir as NSString).appendingPathComponent(name)
                if isUsableCLI(at: candidate, fileManager: fileManager) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// True when `path` is an executable usage CLI, not the Kiro IDE launcher.
    static func isUsableCLI(at path: String, fileManager: FileManager = .default) -> Bool {
        guard fileManager.isExecutableFile(atPath: path) else { return false }
        let resolved = (path as NSString).resolvingSymlinksInPath
        // VS Code-style shim lives under Kiro.app and cannot run /usage.
        if resolved.contains("Kiro.app") { return false }
        return true
    }

    /// Version rarely changes between refreshes — probe each binary path once
    /// per app run instead of spawning `--version` on every fetch cycle.
    private static let versionCacheLock = NSLock()
    private static var versionCache: [String: String?] = [:]

    static func cachedVersion(binary: String) -> String? {
        versionCacheLock.lock()
        if let hit = versionCache[binary] {
            versionCacheLock.unlock()
            return hit
        }
        versionCacheLock.unlock()
        let detected = detectVersion(binary: binary)
        versionCacheLock.lock()
        versionCache[binary] = detected
        versionCacheLock.unlock()
        return detected
    }

    /// Runs `kiro-cli --version` (5s, best-effort) and strips the binary-name
    /// prefix, mirroring CodexBar's `KiroStatusProbe.detectVersion`.
    static func detectVersion(binary: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.standardInput = FileHandle.nullDevice
        let sem = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in sem.signal() }
        do { try proc.run() } catch { return nil }
        guard sem.wait(timeout: .now() + 5) == .success else {
            proc.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let line = stripANSI(text)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        guard let line else { return nil }
        return parseVersionOutput(line)
    }

    /// "kiro-cli 1.23.1" → "1.23.1"; anything else passes through.
    static func parseVersionOutput(_ line: String) -> String {
        line.hasPrefix("kiro-cli ") ? String(line.dropFirst("kiro-cli ".count)) : line
    }

    // MARK: - ANSI stripping

    /// Strips ANSI CSI and OSC escape sequences from CLI output.
    static func stripANSI(_ text: String) -> String {
        // Pattern covers CSI (ESC[ ... letter) and block/box drawing sequences
        guard let regex = try? NSRegularExpression(pattern: #"\x1B\[[0-9;?]*[A-Za-z]|\x1B\].*?\x07"#) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    // MARK: - Parsing

    static func isLoginRequired(_ output: String) -> Bool {
        let lowered = stripANSI(output).lowercased()
        return lowered.contains("not logged in")
            || lowered.contains("login required")
            || lowered.contains("failed to initialize auth portal")
            || lowered.contains("kiro-cli login")
            || lowered.contains("oauth error")
    }

    /// Parses whoami output for email + auth method ("Logged in with X").
    static func parseWhoami(_ stripped: String) -> (email: String?, authMethod: String?) {
        var email: String?
        var authMethod: String?
        for line in stripped.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if t.localizedCaseInsensitiveContains("logged in with") {
                let val = t.replacingOccurrences(
                    of: #"(?i)^\s*logged in with\s+"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !val.isEmpty { authMethod = val }
            } else if t.localizedCaseInsensitiveContains("email:") {
                let val = t.replacingOccurrences(
                    of: #"(?i)^\s*email:\s*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !val.isEmpty { email = val }
            } else if email == nil, t.contains("@"), !t.contains(" ") {
                email = t
            }
        }
        return (email, authMethod)
    }

    /// Context-window breakdown parsed from `/context` output.
    struct KiroContextUsage: Equatable {
        let totalPercentUsed: Double
        let contextFilesPercent: Double?
        let toolsPercent: Double?
        let kiroResponsesPercent: Double?
        let promptsPercent: Double?
    }

    /// "Context window: 12.5% used" + optional per-category percents.
    static func parseContextUsage(_ stripped: String) -> KiroContextUsage? {
        guard let total = firstCapture(
            in: stripped,
            pattern: #"(?i)Context window:\s*(\d+\.?\d*)%\s+used"#).flatMap(Double.init)
        else { return nil }
        return KiroContextUsage(
            totalPercentUsed: total,
            contextFilesPercent: percent(after: "Context files", in: stripped),
            toolsPercent: percent(after: "Tools", in: stripped),
            kiroResponsesPercent: percent(after: "Kiro responses", in: stripped),
            promptsPercent: percent(after: "Your prompts", in: stripped))
    }

    private static func percent(after label: String, in text: String) -> Double? {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        return firstCapture(in: text, pattern: #"(?i)"# + escaped + #"\s+(\d+\.?\d*)%"#)
            .flatMap(Double.init)
    }

    /// Cheap "would parseUsage succeed?" probe used by the transport layer to
    /// judge whether a cut-off output is already usable.
    static func usageLooksParseable(_ stripped: String) -> Bool {
        (try? parseUsage(stripped: stripped, accountEmail: nil, authMethod: nil,
                         contextUsage: nil, version: nil)) != nil
    }

    /// Main parse from stripped usage output → ProviderStatus.
    /// Mirrors KiroStatusProbe parsing logic (regex-based).
    static func parseUsage(stripped: String,
                           accountEmail: String?,
                           authMethod: String? = nil,
                           contextUsage: KiroContextUsage? = nil,
                           version: String? = nil) throws -> ProviderStatus {
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KiroProviderError.parseError("Output trống từ kiro-cli")
        }

        if trimmed.lowercased().contains("could not retrieve usage information") {
            throw KiroProviderError.parseError("kiro-cli không lấy được thông tin usage")
        }

        // -- Plan name --
        let planName = displayPlanName(parsePlanName(from: stripped))

        // -- Reset date --
        let resetDate = parseResetDate(from: stripped)

        // -- Credits percentage from "████ X%" --
        var creditsPercent: Double = 0
        var matchedPercent = false
        if let percentMatch = stripped.range(of: #"█+\s*(\d+)%"#, options: .regularExpression) {
            let seg = String(stripped[percentMatch])
            if let numMatch = seg.range(of: #"\d+"#, options: .regularExpression) {
                creditsPercent = Double(String(seg[numMatch])) ?? 0
                matchedPercent = true
            }
        }

        // -- Credits used/total from "(X.XX of Y covered in plan)" --
        var creditsUsed: Double = 0
        var creditsTotal: Double = 50
        var matchedCredits = false
        if let creditsMatch = stripped.range(of: #"\((\d+\.?\d*)\s+of\s+(\d+)\s+covered"#, options: .regularExpression) {
            let seg = String(stripped[creditsMatch])
            let nums = extractNumbers(seg)
            if nums.count >= 2 {
                creditsUsed = nums[0]
                creditsTotal = nums[1]
                matchedCredits = true
            }
        }
        if !matchedPercent, matchedCredits, creditsTotal > 0 {
            creditsPercent = (creditsUsed / creditsTotal) * 100.0
        }

        // -- Bonus credits + overage (parsed for every plan shape) --
        let bonus = parseBonusCredits(from: stripped)
        let overagesStatus = firstCapture(in: stripped, pattern: #"(?i)Overages:\s*([^\n]+)"#)
            .map { stripANSI($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let overageCreditsUsed = firstCapture(in: stripped, pattern: #"(?i)Credits used:\s*(\d+\.?\d*)"#).flatMap(Double.init)
        let overageCostUSD = firstCapture(in: stripped, pattern: #"(?i)Est\.\s*cost:\s*\$?(\d+\.?\d*)\s*USD"#).flatMap(Double.init)
        let manageURL = firstCapture(in: stripped, pattern: #"https://app\.kiro\.dev/account/usage"#)

        // -- Managed plan with no usage (e.g. "Managed by Admin") --
        let isManagedPlan = stripped.lowercased().contains("managed by admin")
            || stripped.lowercased().contains("managed by organization")
        let isNewFormat = firstCapture(in: stripped, pattern: #"Plan:[ \t]*(.+)"#) != nil
        if isNewFormat, isManagedPlan, !matchedPercent, !matchedCredits {
            // Managed plans hide plan credits but may still report bonus and
            // overage — keep those windows instead of dropping them.
            var windows = [QuotaWindow(label: "Credits", usedPct: 0, remainingPct: 100)]
            if let w = bonusWindow(bonus) { windows.append(w) }
            if let w = overageWindow(status: overagesStatus, creditsUsed: overageCreditsUsed,
                                     costUSD: overageCostUSD) { windows.append(w) }
            let kiroMenu = KiroMenuUsage(
                primaryRemainingPct: 100,
                overageCreditsUsed: overageCreditsUsed,
                overageCostUSD: overageCostUSD,
                overagesStatus: overagesStatus,
                contextPercentUsed: contextUsage?.totalPercentUsed,
                contextFilesPercent: contextUsage?.contextFilesPercent,
                contextToolsPercent: contextUsage?.toolsPercent,
                contextResponsesPercent: contextUsage?.kiroResponsesPercent,
                contextPromptsPercent: contextUsage?.promptsPercent)
            return ProviderStatus(
                id: "kiro", displayName: "Kiro",
                windows: windows, lastUpdated: Date(), error: nil,
                accountLabel: accountEmail, version: version,
                planName: planName, sourceLabel: authMethod, kiroMenu: kiroMenu)
        }

        guard matchedPercent || matchedCredits else {
            throw KiroProviderError.parseError("Không tìm thấy thông tin usage trong output kiro-cli")
        }

        let usedPct = max(0, min(100, Int(creditsPercent.rounded())))
        let remainingPct = 100 - usedPct

        // Subtitle: "X.XX / Y credits"; add a manage hint once credits run out.
        var subtitle: String? = matchedCredits
            ? String(format: "%.2f / %.0f credits", creditsUsed, creditsTotal)
            : nil
        if remainingPct == 0, manageURL != nil {
            subtitle = [subtitle, "Nâng cấp tại app.kiro.dev"].compactMap { $0 }.joined(separator: " · ")
        }

        let creditsWindow = QuotaWindow(
            label: "Credits",
            usedPct: usedPct,
            remainingPct: remainingPct,
            subtitle: subtitle,
            resetDate: resetDate)

        var windows: [QuotaWindow] = [creditsWindow]
        if let w = bonusWindow(bonus) { windows.append(w) }
        if let w = overageWindow(status: overagesStatus, creditsUsed: overageCreditsUsed,
                                 costUSD: overageCostUSD) { windows.append(w) }

        // Structured payload for the menu-bar display-mode picker + info grid.
        let kiroMenu = KiroMenuUsage(
            creditsRemaining: creditsTotal - creditsUsed,
            creditsUsed: matchedCredits ? creditsUsed : nil,
            creditsTotal: matchedCredits ? creditsTotal : nil,
            primaryRemainingPct: remainingPct,
            overageCreditsUsed: overageCreditsUsed,
            overageCostUSD: overageCostUSD,
            overagesStatus: overagesStatus,
            contextPercentUsed: contextUsage?.totalPercentUsed,
            contextFilesPercent: contextUsage?.contextFilesPercent,
            contextToolsPercent: contextUsage?.toolsPercent,
            contextResponsesPercent: contextUsage?.kiroResponsesPercent,
            contextPromptsPercent: contextUsage?.promptsPercent)

        return ProviderStatus(
            id: "kiro", displayName: "Kiro",
            windows: windows, lastUpdated: Date(), error: nil,
            accountLabel: accountEmail,
            creditsRemaining: creditsTotal - creditsUsed,
            version: version,
            planName: planName,
            sourceLabel: authMethod,
            kiroMenu: kiroMenu)
    }

    // MARK: - Window builders

    private static func bonusWindow(_ bonus: (used: Double, total: Double, expiryDays: Int?)?) -> QuotaWindow? {
        guard let bonus else { return nil }
        let bonusUsedPct = bonus.total > 0
            ? max(0, min(100, Int((bonus.used / bonus.total * 100).rounded())))
            : 0
        let bonusExpiry: Date? = bonus.expiryDays.flatMap {
            Calendar.current.date(byAdding: .day, value: $0, to: Date())
        }
        return QuotaWindow(
            label: "Bonus Credits",
            usedPct: bonusUsedPct,
            remainingPct: 100 - bonusUsedPct,
            subtitle: String(format: "%.2f / %.0f bonus", bonus.used, bonus.total),
            resetDate: bonusExpiry)
    }

    /// Overage window — shown when the plan reports pay-as-you-go usage or an
    /// explicit Overages status line (Enabled/Disabled).
    private static func overageWindow(status: String?, creditsUsed: Double?,
                                      costUSD: Double?) -> QuotaWindow? {
        guard status != nil || creditsUsed != nil || costUSD != nil else { return nil }
        var parts: [String] = []
        if let u = creditsUsed { parts.append(String(format: "%.2f credits", u)) }
        if let c = costUSD { parts.append(String(format: "~$%.2f", c)) }
        let subtitle = parts.isEmpty ? (status ?? "Đang bật") : parts.joined(separator: " · ")
        return QuotaWindow(label: "Vượt hạn mức", usedPct: 0, remainingPct: 100, subtitle: subtitle)
    }

    // MARK: - Parse helpers

    private static func parsePlanName(from text: String) -> String {
        // New format: "Plan: Q Developer Pro"
        if let cap = firstCapture(in: text, pattern: #"Plan:[ \t]*(.+)"#) {
            let line = cap.components(separatedBy: "\n").first ?? cap
            let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }
        // kiro-cli 2.x: "Estimated Usage | resets on 2026-06-01 | KIRO FREE"
        if let m = text.range(of: #"Estimated Usage[ \t]*\|[^\n|]*\|[ \t]*([A-Z][A-Z0-9 ]+)"#, options: .regularExpression) {
            let line = String(text[m])
            if let plan = line.split(separator: "|").last?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty {
                return plan
            }
        }
        // Legacy: "| KIRO FREE"
        if let m = text.range(of: #"\|[ \t]*(KIRO[ \t]+\w+)"#, options: .regularExpression) {
            return String(text[m]).replacingOccurrences(of: "|", with: "").trimmingCharacters(in: .whitespaces)
        }
        return "Kiro"
    }

    /// Whitespace-collapsed display form; KIRO-branded names get title-cased
    /// ("KIRO  FREE" → "Kiro Free"), others pass through cleaned.
    static func displayPlanName(_ planName: String) -> String {
        let cleaned = stripANSI(planName)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.localizedCaseInsensitiveContains("KIRO") else {
            return cleaned.isEmpty ? planName : cleaned
        }
        return cleaned.split(separator: " ").map { word in
            if word.caseInsensitiveCompare("KIRO") == .orderedSame { return "Kiro" }
            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    private static func parseResetDate(from text: String) -> Date? {
        // "resets on YYYY-MM-DD" or "resets on MM/DD"
        guard let m = text.range(of: #"resets on (\d{4}-\d{2}-\d{2}|\d{2}/\d{2})"#, options: .regularExpression) else {
            return nil
        }
        let seg = String(text[m])
        guard let dateRange = seg.range(of: #"\d{4}-\d{2}-\d{2}|\d{2}/\d{2}"#, options: .regularExpression) else {
            return nil
        }
        return parseDateString(String(seg[dateRange]))
    }

    private static func parseDateString(_ s: String) -> Date? {
        if s.contains("-") {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            f.dateFormat = "yyyy-MM-dd"
            return f.date(from: s)
        }
        // MM/DD — assume current or next year
        let parts = s.split(separator: "/")
        guard parts.count == 2,
              let month = Int(parts[0]), let day = Int(parts[1]) else { return nil }
        let cal = Calendar.current
        let now = Date()
        var comps = DateComponents()
        comps.month = month; comps.day = day
        comps.year = cal.component(.year, from: now)
        if let d = cal.date(from: comps), d > now { return d }
        comps.year = (comps.year ?? 0) + 1
        return cal.date(from: comps)
    }

    private static func parseBonusCredits(from text: String) -> (used: Double, total: Double, expiryDays: Int?)? {
        guard let m = text.range(of: #"Bonus credits:\s*(\d+\.?\d*)/(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let seg = String(text[m])
        let nums = extractNumbers(seg)
        guard nums.count >= 2 else { return nil }
        var expiry: Int?
        if let em = text.range(of: #"expires in (\d+) days?"#, options: .regularExpression) {
            let eseg = String(text[em])
            if let nm = eseg.range(of: #"\d+"#, options: .regularExpression) {
                expiry = Int(String(eseg[nm]))
            }
        }
        return (nums[0], nums[1], expiry)
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range(at: match.numberOfRanges > 1 ? 1 : 0), in: text)
        else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractNumbers(_ text: String) -> [Double] {
        // Extracts all decimal numbers from a string
        let pattern = #"\d+\.?\d*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match -> Double? in
            guard let r = Range(match.range, in: text) else { return nil }
            return Double(String(text[r]))
        }
    }

    // MARK: - Error helper

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }
}

// MARK: - Internal error type

enum KiroProviderError: Error, Equatable {
    case binaryNotFound
    case notLoggedIn
    case cliFailed(String)
    case parseError(String)
    case timeout

    var localizedMessage: String {
        switch self {
        case .binaryNotFound:
            "Chưa cài Kiro CLI"
        case .notLoggedIn:
            "Chưa đăng nhập Kiro. Chạy 'kiro-cli login' trong Terminal"
        case let .cliFailed(msg):
            "Kiro CLI lỗi: \(msg)"
        case let .parseError(msg):
            "Parse thất bại: \(msg)"
        case .timeout:
            "Kiro CLI timeout"
        }
    }
}
