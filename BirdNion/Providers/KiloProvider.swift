import Foundation

/// Kilo Code usage provider.
///
/// Endpoint: tRPC batch GET
///   `https://app.kilo.ai/api/trpc/user.getCreditBlocks,kiloPass.getState,user.getAutoTopUpPaymentMethod`
///   Query: `batch=1&input={"0":{"json":null},"1":{"json":null},"2":{"json":null}}`
///
/// Auth: `Authorization: Bearer <key>` — key sourced from config API key or CLI `~/.config/kilocode/auth.json`.
/// Optional header `X-KILOCODE-ORGANIZATIONID` for org scoping (when scope != personal).
///
/// tRPC batch response shape (array, one entry per procedure):
/// ```json
/// [
///   { "result": { "data": { "json": { "creditBlocks": [...], "totalBalance_mUsd": 0 } } } },
///   { "result": { "data": { "json": { "subscription": { "tier": "tier_49", "currentPeriodUsageUsd": 12.5, ... } } } } },
///   { "result": { "data": { "json": { "enabled": true, "paymentMethod": "visa" } } } }
/// ]
/// ```
///
/// Credit blocks shape (`creditBlocks` array):
///   `{ "amount_mUsd": <Int microUSD>, "balance_mUsd": <Int microUSD>, ... }`
///   Divide by 1,000,000 to get USD. Sum across all blocks for totals.
///
/// Pass/subscription shape (`subscription` object inside index-1 payload):
///   `currentPeriodUsageUsd`, `currentPeriodBaseCreditsUsd`, `currentPeriodBonusCreditsUsd`,
///   `tier` ("tier_19"/"tier_49"/"tier_199"), `nextBillingAt`/`nextRenewalAt`/`renewsAt`.
///
/// ProviderStatus mapping:
///   - windows[0] "Credits": usedPct = used/total*100, subtitle "$used / $total"
///   - windows[1] "Kilo Pass" (optional): usedPct from pass period usage, subtitle "$used / $base (+ $bonus bonus)", resetDate = nextBillingAt
///   - creditsRemaining = remaining credit USD
///   - planName = tier display name ("Starter" / "Pro" / "Expert") or nil
///   - cost = ProviderCostSnapshot(used: creditUsed, limit: creditTotal, "USD", period: "Credits")
final class KiloProvider: QuotaProvider {
    let id = "kilo"
    let displayName = "Kilo"

    // tRPC base URL — from KiloSettingsReader
    static let baseURL = URL(string: "https://app.kilo.ai/api/trpc")!

    // Batch procedures in index order (index matters for response parsing)
    private static let procedures = [
        "user.getCreditBlocks",       // index 0 — credit block array
        "kiloPass.getState",           // index 1 — pass/subscription state
        "user.getAutoTopUpPaymentMethod", // index 2 — optional, auto top-up
    ]
    // Procedures whose tRPC error is non-fatal (we continue without them)
    private static let optionalProcedures: Set<String> = [
        "user.getAutoTopUpPaymentMethod",
    ]

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - QuotaProvider

    func fetch() async throws -> ProviderStatus {
        guard let resolved = Self.resolveToken(source: KiloUsageSource.current) else {
            return failure("Chưa cấu hình API key cho Kilo Code (hoặc đăng nhập CLI)")
        }
        let token = resolved.token
        // Org scope: when an organization is selected, fold its name into the
        // account label and send the org header so the API returns org usage.
        let scope = KiloUsageScope.current()
        let label: String
        if case .organization(_, let name) = scope {
            label = "\(resolved.label) · \(name)"
        } else {
            label = resolved.label
        }

        let url: URL
        do {
            url = try Self.makeBatchURL()
        } catch {
            return failure("Lỗi tạo URL: \(error.localizedDescription)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let orgID = scope.organizationID {
            req.setValue(orgID, forHTTPHeaderField: "X-KILOCODE-ORGANIZATIONID")
        }
        req.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            return failure("Network: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            return failure("Response không phải HTTP")
        }

        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            return failure("Xác thực thất bại (HTTP \(http.statusCode)). Kiểm tra lại API key.")
        case 404:
            return failure("Endpoint không tồn tại (HTTP 404). Kilo tRPC path có thể đã thay đổi.")
        case 500..<600:
            return failure("Kilo API tạm thời không khả dụng (HTTP \(http.statusCode)).")
        default:
            return failure("HTTP \(http.statusCode)")
        }

        return Self._parseForTesting(data, providerID: id, displayName: displayName, accountLabel: label)
    }

    // MARK: - Token resolution (shared by fetch + Settings org refresh)

    struct ResolvedToken {
        let token: String
        let label: String
        /// "api" or "cli" — mirrors CodexBar's source label.
        let sourceLabel: String
    }

    /// Resolves the bearer token per the selected source. `.api` uses the
    /// config API key then `KILO_API_KEY`; `.cli` reads the CLI session;
    /// `.auto` tries API first, then CLI. Returns nil when nothing is set.
    static func resolveToken(source: KiloUsageSource = .current) -> ResolvedToken? {
        func apiToken() -> ResolvedToken? {
            let configKey = BirdNionConfigStore.apiKey(provider: "kilo")
            let envKey = ProcessInfo.processInfo.environment["KILO_API_KEY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key = (configKey?.isEmpty == false ? configKey : nil)
                ?? (envKey?.isEmpty == false ? envKey : nil) else { return nil }
            let label = BirdNionConfigStore.accountLabel(provider: "kilo") ?? String(key.prefix(8))
            return ResolvedToken(token: key, label: label, sourceLabel: "api")
        }
        func cliToken() -> ResolvedToken? {
            guard let t = readCLIToken() else { return nil }
            return ResolvedToken(token: t, label: String(t.prefix(8)) + "… (CLI)", sourceLabel: "cli")
        }
        switch source {
        case .api: return apiToken()
        case .cli: return cliToken()
        case .auto: return apiToken() ?? cliToken()
        }
    }

    // MARK: - Testing hook (internal — visible for unit tests in the same module)

    /// Parse tRPC batch JSON into a ProviderStatus.
    /// Exposed as `static` so unit tests can inject raw response bytes
    /// without needing a live network session.
    ///
    /// - Parameters:
    ///   - data: Raw response body bytes from the tRPC batch endpoint.
    ///   - providerID: Provider id string (default "kilo").
    ///   - displayName: Display name (default "Kilo Code").
    ///   - accountLabel: Account label to embed in the status.
    /// - Returns: A fully-populated `ProviderStatus`, or an error status on parse failure.
    static func _parseForTesting(
        _ data: Data,
        providerID: String = "kilo",
        displayName: String = "Kilo Code",
        accountLabel: String) -> ProviderStatus
    {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return ProviderStatus(id: providerID, displayName: displayName, windows: [], lastUpdated: Date(),
                                  error: "Response JSON không hợp lệ")
        }

        guard let entries = Self.responseEntries(from: root) else {
            return ProviderStatus(id: providerID, displayName: displayName, windows: [], lastUpdated: Date(),
                                  error: "Định dạng tRPC batch không nhận ra")
        }

        // Resolve per-procedure payloads
        var payloads: [Int: Any] = [:]
        for (index, procedure) in Self.procedures.enumerated() {
            guard let entry = entries[index] else { continue }
            if let trpcErr = Self.trpcError(from: entry) {
                if !Self.optionalProcedures.contains(procedure) {
                    return ProviderStatus(id: providerID, displayName: displayName, windows: [], lastUpdated: Date(),
                                          error: trpcErr)
                }
                continue
            }
            if let payload = Self.resultPayload(from: entry) {
                payloads[index] = payload
            }
        }

        let creditSnap  = Self.parseCredits(from: payloads[0])
        let passSnap    = Self.parsePass(from: payloads[1])
        let basePlan    = Self.parsePlanName(from: payloads[1])
        let autoTopUp   = Self.parseAutoTopUp(from: payloads[2])
        let planName    = Self.decoratePlanName(basePlan, autoTopUp: autoTopUp)
        let now         = Date()

        // Build windows
        var windows: [QuotaWindow] = []

        // Credits window
        if let total = creditSnap.total, total > 0 {
            let used      = creditSnap.used ?? 0
            let usedPct   = Int(min(100, max(0, (used / total) * 100)).rounded())
            let remPct    = 100 - usedPct
            let subtitle  = "\(UsageFormatter.usdString(used)) / \(UsageFormatter.usdString(total))"
            windows.append(QuotaWindow(
                label: "Credits",
                usedPct: usedPct,
                remainingPct: remPct,
                subtitle: subtitle,
                allowance: QuotaAllowance(
                    used: used, remaining: max(0, total - used),
                    limit: total, unit: .usd)))
        } else if creditSnap.total == 0 {
            // Explicit exhausted state: zero balance account
            windows.append(QuotaWindow(
                label: "Credits",
                usedPct: 100,
                remainingPct: 0,
                subtitle: "$0.00 / $0.00"))
        }

        // Pass window (optional — only when subscription data present)
        if let passTotal = passSnap.total, passTotal > 0 {
            let passUsed  = passSnap.used ?? 0
            let bonus     = passSnap.bonus ?? 0
            let baseCredits = max(0, passTotal - bonus)
            let usedPct   = Int(min(100, max(0, (passUsed / passTotal) * 100)).rounded())
            let remPct    = 100 - usedPct

            var subtitle = "\(UsageFormatter.usdString(passUsed)) / \(UsageFormatter.usdString(baseCredits))"
            if bonus > 0 {
                subtitle += " (+ \(UsageFormatter.usdString(bonus)) bonus)"
            }

            windows.append(QuotaWindow(
                label: "Kilo Pass",
                usedPct: usedPct,
                remainingPct: remPct,
                subtitle: subtitle,
                resetDate: passSnap.resetsAt,
                allowance: QuotaAllowance(
                    used: passUsed, remaining: max(0, baseCredits - passUsed),
                    limit: baseCredits, unit: .usd)))
        }

        // creditsRemaining from credits block (USD)
        let creditsRemaining: Double? = creditSnap.remaining

        // cost snapshot driven by credit block
        let cost: ProviderCostSnapshot?
        if let used = creditSnap.used, let total = creditSnap.total {
            cost = ProviderCostSnapshot(
                used: used,
                limit: total,
                currencyCode: "USD",
                period: "Credits",
                updatedAt: now)
        } else {
            cost = nil
        }

        return ProviderStatus(
            id: providerID,
            displayName: displayName,
            windows: windows,
            lastUpdated: now,
            error: nil,
            accountLabel: accountLabel,
            creditsRemaining: creditsRemaining,
            planName: planName,
            cost: cost)
    }

    // MARK: - URL builder

    private static func makeBatchURL() throws -> URL {
        let joinedProcedures = procedures.joined(separator: ",")
        let endpoint = baseURL.appendingPathComponent(joinedProcedures)

        // Build input map: { "0": {"json": null}, "1": {"json": null}, "2": {"json": null} }
        let inputMap = Dictionary(
            uniqueKeysWithValues: procedures.indices.map { (String($0), ["json": NSNull()]) }
        )
        let inputData = try JSONSerialization.data(withJSONObject: inputMap)
        guard let inputString = String(data: inputData, encoding: .utf8) else {
            throw KiloProviderError.urlBuild("Encoding input thất bại")
        }
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw KiloProviderError.urlBuild("URL endpoint không hợp lệ")
        }
        components.queryItems = [
            URLQueryItem(name: "batch", value: "1"),
            URLQueryItem(name: "input", value: inputString),
        ]
        guard let url = components.url else {
            throw KiloProviderError.urlBuild("Không thể tạo URL batch")
        }
        return url
    }

    // MARK: - tRPC response parsing

    /// Returns a dictionary keyed by array index from the tRPC batch response.
    /// Handles both array-of-entries and dict-keyed-by-string-index shapes.
    private static func responseEntries(from root: Any) -> [Int: [String: Any]]? {
        if let entries = root as? [[String: Any]] {
            let limited = Array(entries.prefix(procedures.count))
            return Dictionary(uniqueKeysWithValues: limited.enumerated().map { ($0.offset, $0.element) })
        }
        if let dict = root as? [String: Any] {
            // Single-procedure or dict-keyed shape
            if dict["result"] != nil || dict["error"] != nil {
                return [0: dict]
            }
            let indexed = dict.compactMap { key, value -> (Int, [String: Any])? in
                guard let idx = Int(key), let entry = value as? [String: Any] else { return nil }
                return (idx, entry)
            }
            if !indexed.isEmpty {
                return Dictionary(uniqueKeysWithValues: indexed.filter { $0.0 < procedures.count })
            }
        }
        return nil
    }

    /// Returns a localized error string if the entry contains a tRPC `error` envelope.
    private static func trpcError(from entry: [String: Any]) -> String? {
        guard let errorObj = entry["error"] as? [String: Any] else { return nil }
        let code = nestedString(["json", "data", "code"], in: errorObj)
            ?? nestedString(["data", "code"], in: errorObj)
            ?? nestedString(["code"], in: errorObj)
        let message = nestedString(["json", "message"], in: errorObj)
            ?? nestedString(["message"], in: errorObj)
        let combined = ([code, message].compactMap { $0 }).joined(separator: " ").lowercased()
        if combined.contains("unauthorized") || combined.contains("forbidden") {
            return "Xác thực thất bại. Kiểm tra lại API key."
        }
        return "Lỗi tRPC: \(code ?? message ?? "unknown")"
    }

    /// Extracts the logical payload from a tRPC `result` envelope.
    /// Shape: `{ result: { data: { json: <payload> } } }` or flattened variants.
    private static func resultPayload(from entry: [String: Any]) -> Any? {
        guard let result = entry["result"] as? [String: Any] else { return nil }
        if let dataObj = result["data"] as? [String: Any] {
            if let json = dataObj["json"] {
                return json is NSNull ? nil : json
            }
            return dataObj
        }
        if let json = result["json"] {
            return json is NSNull ? nil : json
        }
        return nil
    }

    // MARK: - Credits parsing (procedure index 0: user.getCreditBlocks)

    private struct CreditSnapshot {
        let used: Double?
        let total: Double?
        let remaining: Double?
    }

    private static func parseCredits(from payload: Any?) -> CreditSnapshot {
        guard let payload else { return CreditSnapshot(used: nil, total: nil, remaining: nil) }
        let contexts = dictionaryContexts(from: payload)

        // Primary: creditBlocks array with amount_mUsd / balance_mUsd (micro-USD → divide by 1,000,000)
        if let blocks = firstArray(forKeys: ["creditBlocks"], in: contexts) {
            var totalSum: Double = 0
            var remainSum: Double = 0
            var sawTotal = false, sawRemain = false

            for case let block as [String: Any] in blocks {
                if let amt = double(from: block["amount_mUsd"]) {
                    totalSum += amt / 1_000_000; sawTotal = true
                }
                if let bal = double(from: block["balance_mUsd"]) {
                    remainSum += bal / 1_000_000; sawRemain = true
                }
            }

            if sawTotal || sawRemain {
                let total     = sawTotal  ? max(0, totalSum)  : nil
                let remaining = sawRemain ? max(0, remainSum) : nil
                let used: Double? = total.flatMap { t in remaining.map { r in max(0, t - r) } }
                return CreditSnapshot(used: used, total: total, remaining: remaining)
            }
        }

        // Fallback: zero-balance signal from totalBalance_mUsd == 0
        if let balMilli = firstDouble(forKeys: ["totalBalance_mUsd"], in: contexts) {
            let bal = max(0, balMilli / 1_000_000)
            return CreditSnapshot(used: 0, total: bal, remaining: bal)
        }

        // Generic key fallback
        let used      = firstDouble(forKeys: ["used", "usedCredits", "creditsUsed", "consumed"], in: contexts)
        let total     = firstDouble(forKeys: ["total", "totalCredits", "creditsTotal", "limit"], in: contexts)
        let remaining = firstDouble(forKeys: ["remaining", "remainingCredits", "creditsRemaining"], in: contexts)
        return CreditSnapshot(used: used, total: total, remaining: remaining)
    }

    // MARK: - Pass parsing (procedure index 1: kiloPass.getState)

    private struct PassSnapshot {
        let used: Double?
        let total: Double?
        let bonus: Double?
        let resetsAt: Date?
    }

    private static func parsePass(from payload: Any?) -> PassSnapshot {
        guard let subscription = subscriptionData(from: payload) else {
            return PassSnapshot(used: nil, total: nil, bonus: nil, resetsAt: nil)
        }
        let used        = double(from: subscription["currentPeriodUsageUsd"]).map { max(0, $0) }
        let baseCredits = double(from: subscription["currentPeriodBaseCreditsUsd"]).map { max(0, $0) }
        let bonusCredits = max(0, double(from: subscription["currentPeriodBonusCreditsUsd"]) ?? 0)
        let total       = baseCredits.map { $0 + bonusCredits }
        let resetsAt    = date(from: subscription["nextBillingAt"])
            ?? date(from: subscription["nextRenewalAt"])
            ?? date(from: subscription["renewsAt"])
            ?? date(from: subscription["renewAt"])
        return PassSnapshot(
            used: used,
            total: total,
            bonus: bonusCredits > 0 ? bonusCredits : nil,
            resetsAt: resetsAt)
    }

    // MARK: - Plan name (from kiloPass.getState payload)

    private static func parsePlanName(from payload: Any?) -> String? {
        guard let subscription = subscriptionData(from: payload) else {
            return nil
        }
        if let tier = (subscription["tier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tier.isEmpty
        {
            return planNameForTier(tier)
        }
        return "Kilo Pass"
    }

    private static func planNameForTier(_ tier: String) -> String {
        switch tier {
        case "tier_19":  return "Starter"
        case "tier_49":  return "Pro"
        case "tier_199": return "Expert"
        default:         return tier
        }
    }

    // MARK: - Auto top-up parsing (procedure index 2: user.getAutoTopUpPaymentMethod)

    private struct AutoTopUpSnapshot {
        let enabled: Bool?
        let method: String?
    }

    private static func parseAutoTopUp(from payload: Any?) -> AutoTopUpSnapshot {
        guard let dict = payload as? [String: Any] else {
            return AutoTopUpSnapshot(enabled: nil, method: nil)
        }
        // enabled field
        let enabled: Bool?
        if let v = dict["enabled"] as? Bool {
            enabled = v
        } else if let v = dict["isEnabled"] as? Bool {
            enabled = v
        } else if let v = dict["active"] as? Bool {
            enabled = v
        } else {
            enabled = nil
        }
        // payment method string
        let rawMethod = (dict["paymentMethod"] as? String)
            ?? (dict["paymentMethodType"] as? String)
            ?? (dict["method"] as? String)
        let method = rawMethod.flatMap { s -> String? in
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return AutoTopUpSnapshot(enabled: enabled, method: method)
    }

    /// Appends auto top-up info to the plan name when enabled.
    private static func decoratePlanName(_ base: String?, autoTopUp: AutoTopUpSnapshot) -> String? {
        guard autoTopUp.enabled == true else { return base }
        let topUpLabel: String
        if let m = autoTopUp.method, !m.isEmpty {
            topUpLabel = "Auto top-up: \(m)"
        } else {
            topUpLabel = "Auto top-up: enabled"
        }
        if let base = base, !base.isEmpty {
            return "\(base) · \(topUpLabel)"
        }
        return topUpLabel
    }

    // MARK: - CLI token fallback

    /// Reads the Kilo CLI session token from `~/.local/share/kilo/auth.json`.
    /// The real CodexBar schema nests the token under `kilo.access`; older
    /// top-level `token`/`access_token` keys are kept as a fallback.
    /// Returns nil silently on any I/O or parse failure (non-fatal).
    private static func readCLIToken() -> String? {
        let path = (("~/.local/share/kilo/auth.json" as NSString)
            .expandingTildeInPath)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        // Primary: nested { "kilo": { "access": "<token>" } }
        if let kilo = json["kilo"] as? [String: Any],
           let access = (kilo["access"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !access.isEmpty {
            return access
        }
        // Fallback: legacy top-level keys.
        for key in ["token", "access_token"] {
            if let t = json[key] as? String {
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// Extracts the subscription sub-object or returns the dictionary itself
    /// if it has a recognizable subscription shape.
    private static func subscriptionData(from payload: Any?) -> [String: Any]? {
        guard let dict = payload as? [String: Any] else { return nil }
        if let sub = dict["subscription"] as? [String: Any] { return sub }
        if dict["subscription"] is NSNull { return nil }
        // Direct subscription shape (no wrapper key)
        let hasShape = dict["currentPeriodUsageUsd"] != nil
            || dict["currentPeriodBaseCreditsUsd"] != nil
            || dict["tier"] != nil
        return hasShape ? dict : nil
    }

    // MARK: - Failure helper

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }
}

// MARK: - Internal parse error

private enum KiloProviderError: Error {
    case urlBuild(String)
}

// MARK: - Low-level parse helpers (file-private)

/// Walks a dictionary up to 2 levels deep, collecting all nested dictionaries.
private func dictionaryContexts(from payload: Any) -> [[String: Any]] {
    guard let dict = payload as? [String: Any] else { return [] }
    var results: [[String: Any]] = []
    var queue: [([String: Any], Int)] = [(dict, 0)]
    while !queue.isEmpty {
        let (current, depth) = queue.removeFirst()
        results.append(current)
        guard depth < 2 else { continue }
        for value in current.values {
            if let nested = value as? [String: Any] {
                queue.append((nested, depth + 1))
            } else if let arr = value as? [Any] {
                for case let nested as [String: Any] in arr {
                    queue.append((nested, depth + 1))
                }
            }
        }
    }
    return results
}

private func firstArray(forKeys keys: [String], in contexts: [[String: Any]]) -> [Any]? {
    for ctx in contexts {
        for key in keys {
            if let arr = ctx[key] as? [Any] { return arr }
        }
    }
    return nil
}

private func firstDouble(forKeys keys: [String], in contexts: [[String: Any]]) -> Double? {
    for ctx in contexts {
        for key in keys {
            if let v = double(from: ctx[key]) { return v }
        }
    }
    return nil
}

/// Resolves numeric Any → Double (Int, NSNumber, String coercion).
private func double(from raw: Any?) -> Double? {
    switch raw {
    case let v as Double:  return v
    case let v as Int:     return Double(v)
    case let v as NSNumber: return v.doubleValue
    case let v as String:  return Double(v.trimmingCharacters(in: .whitespacesAndNewlines))
    default:               return nil
    }
}

/// Resolves date from epoch seconds/ms or ISO-8601 string.
private func date(from raw: Any?) -> Date? {
    switch raw {
    case let v as Double:   return epochToDate(v)
    case let v as Int:      return epochToDate(Double(v))
    case let v as NSNumber: return epochToDate(v.doubleValue)
    case let v as String:
        let s = v.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let n = Double(s) { return epochToDate(n) }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    default: return nil
    }
}

private func epochToDate(_ value: Double) -> Date {
    // Milliseconds heuristic: epoch > 10^10 means it's in ms
    let seconds = abs(value) > 10_000_000_000 ? value / 1000 : value
    return Date(timeIntervalSince1970: seconds)
}

/// Navigates a nested dictionary by key path, returning the terminal String value.
private func nestedString(_ path: [String], in dict: [String: Any]) -> String? {
    var cursor: Any = dict
    for key in path {
        guard let next = (cursor as? [String: Any])?[key] else { return nil }
        cursor = next
    }
    return cursor as? String
}
