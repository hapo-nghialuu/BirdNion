import Foundation
import os

// MARK: - FreemodelAccountStore

/// One FreeModel identity the app can fetch quota for.
/// - `browser` (default) scans all browsers for the first signed-in session.
/// - `browser:<id>` pins ONE specific browser's session — two browsers signed
///   in to two different FreeModel accounts appear as two entries.
/// - Managed accounts hold a user-pasted `bm_session` cookie header.
struct FreemodelAccount: Identifiable, Equatable {
    let id: String          // "browser", "browser:<browserID>", or a UUID
    let email: String?
    let label: String?      // custom label (managed) or browser name
    let isBrowser: Bool
}

/// FreeModel multi-account state — pattern-matched to `CodexAccountStore`:
/// managed accounts persist in their own metadata file under Application
/// Support (cookies are secrets — never in the shared settings.json), the
/// active id lives in UserDefaults.
enum FreemodelAccountStore {
    static let activeKey = "activeFreemodelAccount"
    static let browserID = "browser"
    static let browserPrefix = "browser:"

    private static func metadataURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("BirdNion", isDirectory: true)
            .appendingPathComponent("freemodel-accounts.json")
    }

    // MARK: Active selection

    static func activeID() -> String {
        UserDefaults.standard.string(forKey: activeKey) ?? browserID
    }

    static func setActive(_ id: String) {
        UserDefaults.standard.set(id, forKey: activeKey)
        NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
    }

    /// The stored cookie header for the ACTIVE account — nil for browser
    /// entries (live scan) or when the managed account vanished.
    static func activeCookieHeader() -> String? {
        let id = activeID()
        guard id != browserID, !id.hasPrefix(browserPrefix) else { return nil }
        return storedEntries().first(where: { $0.id == id })?.cookie
    }

    /// The pinned browser id when the active account is `browser:<id>`.
    static func activeBrowserID() -> String? {
        let id = activeID()
        guard id.hasPrefix(browserPrefix) else { return nil }
        return String(id.dropFirst(browserPrefix.count))
    }

    // MARK: Persistence

    private struct Stored: Codable { var accounts: [Entry] }
    private struct Entry: Codable {
        var id: String
        var email: String?
        var label: String?
        var cookie: String
    }

    private static func storedEntries() -> [Entry] {
        guard let data = try? Data(contentsOf: metadataURL()),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return [] }
        return stored.accounts
    }

    private static func persist(_ entries: [Entry]) throws {
        let url = metadataURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Stored(accounts: entries))
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Listing / mutation

    static func managedAccounts() -> [FreemodelAccount] {
        storedEntries().map {
            FreemodelAccount(id: $0.id, email: $0.email, label: $0.label, isBrowser: false)
        }
    }

    /// "Trình duyệt (tự động)" + one entry per signed-in browser + managed
    /// accounts. Browser detection is a blocking cookie-store read — call
    /// off-main. `emailResolver` (network) labels per-browser sessions.
    static func allAccounts(
        emailResolver: (String) async -> String? = { _ in nil }) async -> [FreemodelAccount]
    {
        var out = [FreemodelAccount(id: browserID, email: nil, label: nil, isBrowser: true)]
        let sessions = ProviderCookieReader.allBrowserSessions(
            domain: FreemodelProvider.cookieDomain, requiredCookie: "bm_session")
        for session in sessions {
            let email = await emailResolver(session.cookieHeader)
            out.append(FreemodelAccount(
                id: browserPrefix + session.browserID,
                email: email,
                label: session.browserName,
                isBrowser: true))
        }
        out.append(contentsOf: managedAccounts())
        return out
    }

    /// Stores a pasted cookie as a new managed account. The cookie must carry
    /// `bm_session` (a bare token is wrapped by the caller's filter).
    @discardableResult
    static func add(cookie: String, label: String?, email: String?) throws -> FreemodelAccount {
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = Entry(
            id: UUID().uuidString,
            email: email,
            label: (trimmedLabel?.isEmpty ?? true) ? nil : trimmedLabel,
            cookie: cookie)
        var entries = storedEntries()
        entries.append(entry)
        try persist(entries)
        return FreemodelAccount(id: entry.id, email: entry.email, label: entry.label, isBrowser: false)
    }

    /// Removes a managed account (no-op for browser entries); the active
    /// selection falls back to the auto browser scan.
    static func remove(_ id: String) throws {
        guard id != browserID, !id.hasPrefix(browserPrefix) else { return }
        try persist(storedEntries().filter { $0.id != id })
        if activeID() == id {
            setActive(browserID)
        }
    }
}

/// FreeModel quota provider.
///
/// Authenticates via the `bm_session` browser cookie set by freemodel.dev —
/// scraped automatically through `ProviderCookieReader`, the same path the
/// other cookie providers (CommandCode / MiMo / Cursor …) use. No API token.
///
/// Endpoints:
///   GET https://freemodel.dev/api/usage      → 5h + weekly dollar budgets
///   GET https://freemodel.dev/api/auth/me    → account email (label only)
///
/// Usage response shape:
/// ```json
/// { "window5h":   { "usedCents": 2250, "limitCents": 20000,  "resetsAt": 1782724407 },
///   "windowWeek": { "usedCents": 8,    "limitCents": 132000, "resetsAt": 1783321795 } }
/// ```
/// (the endpoint also returns request/token totals we don't surface.)
///
/// `me` response shape: `{ "user": { "email": "…", … } }`.
/// `referral` + `billing` (best-effort) feed the "Số dư" bonus-credit window
/// mirroring the dashboard's "Current balance" card.
final class FreemodelProvider: QuotaProvider {
    let id = "freemodel"
    let displayName = "FreeModel"

    /// Cookie domain freemodel.dev sets the session cookie for.
    static let cookieDomain = "freemodel.dev"
    /// Session cookie name (Akamai bot-manager session). The dollar budgets are
    /// gated on this being present.
    private static let sessionCookieName = "bm_session"

    private static let usageURL = URL(string: "https://freemodel.dev/api/usage")!
    private static let meURL = URL(string: "https://freemodel.dev/api/auth/me")!
    /// Bonus-credit sources behind the dashboard's "Current balance" card:
    /// referral credits (+count) and the signup credit (cents).
    private static let referralURL = URL(string: "https://freemodel.dev/api/referral")!
    private static let billingURL = URL(string: "https://freemodel.dev/api/billing")!
    private static let webOrigin = "https://freemodel.dev"
    private static let referer = "https://freemodel.dev/dashboard/usage"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    private static let requestTimeout: TimeInterval = 15
    /// `/api/auth/me` only enriches the account label — keep its timeout short so a
    /// slow/hung email lookup never delays the quota `/api/usage` already returned.
    private static let accountTimeout: TimeInterval = 5

    private let session: URLSession
    private static let log = Logger(subsystem: "com.local.birdnion", category: "provider.freemodel")

    /// Account email cached after the first successful `/api/auth/me`; later polls
    /// reuse it instead of re-hitting the endpoint. Keyed by the cookie header so
    /// an account switch re-resolves the email.
    private var cachedEmail: String?
    private var cachedEmailCookie: String?

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - QuotaProvider

    func fetch() async throws -> ProviderStatus {
        // Multi-account resolution: a managed account's stored cookie → a
        // pinned `browser:<id>` entry's live read of THAT browser → the
        // default scan across all browsers. `bm_session` as the required
        // cookie makes every browser path skip stores that only hold stale
        // analytics/Stripe cookies.
        let rawHeader: String?
        if let stored = FreemodelAccountStore.activeCookieHeader() {
            rawHeader = stored
        } else if let browserID = FreemodelAccountStore.activeBrowserID() {
            rawHeader = ProviderCookieReader.cookieHeader(
                browserID: browserID, domain: Self.cookieDomain, requiredCookie: Self.sessionCookieName)
        } else {
            rawHeader = ProviderCookieReader.resolvedCookieHeader(
                providerID: id, domain: Self.cookieDomain, requiredCookie: Self.sessionCookieName)
        }
        let cookieHeader = rawHeader.flatMap { Self.filteredCookieHeader(from: $0) }
        guard let cookieHeader else {
            return failure("Chưa đăng nhập FreeModel trên trình duyệt")
        }

        let usageData: Data
        do {
            usageData = try await fetchEndpoint(url: Self.usageURL, cookieHeader: cookieHeader, timeout: Self.requestTimeout)
        } catch {
            Self.log.error("fetch: usage network error: \(error.localizedDescription, privacy: .public)")
            return failure("Network: \(error.localizedDescription)")
        }

        // Account email + bonus-balance cards are best-effort enrichment —
        // never block the budget windows on them.
        async let referralTask = Self.optionalFetch(
            url: Self.referralURL, cookieHeader: cookieHeader, session: session)
        async let billingTask = Self.optionalFetch(
            url: Self.billingURL, cookieHeader: cookieHeader, session: session)
        let accountLabel = await resolveAccountLabel(cookieHeader: cookieHeader)
        let referralData = await referralTask
        let billingData = await billingTask

        return parse(usageData: usageData, accountLabel: accountLabel,
                     referralData: referralData, billingData: billingData)
    }

    // MARK: - Parsing (static entry point for unit tests — no network I/O)

    static func _parseForTesting(usageData: Data, accountLabel: String?,
                                 referralData: Data? = nil,
                                 billingData: Data? = nil) -> ProviderStatus {
        FreemodelProvider().parse(usageData: usageData, accountLabel: accountLabel,
                                  referralData: referralData, billingData: billingData)
    }

    private func parse(usageData: Data, accountLabel: String?,
                       referralData: Data?, billingData: Data?) -> ProviderStatus {
        guard let usage = try? JSONDecoder().decode(UsageResponse.self, from: usageData) else {
            // Never log the raw body — it may carry account/billing/auth data.
            Self.log.error("parse: decode failed (bytes=\(usageData.count, privacy: .public))")
            return failure("Response /api/usage không hợp lệ")
        }

        var windows = [
            Self.window(label: "5 giờ", from: usage.window5h, windowSeconds: 5 * 3600),
            Self.window(label: "Tuần", from: usage.windowWeek, windowSeconds: 7 * 24 * 3600),
        ]
        if let balance = Self.balanceWindow(referralData: referralData, billingData: billingData) {
            windows.append(balance)
        }

        return ProviderStatus(
            id: id,
            displayName: displayName,
            windows: windows,
            lastUpdated: Date(),
            error: nil,
            accountLabel: accountLabel)
    }

    /// Dashboard "Current balance" (§ Extra usage) — bonus credits applied
    /// automatically before plan credits. remaining = referral credits +
    /// signup credit; total = remaining + used (matches the web card's
    /// "$used / $total" readout). nil when nothing was ever earned.
    static func balanceWindow(referralData: Data?, billingData: Data?) -> QuotaWindow? {
        guard let referralData,
              let referral = try? JSONDecoder().decode(ReferralResponse.self, from: referralData)
        else { return nil }
        let signupUSD = billingData
            .flatMap { try? JSONDecoder().decode(BillingResponse.self, from: $0) }
            .flatMap(\.signupCreditCents)
            .map { Double($0) / 100.0 } ?? 0

        let used = referral.used ?? 0
        let remaining = (referral.credits ?? 0) + signupUSD
        let total = remaining + used
        guard total > 0 else { return nil }

        let usedPct = max(0, min(100, Int((used / total * 100).rounded())))
        var subtitle = "\(UsageFormatter.usdString(used)) / \(UsageFormatter.usdString(total))"
        if let count = referral.count, count > 0 {
            subtitle += " · \(count) giới thiệu"
        }
        return QuotaWindow(
            label: "Số dư",
            usedPct: usedPct,
            remainingPct: 100 - usedPct,
            subtitle: subtitle,
            isSupplementary: true)
    }

    /// Map one freemodel dollar window into a QuotaWindow with a "$used / $limit"
    /// subtitle and reset countdown.
    private static func window(label: String, from w: UsageResponse.Window, windowSeconds: Int) -> QuotaWindow {
        let used = Double(w.usedCents) / 100.0
        let limit = Double(w.limitCents) / 100.0
        // When both used and limit are 0 (e.g. window not yet started), treat
        // as 0% used (100% remaining) but mark it as inactive so the menu bar
        // does not show "100%" for an unused window.
        let usedPct = (limit > 0 && used > 0) ? Int((used / limit * 100).rounded()) : 0
        let clamped = max(0, min(100, usedPct))
        return QuotaWindow(
            label: label,
            usedPct: clamped,
            remainingPct: 100 - clamped,
            subtitle: "\(UsageFormatter.usdString(used)) / \(UsageFormatter.usdString(limit))",
            resetDate: w.resetsAt > 0 ? Date(timeIntervalSince1970: TimeInterval(w.resetsAt)) : nil,
            windowSeconds: windowSeconds)
    }

    // MARK: - Account label

    private func resolveAccountLabel(cookieHeader: String) async -> String? {
        if let explicit = BirdNionConfigStore.accountLabel(provider: id), !explicit.isEmpty {
            return explicit
        }
        // Resolved once already — reuse it; don't re-hit /api/auth/me every
        // poll. Keyed by cookie so switching accounts re-resolves.
        if let cachedEmail, cachedEmailCookie == cookieHeader { return cachedEmail }
        guard let email = await Self.accountEmail(cookieHeader: cookieHeader) else { return nil }
        cachedEmail = email
        cachedEmailCookie = cookieHeader
        return email
    }

    /// `/api/auth/me` email for an arbitrary cookie header — shared with the
    /// account store's per-browser session labeling and add-account flow.
    static func accountEmail(
        cookieHeader: String,
        session: URLSession = .shared) async -> String?
    {
        guard let data = try? await Self.fetchEndpoint(
                url: Self.meURL, cookieHeader: cookieHeader,
                timeout: Self.accountTimeout, session: session),
              let me = try? JSONDecoder().decode(MeResponse.self, from: data),
              !me.user.email.isEmpty
        else {
            return nil
        }
        return me.user.email
    }

    // MARK: - Cookie filtering

    /// Forward every cookie from the browser header (freemodel validates the
    /// whole set, including the `__stripe_*` cookies) but only proceed when
    /// `bm_session` is present. A bare token (no `=`) is wrapped under the
    /// session name.
    static func filteredCookieHeader(from raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerate a full header line pasted from devtools ("Cookie: name=value; …").
        if trimmed.lowercased().hasPrefix("cookie:") {
            trimmed = String(trimmed.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else { return nil }

        if !trimmed.contains("=") {
            return "\(sessionCookieName)=\(trimmed)"
        }

        var pairs: [String] = []
        var hasSession = false
        for chunk in trimmed.split(separator: ";") {
            let t = chunk.trimmingCharacters(in: .whitespaces)
            guard let eq = t.firstIndex(of: "=") else { continue }
            let name = String(t[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { continue }
            pairs.append("\(name)=\(value)")
            if name == sessionCookieName { hasSession = true }
        }
        guard hasSession, !pairs.isEmpty else { return nil }
        return pairs.joined(separator: "; ")
    }

    // MARK: - Networking

    private func fetchEndpoint(url: URL, cookieHeader: String, timeout: TimeInterval) async throws -> Data {
        try await Self.fetchEndpoint(url: url, cookieHeader: cookieHeader, timeout: timeout, session: session)
    }

    /// Best-effort GET with the short account timeout — nil on any failure
    /// (enrichment endpoints must never fail the fetch).
    private static func optionalFetch(url: URL, cookieHeader: String,
                                      session: URLSession) async -> Data? {
        try? await fetchEndpoint(url: url, cookieHeader: cookieHeader,
                                 timeout: accountTimeout, session: session)
    }

    /// Static so the account store / add flow can validate arbitrary cookies.
    private static func fetchEndpoint(
        url: URL, cookieHeader: String, timeout: TimeInterval,
        session: URLSession = .shared) async throws -> Data
    {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(Self.webOrigin, forHTTPHeaderField: "Origin")
        req.setValue(Self.referer, forHTTPHeaderField: "Referer")

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw NSError(domain: "Freemodel", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"])
        }
        return data
    }

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }
}

// MARK: - Wire types

private struct UsageResponse: Decodable {
    let window5h: Window
    let windowWeek: Window
    struct Window: Decodable {
        let usedCents: Int
        let limitCents: Int
        let resetsAt: Int
    }
}

private struct MeResponse: Decodable {
    let user: User
    struct User: Decodable { let email: String }
}

/// `/api/referral` — `{ "count": 8, "credits": 53.22, "used": 67.22, … }`
/// (credits/used are dollars; the dashboard adds the signup credit on top).
private struct ReferralResponse: Decodable {
    let count: Int?
    let credits: Double?
    let used: Double?
}

/// `/api/billing` — only `signupCreditCents` is consumed here.
private struct BillingResponse: Decodable {
    let signupCreditCents: Int?
}
