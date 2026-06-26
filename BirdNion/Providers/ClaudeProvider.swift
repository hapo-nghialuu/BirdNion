import Foundation
import Security
import CodexBarCore

/// Claude (Anthropic) subscription usage provider.
///
/// Auth: reads the OAuth token Claude Code stores in the macOS Keychain under
/// service `Claude Code-credentials` (JSON: `{ "claudeAiOauth": { "accessToken",
/// "rateLimitTier", "subscriptionType", ... } }`). Because that item belongs to
/// the Claude Code app, the first read triggers a macOS Keychain access prompt —
/// the user must click "Always Allow" once.
///
/// Endpoint: `GET https://api.anthropic.com/api/oauth/usage`
/// Headers: `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`.
/// Response: `{ five_hour, seven_day, seven_day_opus, seven_day_sonnet, extra_usage }`
/// where each window's `utilization` is a percent already used (0..100).
/// `extra_usage` is `{ is_enabled, monthly_limit, used_credits, utilization, currency }`.
final class ClaudeProvider: QuotaProvider {
    let id = "claude"
    let displayName = "Claude"

    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let keychainService = "Claude Code-credentials"
    static let betaHeader = "oauth-2025-04-20"

    private let session: URLSession
    /// Token reader, injectable so tests don't touch the real Keychain.
    private let tokenProvider: () -> String?
    /// Status-page reader. Isolated from the main fetcher so unit tests can
    /// inject a fake without hitting status.anthropic.com.
    private let statusProvider: () async -> OpenAIServiceStatus?
    /// Cost-scrape reader. Calls CodexBarCore's ClaudeWebAPIFetcher which
    /// auto-detects browser cookies (Safari/Chrome via SweetCookieKit) and
    /// scrapes claude.ai/settings/billing. nil when no session cookie is
    /// found or the scrape fails — mirrors CodexBar's auto path.
    private let costProvider: () async -> ProviderCostSnapshot?

    init(session: URLSession = .shared,
         tokenProvider: @escaping () -> String? = { ClaudeProvider.readKeychainToken() },
         statusProvider: @escaping () async -> OpenAIServiceStatus? = ClaudeProvider.fetchServiceStatus,
         costProvider: @escaping () async -> ProviderCostSnapshot? = ClaudeProvider.fetchCost) {
        self.session = session
        self.tokenProvider = tokenProvider
        self.statusProvider = statusProvider
        self.costProvider = costProvider
    }

    private func override() -> String? {
        BirdNionConfigStore.accountLabel(provider: id)
    }

    /// Hard cap on a single Claude fetch. Without this, the inner
    /// `async let statusAsync = statusProvider()` (HTTP to
    /// status.anthropic.com) can hang for many minutes when the user's
    /// network is down or Anthropic's status endpoint is unreachable — the
    /// TaskGroup waits for ALL tasks to complete before publishing statuses,
    /// so a stuck Claude blocks MiniMax/Hapo/Codex data from being
    /// surfaced. 12s is well above the per-provider 6s status timeout +
    /// 5s cost timeout, leaving headroom for the slowest normal path.
    private static let fetchTimeout: TimeInterval = 12

    func fetch() async throws -> ProviderStatus {
        // Wrap the entire body in a Task so a hang inside
        // `statusProvider()` / `costProvider()` / `fetchOAuth()` /
        // `fetchViaUsageFetcher()` can't block the whole refresh cycle.
        // The outer `withTaskGroup` in QuotaService waits for every
        // provider to complete, so a stuck provider stalls the loop and
        // every other provider's last-known data shows up as stale.
        try await withThrowingTaskGroup(of: ProviderStatus?.self) { group in
            group.addTask { [self] in
                await runFetch()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(Self.fetchTimeout * 1_000_000_000))
                return nil
            }
            // Whichever returns first wins. If the timeout fires first we
            // cancel the fetch task so it stops blocking the next cycle.
            let result = try await group.next() ?? nil
            group.cancelAll()
            if let result { return result }
            return failure("Claude: timeout sau \(Int(Self.fetchTimeout))s")
        }
    }

    /// Inner fetch — same logic as the previous fetch body, just split
    /// out so the outer wrapper can apply the timeout.
    private func runFetch() async -> ProviderStatus {
        // Resolve which data source the user picked in Settings. CodexBar's
        // `.auto` falls back across OAuth → Web → CLI when the preferred
        // source fails; the other modes pin to a single strategy. We honor
        // `.oauth` (current behavior) by running the in-house path; anything
        // else routes through CodexBarCore's `ClaudeUsageFetcher` which has
        // battle-tested OAuth/Web/CLI/API execution + fallback.
        let source = Self.readUsageDataSource()

        // Service status + (legacy) cost run concurrently regardless of the
        // chosen data source — they're best-effort UI overlays and must not
        // block the main quota fetch.
        async let statusAsync = statusProvider()
        async let legacyCostAsync = costProvider()
        let status = await statusAsync
        let legacyCost = await legacyCostAsync

        switch source {
        case .oauth:
            return await fetchOAuth(status: status, cost: legacyCost)
        default:
            // For all other modes (auto / web / cli / api) defer to the
            // CodexBarCore fetcher — it already handles delegation, fallback,
            // cookie auto-detect, manual cookie header, and CLI rate-limit
            // gating. We merge the OAuth accountLabel fallback (Keychain)
            // into the resulting snapshot so the user still sees their
            // override label even when OAuth didn't run.
            do {
                let snapshot = try await fetchViaUsageFetcher(source: source)
                return Self.materialize(from: snapshot, override: override(), sourceLabel: source.sourceLabel)
            } catch {
                // Surface the error + still keep cost + status so the panel
                // stays informative. Matches CodexBar: a 401 from OAuth with
                // cookies present still shows the cost row.
                return failure("Claude: \(error.localizedDescription)",
                               status: status, cost: legacyCost,
                               extras: Self.webExtrasFromLastAttempt())
            }
        }
    }

    /// Original OAuth-only fetch path. Preserved unchanged for the default
    /// `.oauth` mode and for unit tests that drive `parse()` directly.
    private func fetchOAuth(status: OpenAIServiceStatus?,
                            cost: ProviderCostSnapshot?) async -> ProviderStatus {
        guard let token = tokenProvider(), !token.isEmpty else {
            return failure("Chưa đăng nhập Claude — đăng nhập bằng Claude Code",
                           status: status, cost: cost)
        }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/1.0.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            return failure("Network: \(error.localizedDescription)",
                           status: status, cost: cost)
        }
        guard let http = response as? HTTPURLResponse else {
            return failure("Response không phải HTTP", status: status, cost: cost)
        }
        switch http.statusCode {
        case 200..<300:
            let base = parse(data, accountLabel: override())
            return ProviderStatus(
                id: base.id,
                displayName: base.displayName,
                windows: base.windows,
                lastUpdated: base.lastUpdated,
                error: base.error,
                accountLabel: base.accountLabel,
                planType: base.planType,
                creditsRemaining: base.creditsRemaining,
                version: Self.detectedClaudeVersion(),
                serviceStatus: status?.description,
                serviceStatusLevel: status?.indicator,
                accountID: base.accountID,
                planName: base.planName,
                resetCreditsAvailable: base.resetCreditsAvailable,
                cost: cost,
                webExtras: base.webExtras)
        case 401, 403:
            return failure("Token Claude hết hạn — đăng nhập lại bằng Claude Code",
                           status: status, cost: cost)
        default:
            return failure("HTTP \(http.statusCode)", status: status, cost: cost)
        }
    }

    /// Routes through CodexBarCore's `ClaudeUsageFetcher` for non-OAuth
    /// sources. Reads the cookie source preference + manual cookie header
    /// from UserDefaults so the Settings pane can drive this transparently.
    private func fetchViaUsageFetcher(source: ClaudeUsageDataSource) async throws -> ClaudeUsageSnapshot {
        let cookieSource = Self.readCookieSource()
        let manualCookie = Self.readManualCookieHeader()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(),
            dataSource: source,
            manualCookieHeader: cookieSource == .manual ? manualCookie : nil,
            keepCLISessionsAlive: false)
        return try await fetcher.loadLatestUsage()
    }

    /// Reads the user-selected data source from UserDefaults. Defaults to
    /// `.oauth` so existing users (and tests) keep the original behavior.
    /// `SettingsStore.claudeUsageDataSource` writes the same key.
    private static func readUsageDataSource() -> ClaudeUsageDataSource {
        let raw = UserDefaults.standard.string(forKey: "claudeUsageDataSource") ?? ClaudeUsageDataSource.oauth.rawValue
        return ClaudeUsageDataSource(rawValue: raw) ?? .oauth
    }

    /// Reads the user-selected cookie source. Defaults to `.auto` so the
    /// CodexBarCore fetcher does its standard Safari/Chrome auto-detect.
    /// `SettingsStore.claudeCookieSource` writes the same key.
    private static func readCookieSource() -> ProviderCookieSource {
        let raw = UserDefaults.standard.string(forKey: "claudeCookieSource") ?? ProviderCookieSource.auto.rawValue
        return ProviderCookieSource(rawValue: raw) ?? .auto
    }

    /// Reads the manual Cookie: header from UserDefaults. Empty when absent.
    /// Stored plaintext — only the user pastes it, never logged.
    private static func readManualCookieHeader() -> String? {
        let raw = UserDefaults.standard.string(forKey: "claudeManualCookieHeader")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty ?? true) ? nil : raw
    }

    /// Remembers the last successful `ClaudeUsageSnapshot` so the failure
    /// path can still surface web extras (account email / cost / quota
    /// fallback) even when the current fetch throws. Captured by the
    /// `fetchViaUsageFetcher` wrapper; nil at startup.
    private static var lastSnapshot: ClaudeUsageSnapshot?

    /// Last label of the source that produced `lastSnapshot` — surfaced
    /// to the UI as "Source: web" / "cli" etc. so the user can confirm which
    /// path the planner picked. Set in `materialize`, read by `webExtrasFromLastAttempt`.
    private static var lastUsedSourceLabel: String?

    /// Exposed for the failure-path merge in `fetch()`.
    static func webExtrasFromLastAttempt() -> ClaudeWebExtras? {
        lastSnapshot.map { snapshot in
            ClaudeWebExtras(
                accountEmail: snapshot.accountEmail,
                accountOrganization: snapshot.accountOrganization,
                loginMethod: snapshot.loginMethod,
                sessionPercentUsed: snapshot.primary.usedPercent,
                weeklyPercentUsed: snapshot.secondary?.usedPercent,
                opusPercentUsed: snapshot.opus?.usedPercent,
                extraRateWindows: snapshot.extraRateWindows.map { named in
                    ClaudeExtraRateWindow(
                        id: named.id,
                        title: named.title,
                        usedPercent: Int(named.window.usedPercent.rounded()),
                        resetsAt: named.window.resetsAt,
                        resetDescription: named.window.resetDescription,
                        windowMinutes: named.window.windowMinutes)
                },
                sourceLabel: Self.lastUsedSourceLabel)
        }
    }

    /// Convert a CodexBarCore `ClaudeUsageSnapshot` into our `ProviderStatus`.
    /// Stamps the current time, attaches the detected CLI version, surfaces
    /// the user override label, and packs web-only data into `webExtras`.
    private static func materialize(from snapshot: ClaudeUsageSnapshot,
                                    override: String?,
                                    sourceLabel: String) -> ProviderStatus {
        lastSnapshot = snapshot
        lastUsedSourceLabel = sourceLabel

        // Build quota windows from snapshot rate windows (primary + secondary + opus).
        var windows: [QuotaWindow] = []
        if snapshot.primary.usedPercent > 0 || snapshot.primary.windowMinutes != nil {
            windows.append(Self.window(label: "5 giờ",
                                       utilization: snapshot.primary.usedPercent,
                                       resetsAt: snapshot.primary.resetsAt?.description,
                                       seconds: 5 * 3600))
        }
        if let sec = snapshot.secondary {
            windows.append(Self.window(label: "Tuần",
                                       utilization: sec.usedPercent,
                                       resetsAt: sec.resetsAt?.description,
                                       seconds: 7 * 24 * 3600))
        }
        if let opus = snapshot.opus {
            windows.append(Self.window(label: "Opus",
                                       utilization: opus.usedPercent,
                                       resetsAt: opus.resetsAt?.description,
                                       seconds: 7 * 24 * 3600))
        }

        // Plan label from login method (CodexBar maps Max/Pro/Team from
        // subscriptionType/rateLimitTier — we approximate via loginMethod
        // hint since we no longer parse the raw OAuth blob in this path).
        let planName = Self.planName(fromLoginMethod: snapshot.loginMethod)

        // AccountLabel preference: user override > OAuth Keychain email > web email.
        let keychainEmail = (try? tokenFromKeychainJSON(readKeychainData() ?? Data()))
            .flatMap { _ in Self.readKeychainData().flatMap { tokenFromKeychainJSON($0) } }
            .flatMap { _ in KeychainRoot.decode(keychainData: Self.readKeychainData())?.email }
        let label = override ?? keychainEmail ?? snapshot.accountEmail

        // Build extras bag.
        let extras = ClaudeWebExtras(
            accountEmail: snapshot.accountEmail,
            accountOrganization: snapshot.accountOrganization,
            loginMethod: snapshot.loginMethod,
            sessionPercentUsed: snapshot.primary.usedPercent,
            weeklyPercentUsed: snapshot.secondary?.usedPercent,
            opusPercentUsed: snapshot.opus?.usedPercent,
            extraRateWindows: snapshot.extraRateWindows.map { named in
                ClaudeExtraRateWindow(
                    id: named.id,
                    title: named.title,
                    usedPercent: Int(named.window.usedPercent.rounded()),
                    resetsAt: named.window.resetsAt,
                    resetDescription: named.window.resetDescription,
                    windowMinutes: named.window.windowMinutes)
            },
            sourceLabel: snapshot.providerCost?.period)

        return ProviderStatus(
            id: "claude",
            displayName: "Claude",
            windows: windows,
            lastUpdated: Date(),
            error: nil,
            accountLabel: label,
            creditsRemaining: Self.spendRemainingFromCost(snapshot.providerCost),
            version: Self.detectedClaudeVersion(),
            planName: planName,
            cost: snapshot.providerCost,
            webExtras: extras)
    }

    /// If providerCost carries a credit-style (used, limit, currencyCode)
    /// snapshot, derive the remaining balance for the existing UI cell.
    private static func spendRemainingFromCost(_ cost: ProviderCostSnapshot?) -> Double? {
        guard let cost, cost.limit > 0 else { return nil }
        return max(0, cost.limit - cost.used)
    }

    /// Approximate the plan label from the loginMethod CodexBar returns.
    /// The OAuth path uses `ClaudePlan.label` for exact mapping; for
    /// web/CLI/API we only get a coarse hint like "Claude account" / "SSO",
    /// so we keep the existing label if any and otherwise leave it nil.
    private static func planName(fromLoginMethod method: String?) -> String? {
        guard let method, !method.isEmpty else { return nil }
        // Try Keychain first — exact mapping.
        let creds = KeychainRoot.decode(keychainData: Self.readKeychainData())
        if let exact = ClaudePlan.label(forSubscriptionType: creds?.subscriptionType,
                                        rateLimitTier: creds?.rateLimitTier) {
            return exact
        }
        // Fallback to a sanitized version of the loginMethod hint.
        if method.lowercased().contains("max") { return "Max" }
        if method.lowercased().contains("ultra") { return "Ultra" }
        if method.lowercased().contains("pro") { return "Pro" }
        if method.lowercased().contains("team") { return "Team" }
        return nil
    }

    func parse(_ data: Data, accountLabel: String?) -> ProviderStatus {
        guard let root = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
            return failure("Response thiếu trường")
        }
        var windows: [QuotaWindow] = []
        if let five = root.fiveHour, let pct = five.utilization {
            windows.append(Self.window(label: "5 giờ", utilization: pct,
                                       resetsAt: five.resetsAt, seconds: 5 * 3600))
        }
        if let week = root.sevenDay, let pct = week.utilization {
            windows.append(Self.window(label: "Tuần", utilization: pct,
                                       resetsAt: week.resetsAt, seconds: 7 * 24 * 3600))
        }
        if let opus = root.sevenDayOpus, let pct = opus.utilization {
            windows.append(Self.window(label: "Opus", utilization: pct,
                                       resetsAt: opus.resetsAt, seconds: 7 * 24 * 3600))
        }
        if let sonnet = root.sevenDaySonnet, let pct = sonnet.utilization {
            windows.append(Self.window(label: "Sonnet", utilization: pct,
                                       resetsAt: sonnet.resetsAt, seconds: 7 * 24 * 3600))
        }
        guard !windows.isEmpty else { return failure("Claude chưa có dữ liệu quota") }

        // Plan + account email come from the same Keychain blob the token is read from.
        let credentials = KeychainRoot.decode(keychainData: Self.readKeychainData())
        let planName = ClaudePlan.label(forSubscriptionType: credentials?.subscriptionType,
                                        rateLimitTier: credentials?.rateLimitTier)

        return ProviderStatus(
            id: id,
            displayName: displayName,
            windows: windows,
            lastUpdated: Date(),
            error: nil,
            accountLabel: accountLabel ?? credentials?.email,
            creditsRemaining: Self.spendRemaining(extraUsage: root.extraUsage),
            planName: planName)
    }

    /// If `extra_usage` is enabled and has a monthly_limit + used_credits,
    /// return the remaining balance. nil when not enabled or limits are absent.
    /// We surface it via `creditsRemaining` so the existing UI cell shows it.
    private static func spendRemaining(extraUsage: ExtraUsage?) -> Double? {
        guard let e = extraUsage, e.isEnabled == true,
              let limit = e.monthlyLimit, let used = e.usedCredits else { return nil }
        return max(0, limit - used)
    }

    /// `utilization` is a percent already used (0..100).
    private static func window(label: String, utilization: Double,
                               resetsAt: String?, seconds: Int) -> QuotaWindow {
        let used = max(0, min(100, Int(utilization.rounded())))
        return QuotaWindow(
            label: label,
            usedPct: used,
            remainingPct: 100 - used,
            resetDate: parseISO8601(resetsAt),
            windowSeconds: seconds)
    }

    static func parseISO8601(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(
            id: id,
            displayName: displayName,
            windows: [],
            lastUpdated: Date(),
            error: message,
            version: Self.detectedClaudeVersion())
    }

    /// Failure path that still surfaces side data (service status + cost).
    /// Used when OAuth fails but the cookie-based cost scrape succeeded —
    /// matches CodexBar which shows "last fetch failed" alongside the Cost row.
    private func failure(_ message: String,
                         status: OpenAIServiceStatus?,
                         cost: ProviderCostSnapshot?) -> ProviderStatus {
        failure(message, status: status, cost: cost, extras: nil)
    }

    /// Failure path that also preserves the last successful web extras
    /// (account email / quota fallback percentages) so the panel stays
    /// informative across transient errors. Used when CodexBarCore throws
    /// but we have a cached snapshot from the previous attempt.
    private func failure(_ message: String,
                         status: OpenAIServiceStatus?,
                         cost: ProviderCostSnapshot?,
                         extras: ClaudeWebExtras?) -> ProviderStatus {
        ProviderStatus(
            id: id,
            displayName: displayName,
            windows: [],
            lastUpdated: Date(),
            error: message,
            version: Self.detectedClaudeVersion(),
            serviceStatus: status?.description,
            serviceStatusLevel: status?.indicator,
            cost: cost,
            webExtras: extras)
    }

    // MARK: - Keychain

    /// Reads `claudeAiOauth.accessToken` from the Claude Code keychain item.
    /// Returns nil if absent or access is denied. May trigger a macOS prompt.
    static func readKeychainToken() -> String? {
        return tokenFromKeychainJSON(readKeychainData() ?? Data())
    }

    /// Reads the raw keychain blob so the plan + email can be surfaced without
    /// paying the prompt cost twice. Returns nil if access is denied.
    private static func readKeychainData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return data
    }

    /// Parses the keychain JSON blob → access token. Exposed for tests.
    static func tokenFromKeychainJSON(_ data: Data) -> String? {
        guard let creds = KeychainRoot.decode(keychainData: data) else { return nil }
        let token = creds.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (token?.isEmpty ?? true) ? nil : token
    }

    // MARK: - Service status (status.anthropic.com)

    /// Cached output of `claude --version` so we don't spawn a process on
    /// every quota fetch. Set to the version string the CLI returned, or
    /// empty string when the binary is absent (so we still re-check, in case
    /// the user installs it later). UI surfaces it as
    /// `"2.1.185 (Claude Code)"` to match CodexBar.
    private static var cachedClaudeVersion: String?

    /// Detects the installed `claude` CLI version (memoized). Returns nil
    /// when the binary isn't on PATH.
    static func detectedClaudeVersion() -> String? {
        if let cached = cachedClaudeVersion {
            return cached.isEmpty ? nil : cached
        }
        let raw = ClaudeCLIVersionDetector.claudeVersion()
        cachedClaudeVersion = raw ?? ""
        return raw
    }

    // MARK: - Cost scrape (ClaudeWebAPIFetcher)

    /// Best-effort cost scrape via CodexBarCore's ClaudeWebAPIFetcher.
    /// Auto-detects browser cookies (Safari/Chrome via SweetCookieKit)
    /// and pulls today's spend + monthly limit from claude.ai. nil when:
    /// - no claude.ai session cookie is present in any browser,
    /// - the user denied Keychain access (CodexBar's BrowserCookieAccessGate
    /// Best-effort cost scrape via CodexBarCore's ClaudeWebAPIFetcher.
    /// Auto-detects browser cookies (Safari/Chrome via SweetCookieKit)
    /// and pulls today's spend + monthly limit from claude.ai. nil when:
    /// - no claude.ai session cookie is present in any browser,
    /// - the user denied Keychain access (CodexBar's BrowserCookieAccessGate
    ///   suppresses further attempts for 6h),
    /// - the network call or JSON parse failed,
    /// - the scrape didn't return within 5s (Keychain prompt for cookie
    ///   decryption may be hanging in the background — we bail so the main
    ///   quota refresh can still complete).
    /// We never throw — the cost row is optional UI and must not block the
    /// OAuth quota path. The 5s race also guarantees that a missed Keychain
    /// prompt on one fetch doesn't hang subsequent `QuotaService.refresh()`
    /// cycles for the lifetime of the process.
    static func fetchCost() async -> ProviderCostSnapshot? {
        await withTaskGroup(of: ProviderCostSnapshot?.self) { group in
            group.addTask {
                do {
                    let detection = BrowserDetection()
                    let data = try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: detection)
                    return data.extraUsageCost
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return nil
            }
            // First to finish wins; cancel the other so we don't keep
            // SweetCookieKit's serial cookie fetch running in the background.
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    // MARK: - Service status (status.anthropic.com)

    /// Best-effort fetch of Anthropic's public status. Mirrors Codex's
    /// `OpenAIServiceStatus` pattern: short timeout, never throws, returns nil
    /// on any failure so the main quota fetch isn't blocked by a flaky 3rd
    /// party endpoint.
    static func fetchServiceStatus() async -> OpenAIServiceStatus? {
        guard let url = URL(string: "https://status.anthropic.com/api/v2/summary.json") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 6
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: req)
        } catch {
            return nil
        }
        struct Payload: Decodable {
            struct Status: Decodable { let indicator: String?; let description: String? }
            let status: Status?
        }
        guard let p = try? JSONDecoder().decode(Payload.self, from: data),
              let s = p.status
        else { return nil }
        return OpenAIServiceStatus(indicator: s.indicator ?? "unknown",
                                   description: s.description ?? "Unknown")
    }

    // MARK: - Models

    /// Decoded shape of the Claude Code Keychain JSON. We keep this internal
    /// to ClaudeProvider because the OAuth token + plan both come from the
    /// same blob and have no other consumers.
    struct KeychainRoot: Decodable {
        let claudeAiOauth: OAuth?
        struct OAuth: Decodable {
            let accessToken: String?
            let rateLimitTier: String?
            let subscriptionType: String?
            let email: String?

            enum CodingKeys: String, CodingKey {
                case accessToken
                case rateLimitTier
                case subscriptionType
                case email
            }
        }

        /// Convenience init that swallows decode failures and returns nil —
        /// the keychain JSON is a Claude-Code-owned contract and we don't
        /// want one missing optional field to crash the quota fetch.
        static func decode(keychainData: Data?) -> OAuth? {
            guard let data = keychainData, !data.isEmpty else { return nil }
            guard let root = try? JSONDecoder().decode(KeychainRoot.self, from: data) else { return nil }
            return root.claudeAiOauth
        }
    }

    private struct UsageResponse: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let sevenDayOpus: Window?
        let sevenDaySonnet: Window?
        let extraUsage: ExtraUsage?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
            case extraUsage = "extra_usage"
        }
    }
    private struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?
        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }
    private struct ExtraUsage: Decodable {
        let isEnabled: Bool?
        let monthlyLimit: Double?
        let usedCredits: Double?
        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case monthlyLimit = "monthly_limit"
            case usedCredits = "used_credits"
        }
    }

    private struct StatusSummary: Decodable {
        struct Status: Decodable { let indicator: String?; let description: String? }
        let status: Status?
    }
}

/// Plan mapping mirroring CodexBar's `ClaudePlan`. We only need a human label
/// (`"Max"` / `"Pro"` / etc.) so we don't expose the full enum.
enum ClaudePlan {
    static func label(forSubscriptionType sub: String?, rateLimitTier tier: String?) -> String? {
        if let t = tier?.lowercased(), t.contains("max") { return "Max" }
        if let t = tier?.lowercased(), t.contains("ultra") { return "Ultra" }
        if let s = sub?.lowercased() {
            if s.contains("max") { return "Max" }
            if s.contains("ultra") { return "Ultra" }
            if s.contains("pro") { return "Pro" }
            if s.contains("team") { return "Team" }
            if s.contains("enterprise") { return "Enterprise" }
        }
        return nil
    }
}