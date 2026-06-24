import Foundation

/// One reading from the local Codex CLI's `/status` screen.
/// Mirrors CodexBar's `CodexStatusSnapshot` (without the `rawText` field
/// since BirdNion doesn't render it).
struct CodexStatusSnapshot: Sendable, Equatable {
    let credits: Double?
    let fiveHourPercentLeft: Int?
    let weeklyPercentLeft: Int?
    let fiveHourResetText: String?
    let weeklyResetText: String?
    let fiveHourResetsAt: Date?
    let weeklyResetsAt: Date?
}

enum CodexStatusProbeError: LocalizedError, Equatable {
    case codexNotInstalled
    case launchFailed(String)
    case parseFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .codexNotInstalled: "Codex CLI chưa cài — `brew install codex` hoặc tương đương."
        case .launchFailed(let m): "Không chạy được codex: \(m)"
        case .parseFailed: "Không đọc được /status."
        case .timedOut: "codex /status timeout."
        }
    }
}

/// Runs `codex /status` once and parses the snapshot. Used as a fallback
/// when the OAuth usage call fails (CodexBar's "auto" mode).
///
/// Implementation note: we don't drive a real PTY (CodexBar's TTYCommandRunner
/// + CodexCLISession is ~700 lines). Instead we shell out, send `/status` via
/// stdin, and capture stdout. The trade-off: we depend on `codex` accepting
/// the command non-interactively. In practice `codex /status` exits after
/// printing, so this works.
enum CodexStatusProbe {
    private static let defaultTimeout: TimeInterval = 8

    /// Cached lookup so we don't shell out every poll cycle. The CLI version
    /// and binary path don't change while the app is running.
    private actor Cache {
        static let shared = Cache()
        private var cached: (at: Date, value: CodexStatusSnapshot?)?
        func get(now: Date, ttl: TimeInterval) -> CodexStatusSnapshot?? {
            if let c = cached, now.timeIntervalSince(c.at) < ttl { return .some(c.value) }
            return .none
        }
        func store(_ value: CodexStatusSnapshot?, at: Date) { cached = (at, value) }
    }

    static func fetch(
        binary: String? = nil,
        timeout: TimeInterval = defaultTimeout,
        now: Date = Date()) async throws -> CodexStatusSnapshot
    {
        // 30s cache — the value is informational, no need to spawn codex twice a minute.
        // Outer optional from `get` = "have we cached yet?"; inner = the snapshot (nil if last attempt failed).
        if let hit = await Cache.shared.get(now: now, ttl: 30) {
            if let snap = hit { return snap }
            throw CodexStatusProbeError.parseFailed("cache hit was nil")
        }
        let resolved = binary ?? Self.locateCodexBinary()
        guard let resolved, Self.isExecutable(resolved) else {
            await Cache.shared.store(nil, at: now)
            throw CodexStatusProbeError.codexNotInstalled
        }
        let text: String
        do {
            text = try await Self.runBinary(resolved, timeout: timeout)
        } catch {
            await Cache.shared.store(nil, at: now)
            throw error
        }
        do {
            let snapshot = try Self.parse(text: text, now: now)
            await Cache.shared.store(snapshot, at: now)
            return snapshot
        } catch {
            await Cache.shared.store(nil, at: now)
            throw error
        }
    }

    /// Parse `/status` output. Throws `parseFailed` when the output is empty
    /// or doesn't contain the fields we look for.
    static func parse(text: String, now: Date = Date()) throws -> CodexStatusSnapshot {
        let clean = TextParsing.stripANSICodes(text)
        guard !clean.isEmpty else { throw CodexStatusProbeError.timedOut }
        if clean.localizedCaseInsensitiveContains("data not available yet") {
            throw CodexStatusProbeError.parseFailed("data not available yet")
        }
        let credits = TextParsing.firstNumber(pattern: #"Credits:\s*([0-9][0-9.,]*)"#, text: clean)
        let fiveLine = TextParsing.firstLine(matching: #"5h limit[^\n]*"#, text: clean)
        let weekLine = TextParsing.firstLine(matching: #"Weekly limit[^\n]*"#, text: clean)
        let fivePct = fiveLine.flatMap(TextParsing.percentLeft(fromLine:))
        let weekPct = weekLine.flatMap(TextParsing.percentLeft(fromLine:))
        let fiveReset = fiveLine.flatMap(TextParsing.resetString(fromLine:))
        let weekReset = weekLine.flatMap(TextParsing.resetString(fromLine:))
        if credits == nil, fivePct == nil, weekPct == nil {
            throw CodexStatusProbeError.parseFailed(String(clean.prefix(200)))
        }
        return CodexStatusSnapshot(
            credits: credits,
            fiveHourPercentLeft: fivePct,
            weeklyPercentLeft: weekPct,
            fiveHourResetText: fiveReset,
            weeklyResetText: weekReset,
            fiveHourResetsAt: Self.parseResetDate(from: fiveReset, now: now),
            weeklyResetsAt: Self.parseResetDate(from: weekReset, now: now))
    }

    // MARK: - Reset date parsing

    private static func parseResetDate(from text: String?, now: Date) -> Date? {
        guard var raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        raw = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.defaultDate = now

        if let m = matchFirst(pattern: #"^([0-9]{1,2}:[0-9]{2}) on ([0-9]{1,2} [A-Za-z]{3})$"#, text: raw),
           m.count >= 2
        {
            raw = "\(m[1]) \(m[0])"
            formatter.dateFormat = "d MMM HH:mm"
            if let d = formatter.date(from: raw) { return bumpYearIfNeeded(d, now: now, calendar: calendar) }
        }
        if let m = matchFirst(pattern: #"^([0-9]{1,2}:[0-9]{2}) on ([A-Za-z]{3} [0-9]{1,2})$"#, text: raw),
           m.count >= 2
        {
            raw = "\(m[1]) \(m[0])"
            formatter.dateFormat = "MMM d HH:mm"
            if let d = formatter.date(from: raw) { return bumpYearIfNeeded(d, now: now, calendar: calendar) }
        }
        // codex CLI may also emit "on <date> <time>" (date before time).
        if let m = matchFirst(pattern: #"^on ([0-9]{1,2} [A-Za-z]{3}) ([0-9]{1,2}:[0-9]{2})$"#, text: raw),
           m.count >= 2
        {
            raw = "\(m[0]) \(m[1])"
            formatter.dateFormat = "d MMM HH:mm"
            if let d = formatter.date(from: raw) { return bumpYearIfNeeded(d, now: now, calendar: calendar) }
        }
        if let m = matchFirst(pattern: #"^on ([A-Za-z]{3} [0-9]{1,2}) ([0-9]{1,2}:[0-9]{2})$"#, text: raw),
           m.count >= 2
        {
            raw = "\(m[0]) \(m[1])"
            formatter.dateFormat = "MMM d HH:mm"
            if let d = formatter.date(from: raw) { return bumpYearIfNeeded(d, now: now, calendar: calendar) }
        }
        for fmt in ["HH:mm", "H:mm"] {
            formatter.dateFormat = fmt
            if let t = formatter.date(from: raw) {
                let c = calendar.dateComponents([.hour, .minute], from: t)
                guard let anchored = calendar.date(
                    bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: now)
                else { return nil }
                return anchored >= now ? anchored : calendar.date(byAdding: .day, value: 1, to: anchored)
            }
        }
        return nil
    }

    private static func bumpYearIfNeeded(_ date: Date, now: Date, calendar: Calendar) -> Date? {
        date >= now ? date : calendar.date(byAdding: .year, value: 1, to: date)
    }

    /// Returns all capture groups of the first match, or nil. Avoids the
    /// Swift 5.7+ `firstMatch(of:)` regex literal syntax so this file
    /// compiles on older toolchains.
    private static func matchFirst(pattern: String, text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, options: [], range: range),
              m.numberOfRanges >= 2
        else { return nil }
        var out: [String] = []
        for i in 1..<m.numberOfRanges {
            let r = m.range(at: i)
            guard r.location != NSNotFound, let rr = Range(r, in: text) else { continue }
            out.append(String(text[rr]))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Process

    private static func locateCodexBinary() -> String? {
        let fm = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            NSHomeDirectory() + "/.codex/bin/codex",
            "/usr/bin/codex",
        ]
        return candidates.first(where: { fm.isExecutableFile(atPath: $0) })
    }

    private static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    private static func runBinary(_ path: String, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = []
            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // Close stdin immediately — `codex` without args should print a
            // prompt then exit (or start its REPL). We force-feed "/status"
            // so it dumps the status screen and exits.
            let inPipe = Pipe()
            process.standardInput = inPipe
            let script = "/status\n/exit\n"
            if let data = script.data(using: .utf8) {
                try? inPipe.fileHandleForWriting.write(contentsOf: data)
                try? inPipe.fileHandleForWriting.close()
            }

            let timer = DispatchSource.makeTimerSource()
            var resumed = false
            func resume(_ result: Result<String, Error>) {
                guard !resumed else { return }
                resumed = true
                timer.cancel()
                cont.resume(with: result)
            }
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { process.terminate() }

            process.terminationHandler = { _ in
                let data = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let text = String(data: data, encoding: .utf8) ?? ""
                if text.isEmpty {
                    resume(.failure(CodexStatusProbeError.timedOut))
                } else {
                    resume(.success(text))
                }
            }

            do {
                try process.run()
                timer.activate()
            } catch {
                resume(.failure(CodexStatusProbeError.launchFailed(error.localizedDescription)))
            }
        }
    }

    // MARK: - Helpers

    private static func fail(_ e: CodexStatusProbeError) throws -> CodexStatusSnapshot {
        throw e
    }
}
