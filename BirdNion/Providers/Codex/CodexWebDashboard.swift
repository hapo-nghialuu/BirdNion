import CodexBarCore
import Foundation

/// Best-effort OpenAI web-dashboard scrape for Codex extras (code-review
/// remaining, credits balance, credits purchase URL). Wraps CodexBarCore's
/// browser-cookie importer + dashboard fetcher.
///
/// Opt-in (off by default): it loads chatgpt.com in a hidden WKWebView and
/// imports browser cookies, so it materially increases memory/network use.
/// The scrape only runs while the popover is open (`popoverIsOpen`) or on a
/// manual refresh; results are cached with a TTL to bound how often the
/// WKWebView re-spawns, and a closed popover is served the last cached value.
enum CodexWebDashboard {
    static let enabledKey = "codexOpenAIWebEnabled"
    static let cookieSourceKey = "codexCookieSource"        // ProviderCookieSource raw value
    static let manualCookieKey = "codexManualCookieHeader"
    private static let ttl: TimeInterval = 1800
    private static let timeout: TimeInterval = 20

    /// Set by AppDelegate when the quota popover shows/hides. The WKWebView
    /// scrape only runs while the popover is open or on a manual refresh —
    /// background ticks never spawn the webview for a result nobody can see
    /// (a chatgpt.com render transiently allocates hundreds of MB).
    nonisolated(unsafe) static var popoverIsOpen = false

    /// Whether a scrape may spawn the WKWebView right now: popover open, or
    /// a user-initiated refresh.
    static func mayScrape(forceRefresh: Bool) -> Bool {
        popoverIsOpen || forceRefresh
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private actor Cache {
        static let shared = Cache()
        private var entries: [String: (at: Date, value: CodexWebExtras)] = [:]
        func valid(key: String, now: Date, ttl: TimeInterval) -> CodexWebExtras? {
            guard let e = entries[key], now.timeIntervalSince(e.at) < ttl else { return nil }
            return e.value
        }
        /// Last stored extras regardless of age — served while the popover is
        /// closed so stale fields stay on the next open without a scrape.
        func latest(key: String) -> CodexWebExtras? { entries[key]?.value }
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
        // Popover closed + not a manual refresh: serve whatever is cached
        // (even past TTL) and never spawn the WKWebView — extras only render
        // inside the popover, so a background scrape pays real memory for
        // data nobody can see.
        guard mayScrape(forceRefresh: forceRefresh) else {
            return await Cache.shared.latest(key: key)
        }
        guard let snapshot = await scrape(email: email) else { return nil }
        // Ownership guard: if the caller supplied a specific email, discard the
        // snapshot when the dashboard reports a *different* signed-in account.
        // This prevents data from one account leaking into another account's UI.
        if let requestedEmail = email,
           let signedIn = snapshot.signedInEmail,
           requestedEmail.lowercased() != signedIn.lowercased()
        {
            return nil
        }
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
