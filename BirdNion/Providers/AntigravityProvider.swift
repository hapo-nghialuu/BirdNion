import Foundation
import Darwin

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

private final class AntigravityLocalhostSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let protectionSpace = challenge.protectionSpace
        if protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = protectionSpace.serverTrust,
           (protectionSpace.host == "127.0.0.1" || protectionSpace.host == "localhost") {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let protectionSpace = challenge.protectionSpace
        if protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = protectionSpace.serverTrust,
           (protectionSpace.host == "127.0.0.1" || protectionSpace.host == "localhost") {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
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
        timeout: TimeInterval
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

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout

        let delegate = AntigravityLocalhostSessionDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: req) { data, response, error in
                session.invalidateAndCancel()
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: AntigravityProviderError.apiError("Response không phải HTTP"))
                    return
                }
                guard http.statusCode == 200, let data else {
                    let msg = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    continuation.resume(throwing: AntigravityProviderError.apiError("HTTP \(http.statusCode): \(msg)"))
                    return
                }
                continuation.resume(returning: data)
            }
            task.resume()
        }
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

private final class AgPipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedData = Data()

    func store(_ data: Data) {
        lock.lock()
        capturedData = data
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return capturedData
    }
}

private enum AgProcessDetector {
    static func detectAll(timeout: TimeInterval) async throws -> [AgProcessInfo] {
        let result = try await runCommand(
            binary: "/bin/ps",
            args: ["-ax", "-o", "pid=,command="],
            timeout: timeout,
            label: "antigravity-ps"
        )
        return parseProcessList(result)
    }

    static func detect(timeout: TimeInterval) async throws -> AgProcessInfo {
        let list = try await detectAll(timeout: timeout)
        guard let first = list.first else {
            throw AntigravityProviderError.notRunning
        }
        return first
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

    fileprivate static func parseProcessList(_ output: String) -> [AgProcessInfo] {
        var results: [AgProcessInfo] = []
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
                results.append(AgProcessInfo(
                    pid: pid,
                    csrfToken: token,
                    extensionPort: extPort,
                    extensionServerCSRFToken: extToken
                ))
            } else if isCLIProcess(lower) {
                // agy / antigravity-cli — no CSRF required
                results.append(AgProcessInfo(pid: pid, csrfToken: "", extensionPort: nil, extensionServerCSRFToken: nil))
            }
        }
        return results
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
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: AntigravityProviderError.portDetectionFailed("Không chạy được \(label): \(error.localizedDescription)"))
                    return
                }
                // Drain both pipes while the child is running. `ps` can emit
                // more than a pipe buffer when Chromium/IDE processes have
                // long command lines; waiting for exit before reading would
                // deadlock and hide the Antigravity language server row.
                let captures = (stdout: AgPipeCapture(), stderr: AgPipeCapture())
                let readers = DispatchGroup()
                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    captures.stdout.store(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    readers.leave()
                }
                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    captures.stderr.store(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    readers.leave()
                }
                // Respect timeout by terminating the process
                let deadline = DispatchTime.now() + timeout
                DispatchQueue.global().asyncAfter(deadline: deadline) {
                    guard process.isRunning else { return }
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                        if process.isRunning {
                            _ = kill(process.processIdentifier, SIGKILL)
                        }
                    }
                }
                process.waitUntilExit()
                readers.wait()
                let output = String(data: captures.stdout.data, encoding: .utf8) ?? ""
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

    /// Parse RetrieveUserQuotaSummary JSON response → quota groups.
    /// Server variants wrap groups under `quotaSummary`, `response`, or `summary`,
    /// or emit them at the root (Vendor accepts response ?? summary ?? root).
    /// A wrapper counts only when it actually contains groups.
    static func parseQuotaSummary(_ data: Data) throws -> (groups: [[String: Any]], email: String?, plan: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityProviderError.parseFailed("Invalid JSON")
        }
        if let code = json["code"] as? Int, code != 0 {
            throw AntigravityProviderError.apiError("gRPC code \(code)")
        }
        for key in ["quotaSummary", "response", "summary"] {
            if let wrapper = json[key] as? [String: Any],
               let groups = wrapper["groups"] as? [[String: Any]],
               !groups.isEmpty {
                return (groups, nil, nil)
            }
        }
        let groups = json["groups"] as? [[String: Any]] ?? []
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

    final class AgSpawnedProcess: @unchecked Sendable {
        let pid: pid_t
        let primaryFD: Int32
        private var isTerminated = false
        private let lock = NSLock()

        init(pid: pid_t, primaryFD: Int32) {
            self.pid = pid
            self.primaryFD = primaryFD
        }

        func terminate() {
            lock.lock()
            guard !isTerminated else {
                lock.unlock()
                return
            }
            isTerminated = true
            lock.unlock()

            // `posix_spawn` creates a dedicated process group. Terminate the
            // entire group, then reap the direct child so repeated refreshes
            // cannot leak descendants or zombies.
            if kill(-pid, SIGTERM) != 0 {
                _ = kill(pid, SIGTERM)
            }
            var status: Int32 = 0
            let deadline = Date().addingTimeInterval(0.5)
            var waitResult = waitpid(pid, &status, WNOHANG)
            while waitResult == 0, Date() < deadline {
                usleep(20_000)
                waitResult = waitpid(pid, &status, WNOHANG)
            }
            let groupStillExists = kill(-pid, 0) == 0 || errno == EPERM
            if waitResult == 0 || groupStillExists {
                if kill(-pid, SIGKILL) != 0 {
                    _ = kill(pid, SIGKILL)
                }
            }
            if waitResult == 0 {
                _ = waitpid(pid, &status, 0)
            }
            close(primaryFD)
        }

        deinit {
            terminate()
        }
    }

    /// Spawn `agy` in a pseudo-terminal (PTY) so it initializes its embedded server.
    ///
    /// - Parameters:
    ///   - homeOverride: khi có giá trị, child process nhận `HOME=<homeOverride>`
    ///     (và `PWD`/cwd cũng trỏ vào đó) thay vì HOME thật của user. `agy` đọc
    ///     login Google từ `$HOME/.gemini/`, nên đây là cách cô lập hoàn toàn
    ///     một account khỏi `~/.gemini` chính — không có override thì hành vi
    ///     giữ nguyên như trước (dùng HOME thật).
    ///   - args: đối số dòng lệnh truyền cho `agy` (ví dụ chế độ print
    ///     non-interactive `-p "ping" --print-timeout 40s`). Mặc định rỗng —
    ///     giữ nguyên phiên tương tác hiện có cho các caller cũ.
    static func spawnAgy(
        binary: String,
        homeOverride: String? = nil,
        args: [String] = []
    ) throws -> (process: AgSpawnedProcess, pid: Int) {
        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var win = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primaryFD, &secondaryFD, nil, nil, &win) == 0 else {
            throw AntigravityProviderError.apiError("openpty failed")
        }
        _ = fcntl(primaryFD, F_SETFL, O_NONBLOCK)

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            close(primaryFD)
            close(secondaryFD)
            throw AntigravityProviderError.apiError("posix_spawn_file_actions_init failed")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_adddup2(&fileActions, secondaryFD, 0)
        posix_spawn_file_actions_adddup2(&fileActions, secondaryFD, 1)
        posix_spawn_file_actions_adddup2(&fileActions, secondaryFD, 2)
        posix_spawn_file_actions_addclose(&fileActions, primaryFD)
        posix_spawn_file_actions_addclose(&fileActions, secondaryFD)

        let effectiveHome = homeOverride ?? NSHomeDirectory()
        _ = effectiveHome.withCString { path in
            posix_spawn_file_actions_addchdir_np(&fileActions, path)
        }

        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else {
            close(primaryFD)
            close(secondaryFD)
            throw AntigravityProviderError.apiError("posix_spawnattr_init failed")
        }
        defer { posix_spawnattr_destroy(&attr) }

        let spawnFlags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attr, Int16(spawnFlags))
        posix_spawnattr_setpgroup(&attr, 0)

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["PWD"] = effectiveHome
        if let homeOverride {
            env["HOME"] = homeOverride
        }

        let envStrings = env.map { "\($0.key)=\($0.value)" }
        let cEnv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        let argv = [binary] + args
        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]

        defer {
            for ptr in cEnv where ptr != nil { free(ptr) }
            for ptr in cArgs where ptr != nil { free(ptr) }
        }

        var childPID: pid_t = 0
        let status = posix_spawn(&childPID, binary, &fileActions, &attr, cArgs, cEnv)
        close(secondaryFD)

        guard status == 0 else {
            close(primaryFD)
            throw AntigravityProviderError.apiError("posix_spawn failed with status \(status)")
        }

        let spawned = AgSpawnedProcess(pid: childPID, primaryFD: primaryFD)
        return (spawned, Int(childPID))
    }

    /// Poll lsof cho đến khi pid có port đang listen, hoặc hết deadline.
    static func waitForListeningPort(
        pid: Int,
        deadline: Date,
        pollInterval: TimeInterval = 0.4,
        lsofTimeout: TimeInterval = 2.0
    ) async throws -> [Int] {
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            if let ports = try? await AgProcessDetector.listeningPorts(
                pid: pid,
                timeout: min(lsofTimeout, remaining)
            ),
               !ports.isEmpty {
                return ports
            }
            let sleepInterval = min(pollInterval, max(0, deadline.timeIntervalSinceNow))
            guard sleepInterval > 0 else { break }
            try await Task.sleep(nanoseconds: UInt64(sleepInterval * 1_000_000_000))
        }
        throw AntigravityProviderError.timedOut
    }

    /// Toàn bộ flow: resolve binary → spawn in PTY → wait for port → trả AgProcessInfo + ports.
    /// Throw nếu bất kỳ bước nào fail (caller sẽ bỏ qua).
    ///
    /// `homeOverride`/`args` chuyển thẳng xuống `spawnAgy` (xem doc ở đó) —
    /// dùng cho warm session cô lập theo account. `portWaitCap` giới hạn thời
    /// gian chờ port tối đa (mặc định 7s cho warm session chính; isolated
    /// fetch cần lâu hơn vì agy phải auth trước khi mở port).
    static func warmAndProbe(
        homeOverride: String? = nil,
        args: [String] = [],
        overallTimeout: TimeInterval,
        portWaitCap: TimeInterval = 7.0
    ) async throws -> (process: AgProcessInfo, ports: [Int], spawnedProcess: AgSpawnedProcess?) {
        guard let binary = resolveAgyBinary() else {
            throw AntigravityProviderError.notRunning
        }
        let (proc, pid) = try spawnAgy(binary: binary, homeOverride: homeOverride, args: args)
        let deadline = Date().addingTimeInterval(min(overallTimeout, portWaitCap))
        do {
            let ports = try await waitForListeningPort(pid: pid, deadline: deadline)
            let info = AgProcessInfo(pid: pid, csrfToken: "", extensionPort: nil, extensionServerCSRFToken: nil)
            return (info, ports, proc)
        } catch {
            proc.terminate()
            throw error
        }
    }
}

// MARK: - Isolated per-account agy HOME (multi-account quota)
//
// `agy` đọc login Google từ `$HOME/.gemini/`. Để lấy quota của MỘT account cụ
// thể — khác với account mà agy chính (dùng HOME thật) đang đăng nhập — ta
// trỏ HOME sang một thư mục riêng cho account đó, mỗi account có bản sao
// `.gemini/` độc lập, không đụng tới `~/.gemini` thật của user. Việc SAO CHÉP
// login vào thư mục này (luồng đăng nhập lần đầu) nằm ngoài phạm vi file này —
// ở đây chỉ đọc, và không bao giờ bịa quota khi chưa có login cô lập.
enum AntigravityIsolatedAgy {
    private static let subdirName = "agy-accounts"
    private static let loginTokenRelativePath = ".gemini/jetski-standalone-oauth-token"

    /// Thư mục gốc chứa tất cả HOME cô lập theo account: `~/.config/birdnion/agy-accounts/`.
    /// Dùng chung path resolution với `BirdNionConfigStore` (BIRDNION_CONFIG /
    /// XDG_CONFIG_HOME override) để nằm cạnh `settings.json`.
    static func baseDir(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        BirdNionConfigStore.configURL(home: home, env: env, fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent(subdirName, isDirectory: true)
    }

    /// Sanitize một account label (thường là email) thành tên thư mục an
    /// toàn và xác định (deterministic): chỉ giữ chữ/số ASCII, `-`, `_`, `.`;
    /// mọi ký tự khác (kể cả `@`) thay bằng `_`.
    static func sanitizedDirName(forAccountLabel label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "_" }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
        )
        let scalars = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(scalars)
    }

    /// HOME dành riêng cho account này. `agy` chạy với HOME này sẽ đọc/ghi
    /// `<homeDir>/.gemini/` — hoàn toàn tách biệt với `~/.gemini` thật.
    static func homeDir(
        forAccountLabel label: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        baseDir(home: home, env: env, fileManager: fileManager)
            .appendingPathComponent(sanitizedDirName(forAccountLabel: label), isDirectory: true)
    }

    /// True khi account này đã có login cô lập sẵn (đã copy `.gemini/` với
    /// token OAuth vào thư mục riêng qua luồng đăng nhập — ngoài phạm vi file
    /// này). False khi thư mục/token chưa tồn tại; caller phải fallback,
    /// không bao giờ bịa quota cho account chưa từng login cô lập.
    static func hasLogin(
        forAccountLabel label: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Bool {
        let tokenPath = homeDir(forAccountLabel: label, home: home, env: env, fileManager: fileManager)
            .appendingPathComponent(loginTokenRelativePath).path
        return fileManager.fileExists(atPath: tokenPath)
    }

    /// Seed một login `agy` cô lập TỪ bộ token OAuth (client 1071 + scope agy)
    /// mà KHÔNG cần chạy `agy` login: ghi đúng bộ file agy cần để coi account
    /// này đã đăng nhập + onboard xong. Đã kiểm chứng trên máy thật — agy chấp
    /// nhận thư mục seed này và trả quota bình thường.
    ///
    /// 5 file: `.gemini/jetski-standalone-oauth-token` +
    /// `.gemini/antigravity-cli/antigravity-oauth-token` (cùng nội dung token,
    /// 0600), `.gemini/antigravity-cli/jetski_state.pbtxt` (đánh dấu
    /// post-onboarding hoàn tất — thiếu là agy ép login lại), `.gemini/user_id`,
    /// `.gemini/antigravity-cli/installation_id`.
    static func seedLogin(
        forAccountLabel label: String,
        accessToken: String,
        refreshToken: String,
        expiry: Date,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws {
        let gemini = homeDir(forAccountLabel: label, home: home, env: env, fileManager: fileManager)
            .appendingPathComponent(".gemini", isDirectory: true)
        let cli = gemini.appendingPathComponent("antigravity-cli", isDirectory: true)
        try fileManager.createDirectory(at: cli, withIntermediateDirectories: true)

        // Token theo đúng format agy: { "token": {...}, "auth_method": "consumer" }.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let tokenObject: [String: Any] = [
            "token": [
                "access_token": accessToken,
                "token_type": "Bearer",
                "refresh_token": refreshToken,
                "expiry": iso.string(from: expiry),
            ],
            "auth_method": "consumer",
        ]
        let tokenData = try JSONSerialization.data(withJSONObject: tokenObject, options: [.sortedKeys])
        try writeSecureFile(tokenData, to: gemini.appendingPathComponent("jetski-standalone-oauth-token"), fileManager: fileManager)
        try writeSecureFile(tokenData, to: cli.appendingPathComponent("antigravity-oauth-token"), fileManager: fileManager)

        // installation_id phải KHỚP installation_uuid trong pbtxt; UUID mới cho
        // mỗi account cô lập để không đụng nhau.
        let installationID = UUID().uuidString.lowercased()
        let userID = UUID().uuidString.lowercased()
        try Data(userID.utf8).write(to: gemini.appendingPathComponent("user_id"), options: .atomic)
        try Data(installationID.utf8).write(to: cli.appendingPathComponent("installation_id"), options: .atomic)
        try Data(jetskiState(installationUUID: installationID).utf8)
            .write(to: cli.appendingPathComponent("jetski_state.pbtxt"), options: .atomic)
    }

    /// Ghi file 0600 cho dữ liệu nhạy cảm (token) — tạo mới hoặc ghi đè.
    private static func writeSecureFile(_ data: Data, to url: URL, fileManager: FileManager) throws {
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// `jetski_state.pbtxt` đánh dấu post-onboarding đã xong — bản tối thiểu của
    /// state agy ghi sau onboarding (đã xác minh đủ để agy không ép onboard lại).
    private static func jetskiState(installationUUID: String) -> String {
        """
        post_onboarding:  {
          completed_steps:  POST_ONBOARDING_STEP_TYPE_MANAGER_WELCOME
          completed_steps:  POST_ONBOARDING_STEP_TYPE_USAGE_MODE
          completed_steps:  POST_ONBOARDING_STEP_TYPE_AGENT_CONFIGURATION
          completed_steps:  POST_ONBOARDING_STEP_TYPE_ADD_WORKSPACE
        }
        installation_uuid:  "\(installationUUID)"
        migrations:  {
          key:  3
          value:  MIGRATION_STATUS_COMPLETED
        }
        migrations:  {
          key:  4
          value:  MIGRATION_STATUS_COMPLETED
        }
        migrations:  {
          key:  5
          value:  MIGRATION_STATUS_COMPLETED
        }

        """
    }
}

// MARK: - agy CLI switch + omp import (áp account đang chọn ra công cụ thật)
//
// BirdNion mặc định CHỈ đọc quota. Hai type dưới đây là ngoại lệ có chủ đích do
// người dùng yêu cầu "công tắc": ghi credential của account đang chọn ra công cụ
// mà họ chạy model.
//   - `AntigravityAgyCLI`: switch account cho lệnh `agy` (ghi `~/.gemini/...`),
//     tương đương cơ chế switch của Codex (`~/.codex/auth.json`). Đảo lại được
//     nhờ backup token cũ. So account bằng refresh_token (offline, không mạng).
//   - `AntigravityOmpImport`: import account vào kho auth của omp qua lệnh
//     chính thống `omp auth-broker import` (KHÔNG ghi thẳng SQLite có mirror
//     guard). omp tự rank/rotate nên đây là "thêm vào pool", không ép riêng.

/// Đọc trường token từ file `jetski-standalone-oauth-token`.
private struct AntigravityJetskiToken: Decodable {
    struct Inner: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiry: String
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiry
        }
    }
    let token: Inner

    static func load(_ url: URL) -> AntigravityJetskiToken? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AntigravityJetskiToken.self, from: data)
    }
}

enum AntigravityAgyCLI {
    private static let jetskiRel = "jetski-standalone-oauth-token"
    private static let cliTokenRel = "antigravity-cli/antigravity-oauth-token"

    static func realGeminiDir(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".gemini", isDirectory: true)
    }

    private static func isolatedGeminiDir(
        accountLabel: String,
        home: URL,
        env: [String: String],
        fileManager: FileManager
    ) -> URL {
        AntigravityIsolatedAgy.homeDir(forAccountLabel: accountLabel, home: home, env: env, fileManager: fileManager)
            .appendingPathComponent(".gemini", isDirectory: true)
    }

    /// Account nào đang được nạp vào `~/.gemini` — so bằng refresh_token của
    /// login cô lập với refresh_token trong `~/.gemini` (offline). True khớp.
    static func isActiveInCLI(
        accountLabel: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Bool {
        let isoURL = isolatedGeminiDir(accountLabel: accountLabel, home: home, env: env, fileManager: fileManager)
            .appendingPathComponent(jetskiRel)
        let realURL = realGeminiDir(home: home).appendingPathComponent(jetskiRel)
        guard let iso = AntigravityJetskiToken.load(isoURL)?.token.refreshToken,
              let real = AntigravityJetskiToken.load(realURL)?.token.refreshToken,
              !iso.isEmpty
        else { return false }
        return iso == real
    }

    /// Ghi token của account cô lập vào `~/.gemini` để lệnh `agy` (và mọi tool
    /// đọc `~/.gemini`) dùng account đó. Chỉ ghi đè 2 file token, giữ nguyên
    /// device ids/state của `~/.gemini` (đã xác minh agy vẫn auth đúng account
    /// theo token). Backup token cũ vào `agy-cli-backup/` trước khi ghi.
    static func switchToCLI(
        accountLabel: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws {
        let isoGemini = isolatedGeminiDir(accountLabel: accountLabel, home: home, env: env, fileManager: fileManager)
        let isoJetski = isoGemini.appendingPathComponent(jetskiRel)
        guard fileManager.fileExists(atPath: isoJetski.path) else {
            throw AntigravityOAuthError.missingCredentials
        }

        let realGemini = realGeminiDir(home: home)
        let realCliDir = realGemini.appendingPathComponent("antigravity-cli", isDirectory: true)
        try fileManager.createDirectory(at: realCliDir, withIntermediateDirectories: true)

        // Backup token ~/.gemini hiện tại (đảo lại được nếu cần).
        let configDir = AntigravityIsolatedAgy.baseDir(home: home, env: env, fileManager: fileManager)
            .deletingLastPathComponent()
        let backupDir = configDir.appendingPathComponent("agy-cli-backup", isDirectory: true)
        try? fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
        backup(realGemini.appendingPathComponent(jetskiRel),
               to: backupDir.appendingPathComponent(jetskiRel), fileManager: fileManager)
        backup(realGemini.appendingPathComponent(cliTokenRel),
               to: backupDir.appendingPathComponent("antigravity-oauth-token"), fileManager: fileManager)

        // Ghi đè token: isolated -> ~/.gemini.
        try copySecure(from: isoJetski,
                       to: realGemini.appendingPathComponent(jetskiRel), fileManager: fileManager)
        let isoCli = isoGemini.appendingPathComponent(cliTokenRel)
        if fileManager.fileExists(atPath: isoCli.path) {
            try copySecure(from: isoCli,
                           to: realCliDir.appendingPathComponent("antigravity-oauth-token"), fileManager: fileManager)
        }
    }

    private static func backup(_ src: URL, to dst: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: src.path), let data = try? Data(contentsOf: src) else { return }
        try? data.write(to: dst, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
    }

    private static func copySecure(from src: URL, to dst: URL, fileManager: FileManager) throws {
        let data = try Data(contentsOf: src)
        try data.write(to: dst, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
    }
}

enum AntigravityOmpImport {
    /// omp lưu auth trong `~/.omp/agent/agent.db`; import qua lệnh chính thống
    /// `omp auth-broker import <file>` (JSON kiểu CLIProxyAPI). omp tự rank +
    /// rotate nhiều account nên đây là THÊM account vào pool, không ép riêng.
    static func resolveOmpBinary(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/omp", "/usr/local/bin/omp", "/usr/bin/omp",
            "\(home)/.bun/bin/omp", "\(home)/.local/bin/omp",
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Dựng JSON CLIProxyAPI từ token cô lập của account rồi chạy `omp import`.
    /// Ném lỗi khi thiếu token, không có binary omp, hoặc omp bỏ qua file.
    static func importAccount(
        accountLabel: String,
        email: String?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) async throws {
        let tokenURL = AntigravityIsolatedAgy.homeDir(forAccountLabel: accountLabel, home: home, env: env, fileManager: fileManager)
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("jetski-standalone-oauth-token")
        guard let parsed = AntigravityJetskiToken.load(tokenURL) else {
            throw AntigravityOAuthError.missingCredentials
        }
        guard let omp = resolveOmpBinary(env: env, fileManager: fileManager) else {
            throw AntigravityOAuthError.tokenExchangeFailed("Không tìm thấy omp — hãy cài oh-my-pi trước.")
        }

        let mail = (email?.isEmpty == false ? email! : accountLabel)
        let json: [String: Any] = [
            "type": "antigravity",
            "access_token": parsed.token.accessToken,
            "refresh_token": parsed.token.refreshToken,
            "expired": parsed.token.expiry,
            "email": mail,
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])

        let tmpDir = fileManager.temporaryDirectory
            .appendingPathComponent("birdnion-omp-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tmpDir) }
        // Tên file: `antigravity-<email>.json` (import cũng suy type từ prefix).
        let safeMail = mail.replacingOccurrences(of: "/", with: "_")
        let fileURL = tmpDir.appendingPathComponent("antigravity-\(safeMail).json")
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        let (out, status) = try runProcess(
            binary: omp,
            args: ["auth-broker", "import", fileURL.path, "--json"],
            env: env)
        guard status == 0 else {
            throw AntigravityOAuthError.tokenExchangeFailed("omp import lỗi (exit \(status)): \(out.prefix(200))")
        }
        // Output JSON có `skipped: [...]` khi file bị bỏ qua (thiếu field…).
        if let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
           let skipped = obj["skipped"] as? [[String: Any]], !skipped.isEmpty {
            let reason = (skipped.first?["reason"] as? String) ?? "không rõ lý do"
            throw AntigravityOAuthError.tokenExchangeFailed("omp bỏ qua: \(reason)")
        }
    }

    /// Chạy process đồng bộ (off main), trả (stdout+stderr, exitCode).
    private static func runProcess(binary: String, args: [String], env: [String: String]) throws -> (String, Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", proc.terminationStatus)
    }
}

// MARK: - Isolated agy login session (multi-account, no agy login needed)
//
// Đăng nhập MỘT account vào HOME cô lập của riêng nó để `fetchViaIsolatedAgy`
// đọc quota mà không đụng `~/.gemini` thật.
//
// Cách làm (đã xác minh trên máy thật — KHÔNG chạy `agy` login, KHÔNG dán code):
// BirdNion tự chạy loopback OAuth với client agy CLI (1071) + scope agy, người
// dùng đăng nhập Google trên trình duyệt, Google redirect về `127.0.0.1` nên
// BirdNion tự bắt code (không dính giới hạn ~60s của luồng `agy` login). Sau đó
// seed đúng bộ file vào HOME cô lập (`AntigravityIsolatedAgy.seedLogin`) — agy
// coi như account này đã đăng nhập + onboard xong.
@MainActor
final class AntigravityIsolatedLoginSession: ObservableObject {
    enum State: Equatable {
        case idle
        case launching
        case success
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Nhận diện phiên hiện tại: nếu người dùng huỷ / khởi động phiên khác
    /// trong lúc OAuth (loopback chờ tới 120s) đang chạy, kết quả của phiên cũ
    /// bay tới sau sẽ không khớp token nên tự bỏ qua, không ghi đè state mới.
    private var sessionToken = UUID()

    /// Bắt đầu đăng nhập cho `accountLabel`: mở trình duyệt (loopback OAuth) rồi
    /// seed HOME cô lập. An toàn gọi lại — phiên cũ tự bị vô hiệu.
    func start(accountLabel: String) {
        let token = UUID()
        sessionToken = token
        state = .launching

        Task { [weak self] in
            do {
                let tokens = try await AntigravityOAuthLogin.loginForAgyCLI()
                // Đa tài khoản: nếu label là email mà người dùng đăng nhập nhầm
                // account khác thì báo lỗi rõ, tuyệt đối không seed sai account.
                if accountLabel.contains("@"),
                   let email = tokens.email, !email.isEmpty,
                   email.caseInsensitiveCompare(accountLabel) != .orderedSame {
                    await self?.finish(
                        token: token,
                        result: .failure(AntigravityLoginError.accountMismatch(
                            expected: accountLabel, got: email)))
                    return
                }
                try AntigravityIsolatedAgy.seedLogin(
                    forAccountLabel: accountLabel,
                    accessToken: tokens.accessToken,
                    refreshToken: tokens.refreshToken,
                    expiry: tokens.expiry)
                await self?.finish(token: token, result: .success(()))
            } catch {
                await self?.finish(token: token, result: .failure(error))
            }
        }
    }

    /// Huỷ phiên hiện tại: vô hiệu kết quả OAuth đang chờ + đưa state về idle.
    func cancel() {
        sessionToken = UUID()
        state = .idle
    }

    // MARK: - Private

    private func finish(token: UUID, result: Result<Void, Error>) {
        guard token == sessionToken else { return }
        switch result {
        case .success:
            state = .success
            // Báo QuotaService fetch lại Antigravity ngay — cùng cơ chế với nút
            // refresh thủ công (xem QuotaService.start()).
            NotificationCenter.default.post(name: .birdnionRefresh, object: "antigravity")
        case .failure(let error):
            state = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        if let login = error as? AntigravityLoginError { return login.userMessage }
        if let oauth = error as? AntigravityOAuthError {
            switch oauth {
            case .timeout:
                return L10n.t("antigravity.login.timeout")
            case .codeMissing, .tokenExchangeFailed:
                return L10n.t("antigravity.login.exchangeFailed")
            default:
                break
            }
        }
        return error.localizedDescription
    }
}

/// Lỗi cấp phiên đăng nhập agy cô lập (khác `AntigravityOAuthError` cấp mạng).
enum AntigravityLoginError: Error {
    case accountMismatch(expected: String, got: String)

    var userMessage: String {
        switch self {
        case let .accountMismatch(expected, got):
            return L10n.t("antigravity.login.accountMismatch") + " (\(got) ≠ \(expected))"
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
            case .session: return 18_000
            case .weekly: return 604_800
            }
        }
    }

    private struct SemanticKey: Hashable {
        let pool: SemanticPool
        let interval: SemanticInterval
    }

    private func isIgnoredQuotaMarker(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("image")
            || lower.contains("lite")
            || lower.contains("autocomplete")
            || lower.contains("unknown")
            || lower.contains("model_placeholder")
            || lower.contains("model-placeholder")
    }

    /// Reduce legacy model quotas to pool/interval windows. A missing interval
    /// marker stays an aggregate pool row instead of becoming a guessed 5-hour
    /// or weekly row.
    func quotaWindows(from quotas: [AgModelQuota]) -> [QuotaWindow] {
        let models = quotas.filter { q in
            !isIgnoredQuotaMarker(q.modelId + " " + q.label)
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
                guard !isIgnoredQuotaMarker(markerText),
                      let pool = semanticPool(in: markerText),
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

    /// Deadline chờ agy cô lập (per-account) auth + mở port. Dài hơn nhiều so
    /// với warm session chính (7s) vì agy cô lập phải làm mới OAuth session
    /// lần đầu trên mỗi lần spawn — theo thực nghiệm mất ~10-20s.
    private static let isolatedFetchDeadline: TimeInterval = 35.0

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
            var accountMismatch: ProviderStatus?
            if let status = await fetchFromRunningProcess() {
                if !Self._shouldContinueAfterCandidateForTesting(error: status.error) {
                    return status
                }
                accountMismatch = status
            }
            if let status = await fetchViaCLIWarmSession() {
                if !Self._shouldContinueAfterCandidateForTesting(error: status.error) {
                    return status
                }
                accountMismatch = status
            }
            // Account đang chọn KHÔNG khớp account mà agy chính (HOME thật)
            // đang đăng nhập, nhưng nếu account đó đã từng login cô lập
            // (thư mục agy-accounts/<label> riêng), thử spawn agy cô lập cho
            // đúng account đó trước khi rơi xuống OAuth/mismatch.
            if let accountMismatch {
                let store = AntigravityOAuthStore.load()
                if let activeAccount = AntigravityOAuthStore.activeAccount(in: store),
                   AntigravityIsolatedAgy.hasLogin(forAccountLabel: activeAccount.label),
                   let isolatedStatus = await fetchViaIsolatedAgy(
                       accountLabel: activeAccount.label,
                       expectedEmail: activeAccount.email
                   ),
                   isolatedStatus.error == nil {
                    return isolatedStatus
                }
            }
            // OAuth (cloud) CHỈ hợp lệ khi lấy được quota thật. Với account mà
            // agy không đăng nhập, cloud luôn 403 — đừng để lỗi đó che thông báo
            // "account không khớp" (rõ ràng, đúng việc cần làm). Ưu tiên:
            // OAuth thành công → thông báo mismatch → lỗi OAuth.
            let oauthStatus = await fetchViaOAuth()
            if let oauthStatus, oauthStatus.error == nil {
                return oauthStatus
            }
            if let accountMismatch {
                return accountMismatch
            }
            if let oauthStatus {
                return oauthStatus
            }
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
        let deadline = Date().addingTimeInterval(timeout)
        let processes: [AgProcessInfo]
        do {
            processes = try await AgProcessDetector.detectAll(timeout: min(timeout, 2.0))
        } catch {
            return nil
        }
        var accountMismatch: ProviderStatus?
        for (index, process) in processes.enumerated() {
            let candidatesLeft = processes.count - index
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            let processDeadline = Date().addingTimeInterval(remaining / Double(candidatesLeft))
            let ports: [Int]
            do {
                ports = try await AgProcessDetector.listeningPorts(
                    pid: process.pid,
                    timeout: min(processDeadline.timeIntervalSinceNow, 2.0)
                )
            } catch {
                continue
            }
            if let status = await probeEndpoints(
                process: process,
                ports: ports,
                deadline: processDeadline
            ) {
                if Self._shouldContinueAfterCandidateForTesting(error: status.error) {
                    accountMismatch = status
                    continue
                }
                return status
            }
        }
        return accountMismatch
    }

    /// Spawn `agy` CLI, wait for its server port and API readiness, then probe.
    /// Returns nil (not an error) if agy binary is missing or port never opens.
    private func fetchViaCLIWarmSession() async -> ProviderStatus? {
        let deadline = Date().addingTimeInterval(timeout)
        let result: (process: AgProcessInfo, ports: [Int], spawnedProcess: AgCLIWarmSession.AgSpawnedProcess?)
        do {
            result = try await AgCLIWarmSession.warmAndProbe(overallTimeout: deadline.timeIntervalSinceNow)
        } catch {
            // Binary not found or port never opened — silently skip
            return nil
        }
        var currentPorts = result.ports
        var status: ProviderStatus?

        while Date() < deadline {
            if !currentPorts.isEmpty,
               let s = await probeEndpoints(process: result.process, ports: currentPorts, deadline: deadline) {
                status = s
                break
            }
            let sleepInterval = min(0.4, max(0, deadline.timeIntervalSinceNow))
            guard sleepInterval > 0 else { break }
            try? await Task.sleep(nanoseconds: UInt64(sleepInterval * 1_000_000_000))
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            if let freshPorts = try? await AgProcessDetector.listeningPorts(
                pid: result.process.pid,
                timeout: min(1.0, remaining)
            ),
               !freshPorts.isEmpty {
                currentPorts = freshPorts
            }
        }

        // Terminate the spawned agy after we're done to avoid lingering processes
        result.spawnedProcess?.terminate()
        return status
    }

    /// Fetch quota cho MỘT account cụ thể đã lưu, bằng cách spawn một `agy`
    /// cô lập với HOME trỏ vào bản sao `.gemini/` riêng của account đó —
    /// KHÔNG đụng tới `~/.gemini` thật của user. Dùng khi agy chính (HOME
    /// thật) đang đăng nhập một account KHÁC account được yêu cầu.
    ///
    /// - Returns: `nil` khi account chưa có login cô lập (caller fallback
    ///   sang OAuth/mismatch như cũ) hoặc khi agy không mở port kịp thời gian
    ///   chờ — không bao giờ bịa dữ liệu. Trả về status lỗi "mismatch" nếu
    ///   agy cô lập lỡ trả về đúng account khác `expectedEmail` (bảo vệ khỏi
    ///   hiển thị nhầm account).
    func fetchViaIsolatedAgy(accountLabel: String, expectedEmail: String?) async -> ProviderStatus? {
        guard AntigravityIsolatedAgy.hasLogin(forAccountLabel: accountLabel) else { return nil }

        let deadline = Date().addingTimeInterval(Self.isolatedFetchDeadline)
        let result: (process: AgProcessInfo, ports: [Int], spawnedProcess: AgCLIWarmSession.AgSpawnedProcess?)
        do {
            result = try await AgCLIWarmSession.warmAndProbe(
                homeOverride: AntigravityIsolatedAgy.homeDir(forAccountLabel: accountLabel).path,
                args: ["-p", "ping", "--print-timeout", "40s"],
                overallTimeout: deadline.timeIntervalSinceNow,
                portWaitCap: Self.isolatedFetchDeadline
            )
        } catch {
            // agy binary missing hoặc port không mở kịp — bỏ qua, để caller fallback
            return nil
        }
        // Luôn dọn dẹp process agy đã spawn, kể cả khi nó tự thoát theo
        // --print-timeout — tránh leak process/zombie.
        defer { result.spawnedProcess?.terminate() }

        var currentPorts = result.ports
        var status: ProviderStatus?
        while Date() < deadline {
            if !currentPorts.isEmpty,
               let s = await probeEndpoints(
                   process: result.process,
                   ports: currentPorts,
                   deadline: deadline,
                   expectedEmailOverride: expectedEmail
               ) {
                status = s
                break
            }
            let sleepInterval = min(0.4, max(0, deadline.timeIntervalSinceNow))
            guard sleepInterval > 0 else { break }
            try? await Task.sleep(nanoseconds: UInt64(sleepInterval * 1_000_000_000))
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            if let freshPorts = try? await AgProcessDetector.listeningPorts(
                pid: result.process.pid,
                timeout: min(1.0, remaining)
            ),
               !freshPorts.isEmpty {
                currentPorts = freshPorts
            }
        }

        guard let status else { return nil }
        return status.withAccountLabel(expectedEmail ?? accountLabel)
    }

    /// Try all ports with quota-summary first, then user-status.
    ///
    /// - Parameter expectedEmailOverride: khi có giá trị, account-match guard
    ///   so khớp response email với GIÁ TRỊ NÀY thay vì account đang active
    ///   toàn cục — dùng bởi `fetchViaIsolatedAgy` để xác minh đúng account
    ///   cụ thể được yêu cầu, bất kể account nào đang active trong Settings.
    private func probeEndpoints(
        process: AgProcessInfo,
        ports: [Int],
        deadline: Date,
        expectedEmailOverride: String? = nil
    ) async -> ProviderStatus? {
        let schemes = ["http", "https"]
        for port in ports {
            for scheme in schemes {
                guard deadline.timeIntervalSinceNow > 0 else { return nil }
                if let status = await trySummaryEndpoint(
                    scheme: scheme,
                    port: port,
                    process: process,
                    deadline: deadline,
                    expectedEmailOverride: expectedEmailOverride
                ) {
                    return status
                }
                guard deadline.timeIntervalSinceNow > 0 else { return nil }
                if let status = await tryUserStatusEndpoint(
                    scheme: scheme,
                    port: port,
                    process: process,
                    deadline: deadline,
                    expectedEmailOverride: expectedEmailOverride
                ) {
                    return status
                }
            }
        }
        return nil
    }

    // MARK: Endpoint attempts

    private func trySummaryEndpoint(
        scheme: String,
        port: Int,
        process: AgProcessInfo,
        deadline: Date,
        expectedEmailOverride: String? = nil
    ) async -> ProviderStatus? {
        do {
            let requestTimeout = deadline.timeIntervalSinceNow
            guard requestTimeout > 0 else { return nil }
            let data = try await AntigravityHTTP.post(
                scheme: scheme,
                port: port,
                path: AntigravityHTTP.quotaSummaryPath,
                csrfToken: process.csrfToken,
                body: ["forceRefresh": true],
                timeout: min(timeout, requestTimeout)
            )
            let (groups, _, _) = try AgResponseParser.parseQuotaSummary(data)
            let windows = quotaWindowsFromSummary(groups)
            guard !windows.isEmpty else { return nil }

            // Best-effort: also fetch identity from user-status (non-fatal if fails)
            let (email, plan) = await fetchIdentity(
                scheme: scheme,
                port: port,
                process: process,
                deadline: deadline
            )

            // Account-match guard: nếu config chứa email, chỉ chấp nhận snapshot khớp
            if let mismatch = accountMismatchError(responseEmail: email, expectedEmailOverride: expectedEmailOverride) {
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
        process: AgProcessInfo,
        deadline: Date,
        expectedEmailOverride: String? = nil
    ) async -> ProviderStatus? {
        do {
            let requestTimeout = deadline.timeIntervalSinceNow
            guard requestTimeout > 0 else { return nil }
            let data = try await AntigravityHTTP.post(
                scheme: scheme,
                port: port,
                path: AntigravityHTTP.getUserStatusPath,
                csrfToken: process.csrfToken,
                body: AntigravityHTTP.defaultRequestBody(),
                timeout: min(timeout, requestTimeout)
            )
            let (quotas, email, plan) = try AgResponseParser.parseUserStatus(data)
            let windows = quotaWindows(from: quotas)
            guard !windows.isEmpty else { return nil }

            // Account-match guard: nếu config chứa email, chỉ chấp nhận snapshot khớp
            if let mismatch = accountMismatchError(responseEmail: email, expectedEmailOverride: expectedEmailOverride) {
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

    /// Prefer the selected OAuth account identity. The legacy config email is
    /// only a guard when the selected account has no known email.
    ///
    /// `expectedEmailOverride`, khi có, thay thế hoàn toàn account đang
    /// active toàn cục — dùng bởi `fetchViaIsolatedAgy` để so khớp với MỘT
    /// account cụ thể được yêu cầu (không phải account đang chọn trong
    /// Settings, vốn có thể là account khác).
    private func accountMismatchError(responseEmail: String?, expectedEmailOverride: String? = nil) -> String? {
        if let expectedEmailOverride {
            let trimmed = expectedEmailOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return Self._accountMismatchErrorForTesting(
                responseEmail: responseEmail,
                selectedEmail: trimmed,
                configLabel: nil
            )
        }
        let selectedEmail = AntigravityOAuthStore.activeAccount(
            in: AntigravityOAuthStore.load()
        )?.email
        let configLabel = BirdNionConfigStore.accountLabel(provider: id)
        return Self._accountMismatchErrorForTesting(
            responseEmail: responseEmail,
            selectedEmail: selectedEmail,
            configLabel: configLabel
        )
    }

    static func _accountMismatchErrorForTesting(
        responseEmail: String?,
        selectedEmail: String?,
        configLabel: String?
    ) -> String? {
        guard let expectedRaw = Self._expectedAccountEmailForTesting(
            selectedEmail: selectedEmail,
            configLabel: configLabel
        ) else { return nil }
        let expected = expectedRaw.lowercased()
        let found = responseEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let found, found == expected else {
            let foundDesc = responseEmail ?? "(không xác định)"
            let selected = selectedEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let selected, !selected.isEmpty {
                return "Account không khớp: đã chọn \"\(expectedRaw)\" nhưng đang đăng nhập \"\(foundDesc)\""
            }
            return "Account không khớp: cấu hình \"\(expectedRaw)\" nhưng đang đăng nhập \"\(foundDesc)\""
        }
        return nil
    }

    private func fetchIdentity(
        scheme: String,
        port: Int,
        process: AgProcessInfo,
        deadline: Date
    ) async -> (email: String?, plan: String?) {
        let requestTimeout = deadline.timeIntervalSinceNow
        guard requestTimeout > 0 else { return (nil, nil) }
        guard let data = try? await AntigravityHTTP.post(
            scheme: scheme,
            port: port,
            path: AntigravityHTTP.getUserStatusPath,
            csrfToken: process.csrfToken,
            body: AntigravityHTTP.defaultRequestBody(),
            timeout: min(min(timeout, requestTimeout), 1.5)
        ),
        let (_, email, plan) = try? AgResponseParser.parseUserStatus(data)
        else { return (nil, nil) }
        return (email, plan)
    }

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }

    /// Test-only: parse a RetrieveUserQuotaSummary body into semantic windows.
    func _parseQuotaSummaryForTesting(_ data: Data) throws -> [QuotaWindow] {
        let (groups, _, _) = try AgResponseParser.parseQuotaSummary(data)
        return quotaWindowsFromSummary(groups)
    }

    /// Test-only: expose deterministic process-list selection without running `ps`.
    static func _processIDsForTesting(_ output: String) -> [Int] {
        AgProcessDetector.parseProcessList(output).map(\.pid)
    }

    static func _shouldContinueAfterCandidateForTesting(error: String?) -> Bool {
        error?.hasPrefix("Account không khớp:") == true
    }

    static func _expectedAccountEmailForTesting(
        selectedEmail: String?,
        configLabel: String?
    ) -> String? {
        if let selected = selectedEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selected.isEmpty {
            return selected
        }
        guard let configured = configLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              configured.contains("@") else { return nil }
        return configured
    }
}
