import Foundation

/// OpenCode quota provider.
///
/// Authenticates via session cookies scraped from the user's browser.
/// Required cookies: `auth` or `__Host-auth` (set by opencode.ai).
///
/// Flow:
///   1. GET  https://opencode.ai/_server?id=<workspacesServerID>
///         -> parse workspace id ("wrk_...") from JS/JSON text
///   2. GET  https://opencode.ai/_server?id=<subscriptionServerID>&args=[<workspaceID>]
///         (fallback: POST with body ["<workspaceID>"])
///         -> text/JS containing `rollingUsage` + `weeklyUsage` objects with
///            `usagePercent` (0-100 or 0-1) and `resetInSec` fields.
///
/// Response shape (embedded JS object or JSON):
/// ```js
/// {
///   rollingUsage: { usagePercent: 67.3, resetInSec: 12600 },
///   weeklyUsage:  { usagePercent: 34.1, resetInSec: 345600 }
/// }
/// ```
/// Field names vary — the parser scans aliases for percent and reset values.
///
/// Note: The `_server` RPC protocol embeds serialized JS (SolidStart/TanStack
/// server functions). We parse both JSON and regex fallback — best-effort on
/// the wire format.
final class OpenCodeProvider: QuotaProvider {
    let id = "opencode"
    let displayName = "OpenCode"

    // opencode.ai sets `auth` / `__Host-auth` cookies.
    static let cookieDomain = "opencode.ai"
    // Cookies we forward to the API (filter out unrelated noise).
    static let allowedCookieNames: Set<String> = ["auth", "__Host-auth"]

    private static let baseURL = URL(string: "https://opencode.ai")!
    private static let serverURL = URL(string: "https://opencode.ai/_server")!
    // Server function IDs — ported from OpenCodeUsageFetcher.
    private static let workspacesServerID =
        "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    private static let subscriptionServerID =
        "7abeebee372f304e050aaaf92be863f4a86490e382f8c79db68fd94040d691b4"

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
        // Name the session cookie so a browser whose login has expired loses to
        // one that is still signed in — a stale analytics cookie must not win.
        var browserDenied = false
        guard let rawHeader = ProviderCookieReader.resolvedCookieHeader(
                  providerID: id,
                  domain: Self.cookieDomain,
                  matchingSession: { Self.allowedCookieNames.contains($0) },
                  permissionDenied: &browserDenied),
              !rawHeader.isEmpty
        else {
            return failure(browserDenied
                ? ProviderCookieReader.browserDataDeniedMessage
                : "Chưa đăng nhập OpenCode trên trình duyệt")
        }

        guard let cookieHeader = Self.filteredCookieHeader(from: rawHeader) else {
            return failure("Không tìm thấy cookie đăng nhập OpenCode (cần auth hoặc __Host-auth)")
        }

        let accountLabel = BirdNionConfigStore.accountLabel(provider: id) ?? "opencode"

        // Step 1: get workspace id.
        let workspaceID: String
        do {
            workspaceID = try await fetchWorkspaceID(cookieHeader: cookieHeader)
        } catch {
            return failure("Không lấy được workspace: \(error.localizedDescription)")
        }

        // Step 2: get subscription/usage.
        let text: String
        do {
            text = try await fetchSubscription(workspaceID: workspaceID, cookieHeader: cookieHeader)
        } catch {
            return failure("Không lấy được usage: \(error.localizedDescription)")
        }

        return parse(text: text, accountLabel: accountLabel)
    }

    // MARK: - Parse (exposed for testing — no network I/O)

    /// Parse a canned subscription text into a ProviderStatus.
    static func _parseForTesting(subscriptionText: String) -> ProviderStatus {
        let p = OpenCodeProvider()
        return p.parse(text: subscriptionText, accountLabel: "test")
    }

    // MARK: - Private networking

    private func fetchWorkspaceID(cookieHeader: String) async throws -> String {
        let text = try await fetchServerText(
            serverID: Self.workspacesServerID,
            args: nil,
            method: "GET",
            referer: Self.baseURL,
            cookieHeader: cookieHeader)

        if Self.looksSignedOut(text) {
            throw URLError(.userAuthenticationRequired)
        }

        var ids = Self.parseWorkspaceIDs(from: text)
        if ids.isEmpty {
            // Fallback: POST with empty args array.
            let fallback = try await fetchServerText(
                serverID: Self.workspacesServerID,
                args: "[]",
                method: "POST",
                referer: Self.baseURL,
                cookieHeader: cookieHeader)
            if Self.looksSignedOut(fallback) {
                throw URLError(.userAuthenticationRequired)
            }
            ids = Self.parseWorkspaceIDs(from: fallback)
        }

        guard let first = ids.first else {
            throw URLError(.cannotParseResponse)
        }
        return first
    }

    private func fetchSubscription(workspaceID: String, cookieHeader: String) async throws -> String {
        let referer = URL(string: "\(Self.baseURL)/workspace/\(workspaceID)/billing") ?? Self.baseURL
        let argsJSON = try! JSONSerialization.data(withJSONObject: [workspaceID], options: [])
        let argsStr = String(data: argsJSON, encoding: .utf8)!

        let text = try await fetchServerText(
            serverID: Self.subscriptionServerID,
            args: argsStr,
            method: "GET",
            referer: referer,
            cookieHeader: cookieHeader)

        if Self.looksSignedOut(text) {
            throw URLError(.userAuthenticationRequired)
        }

        // If GET payload seems missing usage fields, retry with POST.
        if !Self.hasUsageFields(text) {
            let fallback = try await fetchServerText(
                serverID: Self.subscriptionServerID,
                args: argsStr,
                method: "POST",
                referer: referer,
                cookieHeader: cookieHeader)
            if Self.looksSignedOut(fallback) {
                throw URLError(.userAuthenticationRequired)
            }
            return fallback
        }

        return text
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
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw URLError(.userAuthenticationRequired)
        }
        guard http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        return text
    }

    // MARK: - Private parsing

    private func parse(text: String, accountLabel: String) -> ProviderStatus {
        // Try JSON path first, then regex fallback.
        if let snapshot = Self.parseJSON(text: text) {
            return buildStatus(from: snapshot, accountLabel: accountLabel)
        }

        // Regex fallback: extract rolling + weekly directly from JS-like text.
        guard let rollingPct = Self.extractDouble(
                pattern: #"rollingUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, text: text),
              let rollingReset = Self.extractInt(
                pattern: #"rollingUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#, text: text),
              let weeklyPct = Self.extractDouble(
                pattern: #"weeklyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, text: text),
              let weeklyReset = Self.extractInt(
                pattern: #"weeklyUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#, text: text)
        else {
            return failure("Không thể phân tích dữ liệu usage OpenCode")
        }

        let snap = Snapshot(
            rollingPercent: Self.normalizePercent(rollingPct),
            weeklyPercent: Self.normalizePercent(weeklyPct),
            rollingResetSec: rollingReset,
            weeklyResetSec: weeklyReset)
        return buildStatus(from: snap, accountLabel: accountLabel)
    }

    private func buildStatus(from snap: Snapshot, accountLabel: String) -> ProviderStatus {
        let now = Date()
        let rollingReset = now.addingTimeInterval(TimeInterval(snap.rollingResetSec))
        let weeklyReset = now.addingTimeInterval(TimeInterval(snap.weeklyResetSec))

        let rollingUsed = Int(snap.rollingPercent.rounded()).clamped(to: 0...100)
        let weeklyUsed = Int(snap.weeklyPercent.rounded()).clamped(to: 0...100)

        var windows: [QuotaWindow] = [
            QuotaWindow(
                label: "Rolling",
                usedPct: rollingUsed,
                remainingPct: 100 - rollingUsed,
                subtitle: "\(rollingUsed)%",
                resetDate: rollingReset,
                windowSeconds: 5 * 3600),
            QuotaWindow(
                label: "Tuần",
                usedPct: weeklyUsed,
                remainingPct: 100 - weeklyUsed,
                subtitle: "\(weeklyUsed)%",
                resetDate: weeklyReset,
                windowSeconds: 7 * 24 * 3600),
        ]

        // Info-only "Gia hạn" row showing the plan renewal date (CodexBar's
        // renewAt extra window). usedPct=0 so it renders as a neutral date row.
        if let renewsAt = snap.renewsAt {
            windows.append(QuotaWindow(
                label: "Gia hạn",
                usedPct: 0,
                remainingPct: 100,
                subtitle: Self.shortDate(renewsAt),
                resetDate: renewsAt))
        }

        return ProviderStatus(
            id: id,
            displayName: displayName,
            windows: windows,
            lastUpdated: now,
            error: nil,
            accountLabel: accountLabel)
    }

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }

    // MARK: - JSON parsing helpers

    private struct Snapshot {
        let rollingPercent: Double
        let weeklyPercent: Double
        let rollingResetSec: Int
        let weeklyResetSec: Int
        /// Subscription renewal date parsed from `renewAt` / `renewsAt` / `renew_at` / `renews_at`.
        let renewsAt: Date?

        init(rollingPercent: Double, weeklyPercent: Double,
             rollingResetSec: Int, weeklyResetSec: Int, renewsAt: Date? = nil) {
            self.rollingPercent = rollingPercent
            self.weeklyPercent = weeklyPercent
            self.rollingResetSec = rollingResetSec
            self.weeklyResetSec = weeklyResetSec
            self.renewsAt = renewsAt
        }
    }

    private static func parseJSON(text: String) -> Snapshot? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any]
        else { return nil }

        // Direct, or nested under data/result/usage/billing/payload.
        if let snap = parseUsageDict(dict) { return snap }
        for key in ["data", "result", "usage", "billing", "payload"] {
            if let nested = dict[key] as? [String: Any],
               let snap = parseUsageDict(nested) { return snap }
        }
        return nil
    }

    private static func parseUsageDict(_ dict: [String: Any]) -> Snapshot? {
        let rollingKeys = ["rollingUsage", "rolling", "rolling_usage", "rollingWindow"]
        let weeklyKeys  = ["weeklyUsage", "weekly", "weekly_usage", "weeklyWindow"]

        guard let rollingDict = firstDict(from: dict, keys: rollingKeys),
              let weeklyDict  = firstDict(from: dict, keys: weeklyKeys)
        else { return nil }

        guard let rollingWin = parseWindow(rollingDict),
              let weeklyWin  = parseWindow(weeklyDict)
        else { return nil }

        // Parse subscription renewal date — aliases: renewAt / renewsAt / renew_at / renews_at.
        let renewAliases = ["renewAt", "renewsAt", "renew_at", "renews_at"]
        let renewsAt = renewAliases.lazy.compactMap { dateValue(dict[$0]) }.first

        return Snapshot(
            rollingPercent: rollingWin.percent,
            weeklyPercent: weeklyWin.percent,
            rollingResetSec: rollingWin.resetSec,
            weeklyResetSec: weeklyWin.resetSec,
            renewsAt: renewsAt)
    }

    private struct WindowResult {
        let percent: Double
        let resetSec: Int
    }

    private static let percentKeys = [
        "usagePercent", "usedPercent", "percentUsed", "percent",
        "usage_percent", "utilization",
    ]
    private static let resetInKeys = [
        "resetInSec", "resetInSeconds", "resetSec", "reset_sec",
        "resetsInSec", "resetIn",
    ]
    private static let resetAtKeys = [
        "resetAt", "resetsAt", "reset_at", "nextReset", "renewAt",
    ]

    private static func parseWindow(_ dict: [String: Any]) -> WindowResult? {
        var pct: Double?
        for key in percentKeys {
            if let v = doubleValue(dict[key]) { pct = v; break }
        }
        if pct == nil {
            if let used = doubleValue(dict["used"]) ?? doubleValue(dict["usage"]),
               let limit = doubleValue(dict["limit"]) ?? doubleValue(dict["total"]),
               limit > 0
            {
                pct = used / limit * 100
            }
        }
        guard var resolvedPct = pct else { return nil }
        resolvedPct = normalizePercent(resolvedPct)

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

    // MARK: - Workspace ID parsing

    private static func parseWorkspaceIDs(from text: String) -> [String] {
        // JS pattern: id: "wrk_..."
        let pattern = #"id\s*:\s*\"(wrk_[^\"]+)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        var ids = regex.matches(in: text, options: [], range: nsrange).compactMap { m -> String? in
            guard let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
        // JSON fallback.
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

    private static func hasUsageFields(_ text: String) -> Bool {
        text.contains("rollingUsage") || text.contains("rolling_usage") ||
            text.contains("weeklyUsage") || text.contains("weekly_usage")
    }

    // MARK: - URL builder

    private static func serverURL(serverID: String, args: String?, isGet: Bool) -> URL {
        guard isGet else { return serverURL }
        var c = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "id", value: serverID)]
        if let args, !args.isEmpty {
            items.append(URLQueryItem(name: "args", value: args))
        }
        c?.queryItems = items
        return c?.url ?? serverURL
    }

    // MARK: - Value coercion

    private static func normalizePercent(_ v: Double) -> Double {
        // Values in [0, 1] treated as fraction — multiply to get %.
        let scaled = (v <= 1.0 && v >= 0) ? v * 100 : v
        return max(0, min(100, scaled))
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        switch raw {
        case let n as Double: return n.isFinite ? n : nil
        case let n as NSNumber: let d = n.doubleValue; return d.isFinite ? d : nil
        case let s as String: return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
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
            let withFrac = ISO8601DateFormatter()
            withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = withFrac.date(from: s) { return d }
            // Fallback: dates without fractional seconds (e.g. "2026-07-01T00:00:00Z").
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let d = plain.date(from: s) { return d }
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
        for key in keys {
            if let v = dict[key] as? [String: Any] { return v }
        }
        return nil
    }

    private static func extractDouble(pattern: String, text: String) -> Double? {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = rx.firstMatch(in: text, options: [], range: range),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return Double(text[r])
    }

    private static func extractInt(pattern: String, text: String) -> Int? {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = rx.firstMatch(in: text, options: [], range: range),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return Int(text[r])
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
