import Foundation

/// OpenCode Go quota provider.
///
/// Authenticates via session cookies scraped from the user's browser.
/// Required cookies: `auth` or `__Host-auth` (set by opencode.ai — same as OpenCode).
///
/// Flow:
///   1. GET  https://opencode.ai/_server?id=<workspacesServerID>
///         -> parse workspace id ("wrk_...") from JS/JSON text
///   2. GET  https://opencode.ai/workspace/<workspaceID>/go
///         -> page HTML/JS containing usage objects
///   3. (optional) GET/billing server RPC + page parse for Zen balance (USD)
///
/// Usage response shape (embedded in Go workspace page):
/// ```js
/// {
///   rollingUsage: { usagePercent: 67.3, resetInSec: 12600 },
///   weeklyUsage:  { usagePercent: 34.1, resetInSec: 345600 },
///   monthlyUsage: { usagePercent: 18.0, resetInSec: 1296000 }  // optional
/// }
/// ```
///
/// Zen balance from billing RPC (server ID: c83b78a6...):
/// ```json
/// { "customerID": "...", "balance": 543210000 }
/// ```
/// Raw balance is divided by 100_000_000 to get USD.
///
/// Note: Like OpenCode, the `_server` protocol is SolidStart RPC with JS-serialised
/// payloads. We parse JSON and fall back to regex — best-effort.
final class OpenCodeGoProvider: QuotaProvider {
    let id = "opencodego"
    let displayName = "OpenCode Go"

    // Same domain as OpenCode — cookies are shared under opencode.ai.
    static let cookieDomain = "opencode.ai"
    static let allowedCookieNames: Set<String> = ["auth", "__Host-auth"]

    private static let baseURL = URL(string: "https://opencode.ai")!
    private static let serverURL = URL(string: "https://opencode.ai/_server")!
    private static let workspacesServerID =
        "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    private static let billingServerID =
        "c83b78a614689c38ebee981f9b39a8b377716db85c1fd7dbab604adc02d3313d"
    // Billing balance raw unit divisor (1 USD = 100_000_000 raw units).
    private static let billingScale = 100_000_000.0

    /// Usage over the Zen API, reachable with a plain API key. Only the Go tier
    /// exposes one: every path under `/zen/v1` (usage, me, balance, credits,
    /// subscription) answers 404, measured against a live key.
    private static let apiUsageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    private static let requestTimeout: TimeInterval = 15
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - QuotaProvider

    func fetch() async throws -> ProviderStatus {
        // A key is the direct path: one request, no browser session and no
        // workspace lookup. Cookies stay as the fallback rather than being
        // replaced, because the endpoint is entitlement-gated — a key from an
        // account without an OpenCode Go subscription cannot read usage at all,
        // while that account's browser session still can.
        var apiKeyError: String?
        if let key = Self.resolvedAPIKey() {
            let status = await fetchViaAPIKey(key)
            if status.error == nil { return status }
            apiKeyError = status.error
        }

        // Name the session cookie so a browser whose login has expired loses to
        // one that is still signed in — a stale analytics cookie must not win.
        guard let rawHeader = ProviderCookieReader.resolvedCookieHeader(
                  providerID: id,
                  domain: Self.cookieDomain,
                  matchingSession: { Self.allowedCookieNames.contains($0) }),
              !rawHeader.isEmpty
        else {
            // With a key configured its rejection is the actionable message;
            // "not signed in to the browser" would send the user to the wrong
            // place entirely.
            return failure(apiKeyError ?? "Chưa đăng nhập OpenCode Go trên trình duyệt")
        }

        guard let cookieHeader = Self.filteredCookieHeader(from: rawHeader) else {
            return failure(apiKeyError ?? "Không tìm thấy cookie đăng nhập OpenCode Go (cần auth hoặc __Host-auth)")
        }

        let accountLabel = BirdNionConfigStore.accountLabel(provider: id) ?? "opencodego"

        // Step 1: workspace id.
        let workspaceID: String
        do {
            workspaceID = try await fetchWorkspaceID(cookieHeader: cookieHeader)
        } catch {
            return failure("Không lấy được workspace: \(error.localizedDescription)")
        }

        // Steps 2 & 3 run concurrently: usage page + Zen balance.
        async let usageTask: String = fetchGoPage(workspaceID: workspaceID, cookieHeader: cookieHeader)
        async let zenTask: Double? = fetchZenBalance(workspaceID: workspaceID, cookieHeader: cookieHeader)

        let usageText: String
        do {
            usageText = try await usageTask
        } catch {
            // If usage page fails, try to return Zen-balance-only status.
            let zen = try? await zenTask
            if let zen {
                return buildZenOnlyStatus(zenUSD: zen, accountLabel: accountLabel)
            }
            return failure("Không lấy được usage: \(error.localizedDescription)")
        }

        let zenBalance = try? await zenTask

        return parse(text: usageText, zenBalance: zenBalance, accountLabel: accountLabel)
    }

    // MARK: - API key path

    /// Resolved Zen API key: env var first (so a shell already configured for
    /// the OpenCode CLI needs no re-entry), then the provider entry in the
    /// BirdNion config file. Internal for testing.
    static func resolvedAPIKey(
        env: [String: String] = ProcessInfo.processInfo.environment,
        configKey: String? = BirdNionConfigStore.apiKey(provider: "opencodego")
    ) -> String? {
        for name in ["OPENCODE_API_KEY", "OPENCODE_ZEN_API_KEY"] {
            if let value = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty
            {
                return value
            }
        }
        guard let configKey = configKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !configKey.isEmpty
        else { return nil }
        return configKey
    }

    private func fetchViaAPIKey(_ key: String) async -> ProviderStatus {
        var request = URLRequest(url: Self.apiUsageURL)
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Cloudflare fronts opencode.ai and answers 403 (code 1010) to a request
        // with no browser agent, before it ever reaches the API. Measured.
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return failure("OpenCode Go API: \(error.localizedDescription)")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            return failure("OpenCode Go API: \(Self.apiErrorMessage(data, status: code))")
        }

        let accountLabel = BirdNionConfigStore.accountLabel(provider: id) ?? "opencodego"
        let status = parse(
            text: String(data: data, encoding: .utf8) ?? "",
            zenBalance: nil,
            accountLabel: accountLabel)
        return status.error == nil ? status.withSourceLabel("API key") : status
    }

    /// Surface the server's own wording. "OpenCode Go subscription required"
    /// tells the user what to do; "HTTP 403" sends them hunting. Internal for
    /// testing.
    static func apiErrorMessage(_ data: Data, status: Int) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let nested = root["error"] as? [String: Any]
            let message = (nested?["message"] as? String) ?? (root["message"] as? String)
            if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "\(message) (HTTP \(status))"
            }
        }
        return "HTTP \(status)"
    }

    // MARK: - Parse (exposed for testing — no network I/O)

    /// Parse canned page text (+ optional zen balance) into a ProviderStatus.
    static func _parseForTesting(pageText: String, zenBalance: Double?) -> ProviderStatus {
        let p = OpenCodeGoProvider()
        return p.parse(text: pageText, zenBalance: zenBalance, accountLabel: "test")
    }

    // MARK: - Private networking

    private func fetchWorkspaceID(cookieHeader: String) async throws -> String {
        let text = try await fetchServerText(
            serverID: Self.workspacesServerID,
            args: nil,
            method: "GET",
            referer: Self.baseURL,
            cookieHeader: cookieHeader)

        if Self.looksSignedOut(text) { throw URLError(.userAuthenticationRequired) }

        var ids = Self.parseWorkspaceIDs(from: text)
        if ids.isEmpty {
            let fallback = try await fetchServerText(
                serverID: Self.workspacesServerID,
                args: "[]",
                method: "POST",
                referer: Self.baseURL,
                cookieHeader: cookieHeader)
            if Self.looksSignedOut(fallback) { throw URLError(.userAuthenticationRequired) }
            ids = Self.parseWorkspaceIDs(from: fallback)
        }

        guard let first = ids.first else { throw URLError(.cannotParseResponse) }
        return first
    }

    private func fetchGoPage(workspaceID: String, cookieHeader: String) async throws -> String {
        let url = URL(string: "\(Self.baseURL)/workspace/\(workspaceID)/go") ?? Self.baseURL
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = Self.requestTimeout
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 || http.statusCode == 403 { throw URLError(.userAuthenticationRequired) }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotParseResponse) }
        if Self.looksSignedOut(text) { throw URLError(.userAuthenticationRequired) }
        return text
    }

    /// Fetch Zen balance; returns nil on any error (optional enrichment).
    private func fetchZenBalance(workspaceID: String, cookieHeader: String) async -> Double? {
        // First try to parse balance directly from the workspace page.
        if let pageText = try? await fetchGoPage(workspaceID: workspaceID, cookieHeader: cookieHeader),
           let balance = Self.parseZenBalanceFromPage(pageText)
        {
            return balance
        }

        // Fallback: billing server RPC.
        guard let argsData = try? JSONSerialization.data(withJSONObject: [workspaceID], options: []),
              let argsStr = String(data: argsData, encoding: .utf8)
        else { return nil }

        let referer = URL(string: "\(Self.baseURL)/workspace/\(workspaceID)") ?? Self.baseURL
        let billingText = try? await fetchServerText(
            serverID: Self.billingServerID,
            args: argsStr,
            method: "GET",
            referer: referer,
            cookieHeader: cookieHeader)

        return billingText.flatMap { Self.parseBillingBalance($0) }
    }

    private func fetchServerText(
        serverID: String,
        args: String?,
        method: String,
        referer: URL,
        cookieHeader: String
    ) async throws -> String {
        let url = Self.serverURL(serverID: serverID, args: args, isGet: method == "GET")
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = Self.requestTimeout
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(serverID, forHTTPHeaderField: "X-Server-Id")
        req.setValue("server-fn:\(UUID().uuidString)", forHTTPHeaderField: "X-Server-Instance")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(Self.baseURL.absoluteString, forHTTPHeaderField: "Origin")
        req.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        req.setValue("text/javascript, application/json;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        if method != "GET", let args {
            req.httpBody = args.data(using: .utf8)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 || http.statusCode == 403 { throw URLError(.userAuthenticationRequired) }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotParseResponse) }
        return text
    }

    // MARK: - Private parsing

    private func parse(text: String, zenBalance: Double?, accountLabel: String) -> ProviderStatus {
        let now = Date()
        var windows: [QuotaWindow] = []
        var renewsAt: Date? = nil

        // Try JSON first, then regex.
        if let (snap, renew) = Self.parseJSONUsage(text: text, now: now) {
            windows = snap
            renewsAt = renew
        } else if let snap = Self.parseRegexUsage(text: text, now: now) {
            windows = snap
            // Regex path: attempt to extract renewAt from raw text as a fallback.
            let renewAliases = ["renewAt", "renewsAt", "renew_at", "renews_at"]
            for alias in renewAliases {
                let pattern = #""\#(alias)"\s*:\s*"([^"]+)""#
                if let rx = try? NSRegularExpression(pattern: pattern),
                   let m = rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                   let r = Range(m.range(at: 1), in: text)
                {
                    renewsAt = Self.dateValue(String(text[r]))
                    if renewsAt != nil { break }
                }
            }
        }

        if windows.isEmpty && zenBalance == nil {
            return failure("Không thể phân tích dữ liệu usage OpenCode Go")
        }

        // Info-only "Gia hạn" row — only when renewal date is known.
        if let renewDate = renewsAt {
            windows.append(QuotaWindow(
                label: "Gia hạn",
                usedPct: 0,
                remainingPct: 100,
                subtitle: Self.shortDate(renewDate),
                resetDate: renewDate))
        }

        let cost: ProviderCostSnapshot? = zenBalance.map {
            ProviderCostSnapshot(
                used: $0,
                limit: 0,
                currencyCode: "USD",
                period: "Zen balance",
                updatedAt: now)
        }

        return ProviderStatus(
            id: id,
            displayName: displayName,
            windows: windows,
            lastUpdated: now,
            error: nil,
            accountLabel: accountLabel,
            cost: cost)
    }

    private func buildZenOnlyStatus(zenUSD: Double, accountLabel: String) -> ProviderStatus {
        let now = Date()
        let cost = ProviderCostSnapshot(
            used: zenUSD,
            limit: 0,
            currencyCode: "USD",
            period: "Zen balance",
            updatedAt: now)
        return ProviderStatus(
            id: id,
            displayName: displayName,
            windows: [],
            lastUpdated: now,
            error: nil,
            accountLabel: accountLabel,
            cost: cost)
    }

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }

    // MARK: - JSON usage parsing

    private static func parseJSONUsage(text: String, now: Date) -> ([QuotaWindow], Date?)? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any]
        else { return nil }

        // Walk wrappers.
        if let result = buildWindowsFromDict(dict, now: now) { return result }
        for key in ["data", "result", "usage", "billing", "payload"] {
            if let nested = dict[key] as? [String: Any],
               let result = buildWindowsFromDict(nested, now: now) { return result }
        }
        return nil
    }

    private static func buildWindowsFromDict(_ dict: [String: Any], now: Date) -> ([QuotaWindow], Date?)? {
        let rollingKeys = ["rollingUsage", "rolling", "rolling_usage", "rollingWindow"]
        let weeklyKeys  = ["weeklyUsage", "weekly", "weekly_usage", "weeklyWindow"]
        let monthlyKeys = ["monthlyUsage", "monthly", "monthly_usage", "monthlyWindow"]

        guard let rollingDict = firstDict(from: dict, keys: rollingKeys),
              let weeklyDict  = firstDict(from: dict, keys: weeklyKeys),
              let rolling     = parseWindow(rollingDict, now: now),
              let weekly      = parseWindow(weeklyDict, now: now)
        else { return nil }

        let monthly = firstDict(from: dict, keys: monthlyKeys).flatMap { parseWindow($0, now: now) }
        let scale = percentScale([rolling, weekly, monthly].compactMap { $0?.percent })

        var windows: [QuotaWindow] = [
            makeWindow(label: "Rolling", result: rolling, scale: scale, windowSec: 5 * 3600),
            makeWindow(label: "Tuần", result: weekly, scale: scale, windowSec: 7 * 24 * 3600),
        ]
        if let monthly {
            windows.append(makeWindow(label: "Tháng", result: monthly, scale: scale, windowSec: 30 * 24 * 3600))
        }

        // Parse subscription renewal date — aliases: renewAt / renewsAt / renew_at / renews_at.
        let renewAliases = ["renewAt", "renewsAt", "renew_at", "renews_at"]
        let renewsAt = renewAliases.lazy.compactMap { dateValue(dict[$0]) }.first

        return (windows, renewsAt)
    }

    // MARK: - Regex usage parsing (fallback for JS text)

    private static func parseRegexUsage(text: String, now: Date) -> [QuotaWindow]? {
        guard let rollingPct = extractDouble(
                pattern: #"rollingUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, text: text),
              let rollingReset = extractInt(
                pattern: #"rollingUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#, text: text),
              let weeklyPct = extractDouble(
                pattern: #"weeklyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, text: text),
              let weeklyReset = extractInt(
                pattern: #"weeklyUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#, text: text)
        else { return nil }

        let monthlyPct = extractDouble(
            pattern: #"monthlyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, text: text)
        let monthlyReset = extractInt(
            pattern: #"monthlyUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#, text: text)

        let scale = percentScale([rollingPct, weeklyPct, monthlyPct].compactMap { $0 })
        var windows = [
            makeWindow(
                label: "Rolling",
                result: WindowResult(percent: rollingPct, resetSec: rollingReset),
                scale: scale,
                windowSec: 5 * 3600),
            makeWindow(
                label: "Tuần",
                result: WindowResult(percent: weeklyPct, resetSec: weeklyReset),
                scale: scale,
                windowSec: 7 * 24 * 3600),
        ]
        if let mPct = monthlyPct, let mReset = monthlyReset {
            windows.append(makeWindow(
                label: "Tháng",
                result: WindowResult(percent: mPct, resetSec: mReset),
                scale: scale,
                windowSec: 30 * 24 * 3600))
        }
        return windows
    }

    // MARK: - Zen balance parsers

    private static func parseZenBalanceFromPage(_ text: String) -> Double? {
        // Try JSON embedded in page.
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: [])
        {
            if let v = findExplicitBalance(in: obj) { return v }
        }
        // Regex: "$X.XX" near "balance" keyword.
        let nearby = #"(?i)(?:balance|残高)[\s\S]{0,120}?\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)"#
        return extractDoubleMatch(pattern: nearby, text: text)
    }

    private static func findExplicitBalance(in obj: Any) -> Double? {
        let explicitKeys: Set<String> = [
            "zenbalance", "zencurrentbalance", "currentbalance",
            "currentbalanceusd", "balanceusd", "usdbalance",
        ]
        if let dict = obj as? [String: Any] {
            for (key, value) in dict {
                let norm = key.lowercased().filter { $0.isLetter || $0.isNumber }
                if explicitKeys.contains(norm), let d = doubleValue(value) { return d }
                if let found = findExplicitBalance(in: value) { return found }
            }
        } else if let arr = obj as? [Any] {
            for item in arr { if let found = findExplicitBalance(in: item) { return found } }
        }
        return nil
    }

    /// Parse billing server RPC response; raw balance / 100_000_000 = USD.
    private static func parseBillingBalance(_ text: String) -> Double? {
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: []),
           let raw = findBillingBalance(in: obj)
        {
            return raw / billingScale
        }
        // Regex fallback: requires customerID context.
        let customerPattern = #"(?:\"customerID\"|customerID)\s*:\s*(?:\$R\[\d+\]\s*=\s*)?\"[^\"]+"#
        guard containsMatch(pattern: customerPattern, text: text) else { return nil }
        let balancePattern = #"(?:\"balance\"|balance)\s*:\s*(?:\$R\[\d+\]\s*=\s*)?(-?[0-9]+(?:\.[0-9]+)?)"#
        guard let raw = extractDoubleMatch(pattern: balancePattern, text: text) else { return nil }
        return raw / billingScale
    }

    private static func findBillingBalance(in obj: Any) -> Double? {
        if let dict = obj as? [String: Any] {
            if dict["balance"] != nil {
                guard let customerID = dict["customerID"] as? String, !customerID.isEmpty else { return nil }
                return doubleValue(dict["balance"])
            }
            for v in dict.values { if let found = findBillingBalance(in: v) { return found } }
        } else if let arr = obj as? [Any] {
            for v in arr { if let found = findBillingBalance(in: v) { return found } }
        }
        return nil
    }

    // MARK: - Workspace ID parsing (same logic as OpenCodeProvider)

    private static func parseWorkspaceIDs(from text: String) -> [String] {
        let pattern = #"id\s*:\s*\"(wrk_[^\"]+)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        var ids = regex.matches(in: text, options: [], range: nsrange).compactMap { m -> String? in
            guard let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
        if ids.isEmpty, let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: [])
        {
            var collected: [String] = []
            collectWorkspaceIDs(in: obj, out: &collected)
            ids = collected
        }
        return ids
    }

    private static func collectWorkspaceIDs(in obj: Any, out: inout [String]) {
        if let dict = obj as? [String: Any] {
            dict.values.forEach { collectWorkspaceIDs(in: $0, out: &out) }
        } else if let arr = obj as? [Any] {
            arr.forEach { collectWorkspaceIDs(in: $0, out: &out) }
        } else if let s = obj as? String, s.hasPrefix("wrk_"), !out.contains(s) {
            out.append(s)
        }
    }

    // MARK: - Cookie filtering

    private static func filteredCookieHeader(from raw: String) -> String? {
        let pairs = raw.split(separator: ";").compactMap { chunk -> (String, String)? in
            let t = chunk.trimmingCharacters(in: .whitespaces)
            guard let eq = t.firstIndex(of: "=") else { return nil }
            let name = String(t[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty, allowedCookieNames.contains(name) else { return nil }
            return (name, value)
        }
        guard !pairs.isEmpty else { return nil }
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    // MARK: - Heuristics

    private static func looksSignedOut(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("login") || lower.contains("sign in") ||
            lower.contains("auth/authorize") || lower.contains("actor of type \"public\"")
    }

    // MARK: - URL builder

    private static func serverURL(serverID: String, args: String?, isGet: Bool) -> URL {
        guard isGet else { return serverURL }
        var c = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "id", value: serverID)]
        if let args, !args.isEmpty { items.append(URLQueryItem(name: "args", value: args)) }
        c?.queryItems = items
        return c?.url ?? serverURL
    }

    // MARK: - Window building helpers

    private struct WindowResult {
        let percent: Double
        let resetSec: Int
    }

    private static let percentKeys = [
        "usagePercent", "usedPercent", "percentUsed", "percent",
        "usage_percent", "utilization",
    ]
    private static let resetInKeys = [
        "resetInSec", "resetInSeconds", "resetSec", "reset_sec", "resetsInSec",
    ]
    private static let resetAtKeys = ["resetAt", "resetsAt", "reset_at", "nextReset", "renewAt"]

    private static func parseWindow(_ dict: [String: Any], now: Date) -> WindowResult? {
        var pct: Double?
        for key in percentKeys {
            if let v = doubleValue(dict[key]) { pct = v; break }
        }
        if pct == nil {
            if let used = doubleValue(dict["used"]) ?? doubleValue(dict["usage"]),
               let limit = doubleValue(dict["limit"]) ?? doubleValue(dict["total"]),
               limit > 0
            { pct = used / limit * 100 }
        }
        guard let resolvedPct = pct else { return nil }

        var resetSec: Int?
        for key in resetInKeys {
            if let v = intValue(dict[key]) { resetSec = v; break }
        }
        if resetSec == nil {
            for key in resetAtKeys {
                if let d = dateValue(dict[key]) {
                    resetSec = max(0, Int(d.timeIntervalSinceNow)); break
                }
            }
        }

        return WindowResult(percent: resolvedPct, resetSec: max(0, resetSec ?? 0))
    }

    /// One payload mixes either 0-1 fractions or 0-100 percents — never both.
    /// Decide once per payload: a bare `1` is ambiguous, so only a fractional
    /// value proves the 0-1 form. The live Zen API returns integer percents
    /// (`"weekly": {"percent": 1}` = 1% used, not 100%).
    private static func percentScale(_ percents: [Double]) -> Double {
        let inUnitRange = percents.allSatisfy { (0.0...1.0).contains($0) }
        let hasFraction = percents.contains { $0.truncatingRemainder(dividingBy: 1) != 0 }
        return (inUnitRange && hasFraction) ? 100 : 1
    }

    private static func makeWindow(
        label: String, result: WindowResult, scale: Double, windowSec: Int
    ) -> QuotaWindow {
        let used = Int((result.percent * scale).rounded()).clamped(to: 0...100)
        let now = Date()
        let resetDate = now.addingTimeInterval(TimeInterval(result.resetSec))
        return QuotaWindow(
            label: label,
            usedPct: used,
            remainingPct: 100 - used,
            subtitle: "\(used)%",
            resetDate: resetDate,
            windowSeconds: windowSec)
    }

    // MARK: - Value coercion

    private static func doubleValue(_ raw: Any?) -> Double? {
        switch raw {
        case let n as Double: return n.isFinite ? n : nil
        case let n as NSNumber: let d = n.doubleValue; return d.isFinite ? d : nil
        case let s as String:
            let c = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
            return Double(c)
        default: return nil
        }
    }

    private static func intValue(_ raw: Any?) -> Int? {
        switch raw {
        case let n as Int: return n
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    private static func dateValue(_ raw: Any?) -> Date? {
        if let d = doubleValue(raw) {
            if d > 1_000_000_000_000 { return Date(timeIntervalSince1970: d / 1000) }
            if d > 1_000_000_000 { return Date(timeIntervalSince1970: d) }
        }
        if let s = raw as? String {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fmt.date(from: s) { return d }
        }
        return nil
    }

    /// Short human date for the info-only "Gia hạn" (renewal) row.
    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    private static func firstDict(from dict: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys { if let v = dict[key] as? [String: Any] { return v } }
        return nil
    }

    private static func extractDouble(pattern: String, text: String) -> Double? {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = rx.firstMatch(in: text, options: [], range: range),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return Double(text[r])
    }

    private static func extractDoubleMatch(pattern: String, text: String) -> Double? {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = rx.firstMatch(in: text, options: [], range: range),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return Double(text[r].replacingOccurrences(of: ",", with: ""))
    }

    private static func extractInt(pattern: String, text: String) -> Int? {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = rx.firstMatch(in: text, options: [], range: range),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return Int(text[r])
    }

    private static func containsMatch(pattern: String, text: String) -> Bool {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return rx.firstMatch(in: text, options: [], range: range) != nil
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
