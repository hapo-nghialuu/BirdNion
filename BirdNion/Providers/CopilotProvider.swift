import Foundation

/// GitHub Copilot usage provider. Uses a GitHub token (PAT/OAuth) — paste it in
/// the token field — to hit the internal Copilot quota endpoint, which reports
/// remaining % for premium interactions + chat plus the plan + reset date.
/// Native port of CodexBar's CopilotUsageFetcher.
final class CopilotProvider: QuotaProvider {
    let id = "copilot"
    let displayName = "Copilot"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func override() -> String? { BirdNionConfigStore.accountLabel(provider: id) }

    /// Resolve API host: prefers GH_HOST / GITHUB_HOST env vars, then defaults to api.github.com.
    /// If an enterprise host is configured, uses api.<host>.
    private static func apiHost() -> String {
        // Enterprise host: Settings config (baseURL) → GH_HOST/GITHUB_HOST env.
        let configHost = BirdNionConfigStore.provider(id: "copilot")?.baseURL?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let envHost = ProcessInfo.processInfo.environment["GH_HOST"]
            ?? ProcessInfo.processInfo.environment["GITHUB_HOST"]
        let host = (configHost?.isEmpty == false ? configHost : nil) ?? envHost
        guard let host, !host.isEmpty, host != "github.com" else {
            return "api.github.com"
        }
        if host.hasPrefix("api.") { return host }
        return "api.\(host)"
    }

    private static func usageURL() -> URL {
        URL(string: "https://\(apiHost())/copilot_internal/user")!
    }

    private static func userURL() -> URL {
        URL(string: "https://\(apiHost())/user")!
    }

    /// Fetches the GitHub username for the given token. Non-fatal: returns nil on any failure.
    private func fetchGitHubUsername(token: String) async -> String? {
        var req = URLRequest(url: Self.userURL())
        req.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("BirdNion/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10

        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONDecoder().decode(GitHubUserResponse.self, from: data)
        else { return nil }
        return obj.login
    }

    func fetch() async throws -> ProviderStatus {
        // Prefer an OAuth (Device Flow) account token; fall back to a pasted token.
        let store = CopilotAccountStore.load()
        let activeAccount = CopilotAccountStore.activeAccount(in: store)
        let token = (activeAccount?.token).flatMap { $0.isEmpty ? nil : $0 }
            ?? BirdNionConfigStore.apiKey(provider: id)
        guard let token, !token.isEmpty else {
            return failure("Chưa đăng nhập GitHub (Add Account) hoặc nhập token cho Copilot")
        }

        // Resolve account label: stored login → manual override → fetched login → token prefix
        let accountLabel: String
        if let login = activeAccount?.login, !login.isEmpty {
            accountLabel = login
        } else if let manual = override() {
            accountLabel = manual
        } else if let login = await fetchGitHubUsername(token: token) {
            accountLabel = login
        } else {
            accountLabel = String(token.prefix(8))
        }

        var req = URLRequest(url: Self.usageURL())
        req.httpMethod = "GET"
        req.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        req.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        req.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        req.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")
        req.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            return failure("Network: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { return failure("Response không phải HTTP") }
        switch http.statusCode {
        case 200..<300:
            let base = parse(data, accountLabel: accountLabel)
            guard base.error == nil else { return base }
            // Best-effort budget enrichment via GitHub web cookie (never fatal).
            let budgetWindows = await fetchBudgetWindowsBestEffort()
            guard !budgetWindows.isEmpty else { return base }
            return ProviderStatus(
                id: base.id, displayName: base.displayName,
                windows: base.windows + budgetWindows, lastUpdated: base.lastUpdated,
                error: nil, accountLabel: base.accountLabel, planName: base.planName)
        case 401, 403: return failure("GitHub token không hợp lệ / thiếu quyền Copilot")
        default: return failure("HTTP \(http.statusCode)")
        }
    }

    /// Pure synchronous parser (fixture-tested). Network-based budget windows
    /// are layered on by `fetch()`, not here, so this stays test-friendly.
    func parse(_ data: Data, accountLabel: String?) -> ProviderStatus {
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else {
            return failure("Response thiếu trường")
        }
        let reset = Self.parseReset(r.quotaResetDate)
        var windows: [QuotaWindow] = []
        if let w = Self.window(label: "Premium", snap: r.quotaSnapshots?.premiumInteractions, reset: reset) {
            windows.append(w)
        }
        if let w = Self.window(label: "Chat", snap: r.quotaSnapshots?.chat, reset: reset) {
            windows.append(w)
        }
        let plan = r.copilotPlan.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }

        // Plan with no usable windows (e.g. token-based billing) still shows the plan.
        return ProviderStatus(
            id: id, displayName: displayName,
            windows: windows, lastUpdated: Date(),
            error: windows.isEmpty && plan == nil ? "Copilot chưa có dữ liệu quota" : nil,
            accountLabel: accountLabel, planName: plan)
    }

    /// Fetches GitHub billing budget windows using a browser session cookie.
    /// Returns an empty array on any error — never throws.
    private func fetchBudgetWindowsBestEffort() async -> [QuotaWindow] {
        guard let cookieHeader = ProviderCookieReader.resolvedCookieHeader(
            providerID: id, domain: "github.com"),
              !cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }

        do {
            // Step 1: load the budgets page to extract the X-Fetch-Nonce (best-effort).
            let nonce = await Self.fetchBudgetNonceBestEffort(
                cookieHeader: cookieHeader, session: session)

            // Step 2: fetch first page of budgets (pagination best-effort: page 1 only).
            let budgets = try await Self.fetchBudgetPage(
                cookieHeader: cookieHeader, nonce: nonce, page: 1, session: session)

            // Step 3: convert Copilot budgets to QuotaWindows.
            return Self.budgetWindows(from: budgets)
        } catch {
            // Any network / parsing failure → silent no-op; main windows are already set.
            return []
        }
    }

    private static func fetchBudgetNonceBestEffort(
        cookieHeader: String, session: URLSession) async -> String?
    {
        guard let url = URL(string: "https://github.com/settings/billing/budgets") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        req.setValue("BirdNion/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8)
        else { return nil }
        return extractFetchNonce(from: html)
    }

    private static func fetchBudgetPage(
        cookieHeader: String, nonce: String?, page: Int, session: URLSession) async throws -> [BudgetEntry]
    {
        guard var components = URLComponents(string: "https://github.com/settings/billing/budgets") else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "page_size", value: "10"),
            URLQueryItem(name: "scope", value: "customer"),
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://github.com/settings/billing/budgets", forHTTPHeaderField: "Referer")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("true", forHTTPHeaderField: "GitHub-Verified-Fetch")
        req.setValue("BirdNion/1.0", forHTTPHeaderField: "User-Agent")
        if let nonce, !nonce.isEmpty {
            req.setValue(nonce, forHTTPHeaderField: "X-Fetch-Nonce")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        return (try? JSONDecoder().decode(BudgetPageResponse.self, from: data))?.budgets ?? []
    }

    /// Converts raw budget entries to QuotaWindows. Skips budgets without Copilot SKU
    /// and skips zero-limit budgets. usedPct = currentAmount / budgetAmount * 100.
    static func budgetWindows(from budgets: [BudgetEntry]) -> [QuotaWindow] {
        let copilotKeywords: Set<String> = ["copilot", "premium_request", "spark"]
        return budgets.compactMap { b -> QuotaWindow? in
            guard b.budgetAmount > 0 else { return nil }
            // Only include budgets that mention "copilot" in any identifying field.
            let identifiers = ([b.name, b.budgetType, b.budgetEntityName]
                .compactMap { $0 } + b.budgetProductSkus)
                .map { $0.lowercased().replacingOccurrences(of: "-", with: "_") }
            let isCopilot = identifiers.contains { identifier in
                copilotKeywords.contains { identifier.contains($0) }
            }
            guard isCopilot else { return nil }
            let usedRaw = b.currentAmount / b.budgetAmount * 100
            let used = max(0, min(100, Int(usedRaw.rounded())))
            let label = "Budget · \(b.name ?? "Copilot")"
            let subtitle = String(format: "$%.2f / $%.2f", b.currentAmount, b.budgetAmount)
            return QuotaWindow(
                label: label,
                usedPct: used,
                remainingPct: 100 - used,
                subtitle: subtitle,
                resetDate: nil,
                windowSeconds: 30 * 24 * 3600,
                allowance: QuotaAllowance(
                    used: b.currentAmount,
                    remaining: max(0, b.budgetAmount - b.currentAmount),
                    limit: b.budgetAmount,
                    unit: .usd))
        }
    }

    /// Extracts `X-Fetch-Nonce` value from a GitHub HTML page. Mirrors CodexBar logic.
    static func extractFetchNonce(from html: String) -> String? {
        let patterns = [
            #"x-fetch-nonce"\s+content="([^"]+)""#,
            #"X-Fetch-Nonce"\s*:\s*"([^"]+)""#,
            #"fetchNonce"\s*:\s*"([^"]+)""#,
            #"data-fetch-nonce="([^"]+)""#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            if let match = regex.firstMatch(in: html, range: range),
               let nonceRange = Range(match.range(at: 1), in: html)
            {
                return String(html[nonceRange])
            }
        }
        return nil
    }

    /// Builds a window from a snapshot. Skips unlimited / zero-entitlement
    /// placeholders (mirrors CodexBar). usedPercent = 100 − percent_remaining.
    static func window(label: String, snap: Snap?, reset: Date?) -> QuotaWindow? {
        guard let snap, snap.unlimited != true else { return nil }
        // Zero-entitlement + zero-remaining = placeholder, no real signal.
        if (snap.entitlement ?? 0) == 0, (snap.remaining ?? 0) == 0 { return nil }
        let percentRemaining: Double
        if let p = snap.percentRemaining {
            percentRemaining = p
        } else if let e = snap.entitlement, e > 0, let rem = snap.remaining {
            percentRemaining = rem / e * 100
        } else {
            return nil
        }
        let used = max(0, min(100, Int((100 - percentRemaining).rounded())))
        let allowance = (snap.entitlement != nil || snap.remaining != nil)
            ? QuotaAllowance(
                used: nil,
                remaining: snap.remaining,
                limit: snap.entitlement,
                unit: .requests)
            : nil
        return QuotaWindow(label: label, usedPct: used, remainingPct: 100 - used,
                           resetDate: reset, windowSeconds: 30 * 24 * 3600,
                           allowance: allowance)
    }

    static func parseReset(_ value: String?) -> Date? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: raw)
    }

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }

    struct Response: Decodable {
        let copilotPlan: String?
        let quotaResetDate: String?
        let quotaSnapshots: Snapshots?
        enum CodingKeys: String, CodingKey {
            case copilotPlan = "copilot_plan"
            case quotaResetDate = "quota_reset_date"
            case quotaSnapshots = "quota_snapshots"
        }
    }
    struct Snapshots: Decodable {
        let premiumInteractions: Snap?
        let chat: Snap?
        enum CodingKeys: String, CodingKey {
            case premiumInteractions = "premium_interactions"
            case chat
        }
    }
    struct Snap: Decodable {
        let entitlement: Double?
        let remaining: Double?
        let percentRemaining: Double?
        let unlimited: Bool?
        enum CodingKeys: String, CodingKey {
            case entitlement, remaining, unlimited
            case percentRemaining = "percent_remaining"
        }
    }

    /// Minimal response for GET /user to extract the GitHub login name.
    struct GitHubUserResponse: Decodable {
        let login: String
    }

    // MARK: - Budget web types

    /// Minimal budget entry from GitHub's billing budgets JSON endpoint.
    struct BudgetEntry: Decodable {
        let name: String?
        let budgetType: String?
        let budgetProductSkus: [String]
        let budgetEntityName: String?
        let budgetAmount: Double
        let currentAmount: Double

        enum CodingKeys: String, CodingKey {
            case name
            case budgetType = "budget_type"
            case budgetProductSkus = "budget_product_skus"
            case budgetEntityName = "budget_entity_name"
            case budgetAmount = "budget_amount"
            case currentAmount = "current_usage"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            budgetType = try c.decodeIfPresent(String.self, forKey: .budgetType)
            budgetProductSkus = (try? c.decodeIfPresent([String].self, forKey: .budgetProductSkus)) ?? []
            budgetEntityName = try c.decodeIfPresent(String.self, forKey: .budgetEntityName)
            // GitHub may use several key shapes; try budget_amount then fall through to 0.
            budgetAmount = (try? c.decodeIfPresent(Double.self, forKey: .budgetAmount)) ?? 0
            currentAmount = (try? c.decodeIfPresent(Double.self, forKey: .currentAmount)) ?? 0
        }
    }

    /// Wrapper around GitHub's paginated budgets response.
    /// GitHub may wrap the array in a `payload` envelope or return it directly.
    struct BudgetPageResponse: Decodable {
        let budgets: [BudgetEntry]

        private enum CodingKeys: String, CodingKey {
            case budgets, payload
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Try unwrapping a `payload` envelope first (matches CodexBar observation).
            if let inner = try? c.decodeIfPresent(BudgetPageResponse.self, forKey: .payload) {
                self = inner
                return
            }
            budgets = (try? c.decodeIfPresent([BudgetEntry].self, forKey: .budgets)) ?? []
        }
    }
}
