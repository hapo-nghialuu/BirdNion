import CodexBarCore
import Foundation

/// Best-effort OpenAI web-dashboard scrape for Codex extras (code-review
/// remaining, credits balance, credits purchase URL). Wraps CodexBarCore's
/// browser-cookie importer + dashboard fetcher.
///
/// Opt-in (off by default): it loads chatgpt.com in a hidden WKWebView and
/// imports browser cookies, so it materially increases battery/network use.
/// Results are cached with a TTL to bound how often the WKWebView spawns on the
/// background poll; a manual refresh forces a re-scrape.
enum CodexWebDashboard {
    static let enabledKey = "codexOpenAIWebEnabled"
    static let cookieSourceKey = "codexCookieSource"        // ProviderCookieSource raw value
    static let manualCookieKey = "codexManualCookieHeader"
    private static let ttl: TimeInterval = 600
    private static let timeout: TimeInterval = 20

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private actor Cache {
        static let shared = Cache()
        private var entries: [String: (at: Date, value: CodexWebExtras)] = [:]
        func valid(key: String, now: Date, ttl: TimeInterval) -> CodexWebExtras? {
            guard let e = entries[key], now.timeIntervalSince(e.at) < ttl else { return nil }
            return e.value
        }
        func store(key: String, value: CodexWebExtras, at: Date) { entries[key] = (at, value) }
    }

    /// Extras for `email`'s account, cached for `ttl`. Returns nil when the
    /// feature is disabled or the scrape fails. `forceRefresh` bypasses the
    /// cache (used for user-initiated refreshes).
    static func extras(email: String?, now: Date = Date(), forceRefresh: Bool = false) async -> CodexWebExtras? {
        guard isEnabled else { return nil }
        let key = email ?? "system"
        if !forceRefresh, let cached = await Cache.shared.valid(key: key, now: now, ttl: ttl) {
            return cached
        }
        guard let snapshot = await scrape(email: email) else { return nil }
        let extras = map(snapshot)
        await Cache.shared.store(key: key, value: extras, at: now)
        return extras
    }

    /// Pure mapping (dashboard snapshot → BirdNion extras), unit-testable.
    static func map(_ s: OpenAIDashboardSnapshot) -> CodexWebExtras {
        CodexWebExtras(
            signedInEmail: s.signedInEmail,
            codeReviewRemainingPercent: s.codeReviewRemainingPercent
                .map { Int(max(0, min(100, $0)).rounded()) },
            creditsRemaining: s.creditsRemaining,
            creditsPurchaseURL: s.creditsPurchaseURL,
            creditsHistoryCount: s.creditEvents.isEmpty ? nil : s.creditEvents.count)
    }

    // MARK: - Scrape

    @MainActor
    private static func scrape(email: String?) async -> OpenAIDashboardSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        let cookieSource = ProviderCookieSource(
            rawValue: UserDefaults.standard.string(forKey: cookieSourceKey) ?? "") ?? .auto
        let manual = UserDefaults.standard.string(forKey: manualCookieKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let importer = OpenAIDashboardBrowserCookieImporter(browserDetection: BrowserDetection())
        do {
            let importResult: OpenAIDashboardBrowserCookieImporter.ImportResult
            if cookieSource == .manual, let manual, !manual.isEmpty {
                importResult = try await importer.importManualCookies(
                    cookieHeader: manual,
                    intoAccountEmail: email,
                    allowAnyAccount: email == nil,
                    deadline: deadline)
            } else {
                importResult = try await importer.importBestCookies(
                    intoAccountEmail: email,
                    allowAnyAccount: email == nil,
                    deadline: deadline)
            }
            let effectiveEmail = email ?? importResult.signedInEmail
            return try await OpenAIDashboardFetcher().loadLatestDashboard(
                accountEmail: effectiveEmail,
                timeout: max(1, deadline.timeIntervalSinceNow))
        } catch {
            return nil
        }
    }
}
