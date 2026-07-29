import Foundation

// MARK: - Model quota (ported from AntigravityModelQuota in AntigravityStatusProbe.swift)

private struct AgModelQuota {
    let label: String
    let modelId: String
    let remainingFraction: Double?   // 0.0–1.0, nil when unknown
    let resetTime: Date?
    let resetDescription: String?

    var remainingPct: Int {
        guard let f = remainingFraction else { return 0 }
        return Int((max(0, min(1, f)) * 100).rounded())
    }
    var usedPct: Int { 100 - remainingPct }
}

// MARK: - gRPC-web / JSON-connect framing
//
// Antigravity's language server speaks gRPC-web using the Connect Protocol
// (https://connectrpc.com/docs/protocol). The header "Connect-Protocol-Version: 1"
// together with Content-Type: application/json causes the server to accept a plain
// JSON body and return a plain JSON body — no gRPC-web binary framing needed.
// This is exactly what CodexBarCore does in sendRequest(payload:endpoint:timeout:).

private enum AntigravityHTTP {
    static let getUserStatusPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    static let quotaSummaryPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"

    static func defaultRequestBody() -> [String: Any] {
        [
            "metadata": [
                "ideName": "antigravity",
                "extensionName": "antigravity",
                "ideVersion": "unknown",
                "locale": "en",
            ],
        ]
    }

    /// POST a Connect/JSON request to the local Antigravity language server.
    /// CSRF token header is included only when non-empty (CLI server needs none).
    static func post(
        scheme: String,
        port: Int,
        path: String,
        csrfToken: String,
        body: [String: Any],
        timeout: TimeInterval,
        session: URLSession
    ) async throws -> Data {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(path)") else {
            throw AntigravityProviderError.apiError("Invalid URL for port \(port)")
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(String(bodyData.count), forHTTPHeaderField: "Content-Length")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if !csrfToken.isEmpty {
            req.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityProviderError.apiError("Response không phải HTTP")
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw AntigravityProviderError.apiError("HTTP \(http.statusCode): \(msg)")
        }
        return data
    }
}

// MARK: - Process detection (ported from AntigravityStatusProbe port detection)
//
// Strategy (matches CodexBar):
//   1. Run `ps -ax -o pid=,command=` to list all processes.
//   2. Find Antigravity language_server, Antigravity IDE, or agy CLI.
//   3. Extract --csrf_token and --extension_server_port flags from the command line.
//   4. Run `lsof -nP -iTCP -sTCP:LISTEN -a -p <pid>` to get listening ports.

private struct AgProcessInfo {
    let pid: Int
    let csrfToken: String   // empty string for CLI (no token needed)
    let extensionPort: Int?
    let extensionServerCSRFToken: String?
}

private enum AgProcessDetector {
    static func detect(timeout: TimeInterval) async throws -> AgProcessInfo {
        let result = try await runCommand(
            binary: "/bin/ps",
            args: ["-ax", "-o", "pid=,command="],
            timeout: timeout,
            label: "antigravity-ps"
        )
        return try parseProcessList(result)
    }

    static func listeningPorts(pid: Int, timeout: TimeInterval) async throws -> [Int] {
        let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let lsof else {
            throw AntigravityProviderError.portDetectionFailed("lsof không có sẵn")
        }
        let output = try await runCommand(
            binary: lsof,
            args: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)],
            timeout: timeout,
            label: "antigravity-lsof"
        )
        let ports = parseListeningPorts(output)
        if ports.isEmpty {
            throw AntigravityProviderError.portDetectionFailed("Không tìm thấy port đang listen")
        }
        return ports
    }

    // MARK: Private

    private static func parseProcessList(_ output: String) throws -> AgProcessInfo {
        for rawLine in output.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int(parts[0]) else { continue }
            let command = String(parts[1])
            let lower = command.lowercased()

            guard isAntigravityProcess(lower) else { continue }

            if let token = extractFlag("--csrf_token", from: command) {
                // IDE or app language server — has a CSRF token
                let extPort = extractPort("--extension_server_port", from: command)
                let extToken = extractFlag("--extension_server_csrf_token", from: command)
                return AgProcessInfo(
                    pid: pid,
                    csrfToken: token,
                    extensionPort: extPort,
                    extensionServerCSRFToken: extToken
                )
            } else if isCLIProcess(lower) {
                // agy / antigravity-cli — no CSRF required
                return AgProcessInfo(pid: pid, csrfToken: "", extensionPort: nil, extensionServerCSRFToken: nil)
            }
            // IDE/app process without a token → skip (missingCSRFToken scenario)
        }
        throw AntigravityProviderError.notRunning
    }

    private static func isAntigravityProcess(_ lower: String) -> Bool {
        isLanguageServerProcess(lower) || isCLIProcess(lower)
    }

    private static func isLanguageServerProcess(_ lower: String) -> Bool {
        let lsPattern = #"(^|[/\\])language(?:_|-)server(?:[_-][a-z0-9]+)*(?:\.exe)?(\s|$)"#
        guard lower.range(of: lsPattern, options: .regularExpression) != nil else { return false }
        return lower.contains("antigravity") || lower.contains("--app_data_dir")
    }

    private static func isCLIProcess(_ lower: String) -> Bool {
        let cliPattern = #"(^|[/\\])(antigravity-cli|antigravity_cli)([\s/\\]|$)"#
        if lower.range(of: cliPattern, options: .regularExpression) != nil { return true }
        let agyPattern = #"(^|[/\\])agy(\s|$)"#
        return lower.range(of: agyPattern, options: .regularExpression) != nil
    }

    private static func extractFlag(_ flag: String, from command: String) -> String? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: flag))[=\\s]+([^\\s]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = regex.firstMatch(in: command, range: range),
              let tokenRange = Range(match.range(at: 1), in: command)
        else { return nil }
        return String(command[tokenRange])
    }

    private static func extractPort(_ flag: String, from command: String) -> Int? {
        extractFlag(flag, from: command).flatMap(Int.init)
    }

    private static func parseListeningPorts(_ output: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#) else { return [] }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        var ports: Set<Int> = []
        regex.enumerateMatches(in: output, range: range) { match, _, _ in
            guard let match,
                  let r = Range(match.range(at: 1), in: output),
                  let port = Int(output[r])
            else { return }
            ports.insert(port)
        }
        return ports.sorted()
    }

    private static func runCommand(
        binary: String,
        args: [String],
        timeout: TimeInterval,
        label: String
    ) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = args
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: AntigravityProviderError.portDetectionFailed("Không chạy được \(label): \(error.localizedDescription)"))
                    return
                }
                // Respect timeout by terminating the process
                let deadline = DispatchTime.now() + timeout
                DispatchQueue.global().asyncAfter(deadline: deadline) {
                    if process.isRunning { process.terminate() }
                }
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: output)
            }
        }
    }
}

// MARK: - Response parsing (ported from AntigravityStatusProbe parsing)

private enum AgResponseParser {
    /// Parse GetUserStatus JSON response → model quotas
    static func parseUserStatus(_ data: Data) throws -> (quotas: [AgModelQuota], email: String?, plan: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityProviderError.parseFailed("Invalid JSON")
        }
        if let code = json["code"] as? Int, code != 0 {
            throw AntigravityProviderError.apiError("gRPC code \(code)")
        }
        guard let userStatus = json["userStatus"] as? [String: Any] else {
            throw AntigravityProviderError.parseFailed("Missing userStatus")
        }
        let email = userStatus["email"] as? String
        let planName: String? = (userStatus["userTier"] as? [String: Any])?["name"] as? String
        let modelConfigs = (userStatus["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"] as? [[String: Any]] ?? []
        let quotas = modelConfigs.compactMap { parseModelConfig($0) }
        return (quotas, email, planName)
    }

    /// Parse RetrieveUserQuotaSummary JSON response → quota groups
    static func parseQuotaSummary(_ data: Data) throws -> (groups: [[String: Any]], email: String?, plan: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityProviderError.parseFailed("Invalid JSON")
        }
        if let code = json["code"] as? Int, code != 0 {
            throw AntigravityProviderError.apiError("gRPC code \(code)")
        }
        let summary = json["quotaSummary"] as? [String: Any] ?? json
        let groups = summary["groups"] as? [[String: Any]] ?? []
        return (groups, nil, nil)
    }

    private static func parseModelConfig(_ config: [String: Any]) -> AgModelQuota? {
        guard let quotaInfo = config["quotaInfo"] as? [String: Any] else { return nil }
        let label = (config["label"] as? String) ?? ""
        let modelId: String
        if let modelAlias = config["modelOrAlias"] as? [String: Any],
           let m = modelAlias["model"] as? String {
            modelId = m
        } else {
            modelId = label
        }
        let remaining = quotaInfo["remainingFraction"] as? Double
        let resetTime: Date?
        if let rt = quotaInfo["resetTime"] as? String {
            resetTime = parseDate(rt)
        } else {
            resetTime = nil
        }
        return AgModelQuota(
            label: label,
            modelId: modelId,
            remainingFraction: remaining,
            resetTime: resetTime,
            resetDescription: nil
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        if let d = ISO8601DateFormatter().date(from: value) { return d }
        if let t = Double(value) { return Date(timeIntervalSince1970: t) }
        return nil
    }
}

// MARK: - Error types

private enum AntigravityProviderError: LocalizedError {
    case notRunning
    case portDetectionFailed(String)
    case apiError(String)
    case parseFailed(String)
    case timedOut
    case accountMismatch(expected: String, found: String?)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Antigravity: cần IDE đang chạy"
        case .portDetectionFailed(let msg):
            return "Antigravity: phát hiện port thất bại – \(msg)"
        case .apiError(let msg):
            return "Antigravity API lỗi: \(msg)"
        case .parseFailed(let msg):
            return "Antigravity: parse lỗi – \(msg)"
        case .timedOut:
            return "Antigravity: timeout"
        case .accountMismatch(let expected, let found):
            let foundDesc = found ?? "(không xác định)"
            return "Account không khớp: cấu hình \"\(expected)\" nhưng đang đăng nhập \"\(foundDesc)\""
        }
    }
}

// MARK: - agy CLI warm-session launcher
//
// Khi local probe (ps -ax) không tìm thấy language_server/agy đang chạy,
// ta thử spawn `agy` binary để nó mở embedded localhost server, rồi
// poll lsof cho đến khi port xuất hiện (tối đa ~5 giây).
// Nếu agy không có hoặc không mở port trong thời gian → throw để
// caller bỏ qua (không lỗi cứng).

private enum AgCLIWarmSession {
    // Well-known install paths cho `agy` binary (khớp với CodexBarCore).
    static func resolveAgyBinary() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ]
        // PATH lookup
        if let pathVar = ProcessInfo.processInfo.environment["PATH"] {
            let dirs = pathVar.components(separatedBy: ":")
            for dir in dirs {
                let p = "\(dir)/agy"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        for p in candidates {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Spawn `agy` và trả về pid sau khi process đã chạy.
    /// Process được giữ alive trong background; caller chịu trách nhiệm terminate nếu cần.
    /// Trả về `Process` (đang chạy) và pid.
    static func spawnAgy(binary: String) throws -> (process: Process, pid: Int) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = []
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        // Chạy trong home directory để agy không bị lỗi chdir
        proc.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        try proc.run()
        return (proc, Int(proc.processIdentifier))
    }

    /// Poll lsof cho đến khi pid có port đang listen, hoặc hết deadline.
    static func waitForListeningPort(
        pid: Int,
        deadline: Date,
        pollInterval: TimeInterval = 0.4,
        lsofTimeout: TimeInterval = 2.0
    ) async throws -> [Int] {
        while Date() < deadline {
            if let ports = try? await AgProcessDetector.listeningPorts(pid: pid, timeout: lsofTimeout),
               !ports.isEmpty {
                return ports
            }
            // Ngủ poll interval
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw AntigravityProviderError.timedOut
    }

    /// Toàn bộ flow: resolve binary → spawn → wait for port → trả AgProcessInfo + ports.
    /// Throw nếu bất kỳ bước nào fail (caller sẽ bỏ qua).
    static func warmAndProbe(overallTimeout: TimeInterval) async throws -> (process: AgProcessInfo, ports: [Int], spawnedProcess: Process?) {
        guard let binary = resolveAgyBinary() else {
            throw AntigravityProviderError.notRunning
        }
        let (proc, pid) = try spawnAgy(binary: binary)
        let deadline = Date().addingTimeInterval(min(overallTimeout, 7.0))
        do {
            let ports = try await waitForListeningPort(pid: pid, deadline: deadline)
            let info = AgProcessInfo(pid: pid, csrfToken: "", extensionPort: nil, extensionServerCSRFToken: nil)
            return (info, ports, proc)
        } catch {
            // Nếu không mở được port → terminate process để không rò rỉ
            if proc.isRunning { proc.terminate() }
            throw error
        }
    }
}

// MARK: - ProviderStatus mapping helpers

private extension AntigravityProvider {
    private enum SemanticPool: CaseIterable, Hashable {
        case gemini
        case claudeGPT

        var label: String {
            switch self {
            case .gemini: return "Gemini"
            case .claudeGPT: return "Claude/GPT"
            }
        }
    }

    private enum SemanticInterval: CaseIterable, Hashable {
        case session
        case weekly

        var label: String {
            switch self {
            case .session: return "5-hour"
            case .weekly: return "weekly"
            }
        }

        var windowSeconds: Int {
            switch self {
            case .session: return 300
            case .weekly: return 604_800
            }
        }
    }

    private struct SemanticKey: Hashable {
        let pool: SemanticPool
        let interval: SemanticInterval
    }

    /// Reduce legacy model quotas to pool/interval windows. A missing interval
    /// marker stays an aggregate pool row instead of becoming a guessed 5-hour
    /// or weekly row.
    func quotaWindows(from quotas: [AgModelQuota]) -> [QuotaWindow] {
        let models = quotas.filter { q in
            let text = (q.modelId + " " + q.label).lowercased()
            return !text.contains("image") && !text.contains("lite") && !text.contains("autocomplete")
        }
        var windowsByKey: [SemanticKey: QuotaWindow] = [:]
        var markedPools: Set<SemanticPool> = []

        for quota in models {
            let text = quota.modelId + " " + quota.label
            guard let pool = semanticPool(in: text) else { continue }
            guard let interval = semanticInterval(in: text) else { continue }
            markedPools.insert(pool)
            guard quota.remainingFraction != nil else { continue }
            let key = SemanticKey(pool: pool, interval: interval)
            let window = makeQuotaWindow(
                label: semanticLabel(pool: pool, interval: interval),
                quota: quota,
                windowSeconds: interval.windowSeconds)
            if let existing = windowsByKey[key], prefer(window, over: existing) {
                windowsByKey[key] = window
            } else if windowsByKey[key] == nil {
                windowsByKey[key] = window
            }
        }

        var windows: [QuotaWindow] = []
        for pool in SemanticPool.allCases {
            for interval in SemanticInterval.allCases {
                let key = SemanticKey(pool: pool, interval: interval)
                if let window = windowsByKey[key] { windows.append(window) }
            }
            if markedPools.contains(pool) { continue }
            let poolModels = models.filter {
                semanticPool(in: $0.modelId + " " + $0.label) == pool && $0.remainingFraction != nil
            }
            guard let representative = poolModels.sorted(by: prefer).first else { continue }
            windows.append(makeQuotaWindow(label: pool.label, quota: representative, windowSeconds: nil))
        }
        return windows
    }

    private func semanticPool(in text: String) -> SemanticPool? {
        let lower = text.lowercased()
        if lower.contains("gemini") { return .gemini }
        if lower.contains("claude") || lower.contains("gpt") || lower.contains("openai") {
            return .claudeGPT
        }
        return nil
    }

    private func semanticInterval(in text: String) -> SemanticInterval? {
        let lower = text.lowercased()
        if lower.contains("5h") || lower.contains("5-hour") || lower.contains("5 hour") || lower.contains("five hour") {
            return .session
        }
        if lower.contains("weekly") || lower.contains("week") {
            return .weekly
        }
        return nil
    }

    private func semanticLabel(pool: SemanticPool, interval: SemanticInterval) -> String {
        "\(pool.label) \(interval.label)"
    }

    private func makeQuotaWindow(label: String, quota: AgModelQuota, windowSeconds: Int?) -> QuotaWindow {
        let subtitle: String?
        if let resetDate = quota.resetTime {
            subtitle = "Resets in \(WindowPace.format(max(0, resetDate.timeIntervalSinceNow)))"
        } else {
            subtitle = quota.resetDescription
        }
        return QuotaWindow(
            label: label,
            usedPct: quota.usedPct,
            remainingPct: quota.remainingPct,
            subtitle: subtitle,
            resetDate: quota.resetTime,
            windowSeconds: windowSeconds)
    }

    private func prefer(_ lhs: AgModelQuota, _ rhs: AgModelQuota) -> Bool {
        if lhs.usedPct != rhs.usedPct { return lhs.usedPct > rhs.usedPct }
        switch (lhs.resetTime, rhs.resetTime) {
        case let (.some(left), .some(right)) where left != right: return left < right
        case (.some, .none): return true
        case (.none, .some): return false
        default:
            let left = (lhs.modelId + " " + lhs.label).lowercased()
            let right = (rhs.modelId + " " + rhs.label).lowercased()
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
    }

    func quotaWindowsFromSummary(_ groups: [[String: Any]]) -> [QuotaWindow] {
        var windowsByKey: [SemanticKey: QuotaWindow] = [:]
        for group in groups {
            let groupTitle = (group["displayName"] as? String ?? "Quota")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let groupDescription = group["description"] as? String ?? ""
            let buckets = group["buckets"] as? [[String: Any] ] ?? []
            for bucket in buckets {
                guard bucket["disabled"] as? Bool != true,
                      let remaining = remainingFraction(from: bucket)
                else { continue }
                let bucketTitle = bucket["displayName"] as? String ?? ""
                let bucketID = bucket["bucketId"] as? String ?? ""
                let resetDescription = bucket["resetDescription"] as? String
                let markerText = [groupTitle, groupDescription, bucketID, bucketTitle, resetDescription ?? ""]
                    .joined(separator: " ")
                guard let pool = semanticPool(in: markerText),
                      let interval = semanticInterval(in: markerText)
                else { continue }
                let resetDate = (bucket["resetTime"] as? String).flatMap(parseDate)
                let window = makeQuotaWindow(
                    label: semanticLabel(pool: pool, interval: interval),
                    remainingFraction: remaining,
                    resetDate: resetDate,
                    resetDescription: resetDescription,
                    windowSeconds: interval.windowSeconds)
                let key = SemanticKey(pool: pool, interval: interval)
                if let existing = windowsByKey[key] {
                    if prefer(window, over: existing) { windowsByKey[key] = window }
                } else {
                    windowsByKey[key] = window
                }
            }
        }

        return SemanticPool.allCases.flatMap { pool in
            SemanticInterval.allCases.compactMap { interval in
                windowsByKey[SemanticKey(pool: pool, interval: interval)]
            }
        }
    }

    private func remainingFraction(from bucket: [String: Any]) -> Double? {
        func number(_ value: Any?) -> Double? {
            if let value = value as? NSNumber { return value.doubleValue }
            return value as? Double
        }
        if let value = number(bucket["remainingFraction"]) { return value }
        guard let remaining = bucket["remaining"] as? [String: Any] else { return nil }
        if let value = number(remaining["remainingFraction"]) { return value }
        guard remaining["case"] as? String == "remainingFraction" else { return nil }
        return number(remaining["value"])
    }

    private func parseDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private func makeQuotaWindow(
        label: String,
        remainingFraction: Double,
        resetDate: Date?,
        resetDescription: String?,
        windowSeconds: Int?
    ) -> QuotaWindow {
        let remainingPct = Int((max(0, min(1, remainingFraction)) * 100).rounded())
        let subtitle: String?
        if let resetDate {
            subtitle = "Resets in \(WindowPace.format(max(0, resetDate.timeIntervalSinceNow)))"
        } else {
            subtitle = resetDescription
        }
        return QuotaWindow(
            label: label,
            usedPct: 100 - remainingPct,
            remainingPct: remainingPct,
            subtitle: subtitle,
            resetDate: resetDate,
            windowSeconds: windowSeconds)
    }

    private func prefer(_ lhs: QuotaWindow, over rhs: QuotaWindow) -> Bool {
        if lhs.usedPct != rhs.usedPct { return lhs.usedPct > rhs.usedPct }
        switch (lhs.resetDate, rhs.resetDate) {
        case let (.some(left), .some(right)) where left != right: return left < right
        case (.some, .none): return true
        case (.none, .some): return false
        default: return false
        }
    }
}

// MARK: - AntigravityProvider

/// Antigravity IDE local-server quota provider.
///
/// Detection approach:
///   1. `ps -ax -o pid=,command=` to find `language_server` or `agy` process.
///   2. Extract --csrf_token and port from the command line.
///   3. `lsof -nP -iTCP -sTCP:LISTEN -a -p <pid>` for listening ports.
///   4. POST to the Connect/JSON endpoint (Content-Type: application/json,
///      Connect-Protocol-Version: 1, X-Codeium-Csrf-Token when non-empty).
///
/// Fallback (best-effort): if no running server is found, spawn `agy` CLI,
/// wait up to ~5 s for its embedded localhost server to open a port, then probe.
/// If `agy` is unavailable or does not open a port, this fallback is silently skipped.
///
/// Account-match guard: if `accountLabel` in config contains `@` (treated as an
/// email address), only snapshots whose response email matches (case-insensitive)
/// are accepted. A mismatch returns an explicit error instead of showing wrong data.
///
/// Endpoint tried first: RetrieveUserQuotaSummary (newer, richer).
/// Fallback: GetUserStatus → clientModelConfigs quotaInfo.
/// User preference for which Antigravity data source to use. Mirrors CodexBar's
/// usage-source picker. Persisted in UserDefaults; the ProvidersPane picker
/// binds the same key. `app`/`ide` both use the running-process probe.
enum AntigravityUsageSource: String, CaseIterable, Identifiable {
    case auto, app, ide, cli, oauth
    static let defaultsKey = "antigravityUsageSource"
    var id: String { rawValue }
    static var current: AntigravityUsageSource {
        AntigravityUsageSource(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "auto") ?? .auto
    }
}

final class AntigravityProvider: QuotaProvider {
    let id = "antigravity"
    let displayName = "Antigravity"

    private let session: URLSession
    private let timeout: TimeInterval

    init(session: URLSession = .shared, timeout: TimeInterval = 8.0) {
        self.session = session
        self.timeout = timeout
    }

    func fetch() async throws -> ProviderStatus {
        switch AntigravityUsageSource.current {
        case .oauth:
            return await fetchViaOAuth()
                ?? failure("Antigravity: chưa đăng nhập Google (Login with Google trong Settings)")
        case .cli:
            return await fetchViaCLIWarmSession() ?? failure("Antigravity: agy CLI không phản hồi")
        case .app, .ide:
            return await fetchFromRunningProcess() ?? failure("Antigravity: cần IDE/app đang chạy")
        case .auto:
            // App/IDE running process → agy CLI → OAuth remote (signed-in account).
            if let status = await fetchFromRunningProcess() { return status }
            if let status = await fetchViaCLIWarmSession() { return status }
            if let status = await fetchViaOAuth() { return status }
            return failure("Antigravity: cần IDE đang chạy, agy CLI, hoặc đăng nhập Google")
        }
    }

    /// OAuth remote path: uses the active stored Google account to fetch quota
    /// from cloudcode-pa. Returns nil when no account/credentials are configured
    /// (so `auto` can fall through), an error status when the fetch itself fails.
    private func fetchViaOAuth() async -> ProviderStatus? {
        let store = AntigravityOAuthStore.load()
        guard let account = AntigravityOAuthStore.activeAccount(in: store),
              let clientID = AntigravityOAuthStore.resolvedClientID(store: store),
              let clientSecret = AntigravityOAuthStore.resolvedClientSecret(store: store)
        else { return nil }
        do {
            let (windows, planName) = try await AntigravityRemoteUsage.fetchDetailed(
                refreshToken: account.refreshToken, clientID: clientID, clientSecret: clientSecret)
            guard !windows.isEmpty else { return failure("Antigravity: không lấy được quota OAuth") }
            return ProviderStatus(
                id: id, displayName: displayName, windows: windows, lastUpdated: Date(),
                error: nil, accountLabel: account.label, planName: planName, sourceLabel: "OAuth")
        } catch {
            return failure("Antigravity OAuth: \(error.localizedDescription)")
        }
    }

    // MARK: Private fetch helpers

    /// Probe against an already-running language_server or agy found via `ps`.
    private func fetchFromRunningProcess() async -> ProviderStatus? {
        let process: AgProcessInfo
        do {
            process = try await AgProcessDetector.detect(timeout: timeout)
        } catch {
            // notRunning is expected when IDE is closed — not an error
            return nil
        }
        let ports: [Int]
        do {
            ports = try await AgProcessDetector.listeningPorts(pid: process.pid, timeout: timeout)
        } catch {
            return nil
        }
        return await probeEndpoints(process: process, ports: ports)
    }

    /// Spawn `agy` CLI, wait for its server port, then probe.
    /// Returns nil (not an error) if agy binary is missing or port never opens.
    private func fetchViaCLIWarmSession() async -> ProviderStatus? {
        let result: (process: AgProcessInfo, ports: [Int], spawnedProcess: Process?)
        do {
            result = try await AgCLIWarmSession.warmAndProbe(overallTimeout: timeout)
        } catch {
            // Binary not found or port never opened — silently skip
            return nil
        }
        let status = await probeEndpoints(process: result.process, ports: result.ports)
        // Terminate the spawned agy after we're done to avoid lingering processes
        if let proc = result.spawnedProcess, proc.isRunning {
            proc.terminate()
        }
        return status
    }

    /// Try all ports with quota-summary first, then user-status.
    private func probeEndpoints(process: AgProcessInfo, ports: [Int]) async -> ProviderStatus? {
        for port in ports {
            if let status = await trySummaryEndpoint(scheme: "http", port: port, process: process) {
                return status
            }
            if let status = await tryUserStatusEndpoint(scheme: "http", port: port, process: process) {
                return status
            }
        }
        return nil
    }

    // MARK: Endpoint attempts

    private func trySummaryEndpoint(
        scheme: String,
        port: Int,
        process: AgProcessInfo
    ) async -> ProviderStatus? {
        do {
            let data = try await AntigravityHTTP.post(
                scheme: scheme,
                port: port,
                path: AntigravityHTTP.quotaSummaryPath,
                csrfToken: process.csrfToken,
                body: ["forceRefresh": true],
                timeout: timeout,
                session: session
            )
            let (groups, _, _) = try AgResponseParser.parseQuotaSummary(data)
            let windows = quotaWindowsFromSummary(groups)
            guard !windows.isEmpty else { return nil }

            // Best-effort: also fetch identity from user-status (non-fatal if fails)
            let (email, plan) = await fetchIdentity(scheme: scheme, port: port, process: process)

            // Account-match guard: nếu config chứa email, chỉ chấp nhận snapshot khớp
            if let mismatch = accountMismatchError(responseEmail: email) {
                return failure(mismatch)
            }

            let configLabel = BirdNionConfigStore.accountLabel(provider: id)
            let accountLabel = configLabel ?? email ?? "Antigravity"
            return ProviderStatus(
                id: id,
                displayName: displayName,
                windows: windows,
                lastUpdated: Date(),
                error: nil,
                accountLabel: accountLabel,
                planName: plan
            )
        } catch {
            return nil
        }
    }

    private func tryUserStatusEndpoint(
        scheme: String,
        port: Int,
        process: AgProcessInfo
    ) async -> ProviderStatus? {
        do {
            let data = try await AntigravityHTTP.post(
                scheme: scheme,
                port: port,
                path: AntigravityHTTP.getUserStatusPath,
                csrfToken: process.csrfToken,
                body: AntigravityHTTP.defaultRequestBody(),
                timeout: timeout,
                session: session
            )
            let (quotas, email, plan) = try AgResponseParser.parseUserStatus(data)
            let windows = quotaWindows(from: quotas)
            guard !windows.isEmpty else { return nil }

            // Account-match guard: nếu config chứa email, chỉ chấp nhận snapshot khớp
            if let mismatch = accountMismatchError(responseEmail: email) {
                return failure(mismatch)
            }

            let configLabel = BirdNionConfigStore.accountLabel(provider: id)
            let accountLabel = configLabel ?? email ?? "Antigravity"
            return ProviderStatus(
                id: id,
                displayName: displayName,
                windows: windows,
                lastUpdated: Date(),
                error: nil,
                accountLabel: accountLabel,
                planName: plan
            )
        } catch {
            return nil
        }
    }

    /// Returns a non-nil error string if `accountLabel` in config looks like an email
    /// and does NOT match the email returned in the response.
    /// Returns nil when no email guard is configured OR when emails match.
    private func accountMismatchError(responseEmail: String?) -> String? {
        guard let configLabel = BirdNionConfigStore.accountLabel(provider: id),
              configLabel.contains("@") else {
            // No email configured → no guard
            return nil
        }
        let expected = configLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let found = responseEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let found, found == expected else {
            let foundDesc = responseEmail ?? "(không xác định)"
            return "Account không khớp: cấu hình \"\(configLabel)\" nhưng đang đăng nhập \"\(foundDesc)\""
        }
        return nil
    }

    private func fetchIdentity(
        scheme: String,
        port: Int,
        process: AgProcessInfo
    ) async -> (email: String?, plan: String?) {
        guard let data = try? await AntigravityHTTP.post(
            scheme: scheme,
            port: port,
            path: AntigravityHTTP.getUserStatusPath,
            csrfToken: process.csrfToken,
            body: AntigravityHTTP.defaultRequestBody(),
            timeout: min(timeout, 1.5),
            session: session
        ),
        let (_, email, plan) = try? AgResponseParser.parseUserStatus(data)
        else { return (nil, nil) }
        return (email, plan)
    }

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }
}
