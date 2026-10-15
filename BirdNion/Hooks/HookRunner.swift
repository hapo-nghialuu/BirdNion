import Foundation
import os

/// Executes hook commands for quota/provider events. Runs the binary directly
/// (never a shell), injects only an allowlisted environment plus `BIRDNION_*`
/// event values, pipes a JSON payload to stdin, and enforces a timeout.
/// Ported from CodexBar `HookRunner`.
enum HookRunner {
    static let maximumPayloadBytes = 4096
    static let maximumOutputBytes = 64 * 1024
    private static let log = Logger(subsystem: "com.local.birdnion", category: "hooks")

    enum DispatchOutcome: Equatable, Sendable {
        case noMatchingRules
        case rateLimited
        /// At least one matching command was attempted, including failed launches.
        case attempted
    }

    enum HookRunnerError: Error {
        case binaryNotFound
        case launchFailed
        case timedOut
        case payloadTooLarge
        case nonZeroExit(Int32)
    }

    /// Environment keys forwarded to a hook. Deliberately narrow: BirdNion's
    /// own process environment may hold provider tokens — hooks must never
    /// receive secrets. Only these pass through, plus `BIRDNION_*` event vars.
    private static let forwardedEnvironmentKeys: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL",
        "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TMPDIR",
    ]

    /// Runs a single rule for an event to completion.
    @discardableResult
    static func run(
        rule: HookRule,
        event: HookEvent,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) async throws -> Int32 {
        var environment = baseEnvironment.filter { Self.forwardedEnvironmentKeys.contains($0.key) }
        for (key, value) in event.environmentVariables() {
            environment[key] = value
        }

        let payload = try event.jsonPayload()
        guard payload.count <= Self.maximumPayloadBytes else {
            throw HookRunnerError.payloadTooLarge
        }

        guard FileManager.default.isExecutableFile(atPath: rule.executable) else {
            throw HookRunnerError.binaryNotFound
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: rule.executable)
            process.arguments = rule.arguments
            process.environment = environment

            let stdinPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderrPipe

            // Cap stderr: it is only read for the failure log, never echoed back.
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                _ = handle.availableData
            }

            var finished = false
            let lock = NSLock()
            func resume(_ result: Result<Int32, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }

            process.terminationHandler = { proc in
                if proc.terminationReason == .uncaughtSignal {
                    resume(.failure(HookRunnerError.timedOut))
                } else if proc.terminationStatus == 0 {
                    resume(.success(proc.terminationStatus))
                } else {
                    resume(.failure(HookRunnerError.nonZeroExit(proc.terminationStatus)))
                }
            }

            let timeoutWork = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + rule.timeoutSeconds, execute: timeoutWork)

            do {
                try process.run()
            } catch {
                timeoutWork.cancel()
                resume(.failure(HookRunnerError.launchFailed))
                return
            }

            // Write payload then close so the child sees EOF.
            stdinPipe.fileHandleForWriting.write(payload)
            try? stdinPipe.fileHandleForWriting.close()
        }
    }

    /// Runs every enabled rule matching the event, subject to the rate limiter.
    /// Fire-and-forget friendly: failures are logged, never thrown to the caller.
    @discardableResult
    static func dispatch(
        event: HookEvent,
        config: HooksConfig,
        rateLimiter: HookRateLimiter,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) async -> DispatchOutcome {
        let rules = config.matchingRules(for: event)
        guard !rules.isEmpty else { return .noMatchingRules }
        if event.event.isRateLimited,
           await !rateLimiter.allow(event) {
            return .rateLimited
        }
        for rule in rules {
            do {
                _ = try await run(rule: rule, event: event, baseEnvironment: baseEnvironment)
            } catch {
                // Never log hook output or env — only the event and coarse reason.
                log.warning(
                    "hook failed event=\(event.event.rawValue, privacy: .public) provider=\(event.provider, privacy: .public) reason=\(failureReason(error), privacy: .public)")
            }
        }
        return .attempted
    }

    private static func failureReason(_ error: Error) -> String {
        guard let error = error as? HookRunnerError else { return "error" }
        switch error {
        case .binaryNotFound: return "executable not found"
        case .launchFailed: return "launch failed"
        case .timedOut: return "timed out"
        case .payloadTooLarge: return "payload too large"
        case .nonZeroExit(let code): return "exit \(code)"
        }
    }
}

/// In-memory storm suppression: fire a given (event, provider, account, window)
/// at most once per `window` seconds. State resets on relaunch — same as
/// upstream `HookRateLimiter`.
actor HookRateLimiter {
    static let defaultWindow: TimeInterval = 600 // 10 minutes

    private var lastFired: [String: Date] = [:]
    private let window: TimeInterval

    init(window: TimeInterval = HookRateLimiter.defaultWindow) {
        self.window = window
    }

    /// Records a fire at `now` and returns whether it is allowed.
    func allow(_ event: HookEvent, now: Date = Date()) -> Bool {
        let key = Self.key(for: event)
        if let previous = lastFired[key], now.timeIntervalSince(previous) < window {
            return false
        }
        lastFired[key] = now
        return true
    }

    static func key(for event: HookEvent) -> String {
        [
            event.event.rawValue,
            event.provider,
            event.account ?? "",
            event.window ?? "",
        ].joined(separator: "\u{1F}")
    }
}
