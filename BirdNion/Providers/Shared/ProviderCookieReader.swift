import Foundation
import SweetCookieKit

// MARK: - BrowserCookieSerialGate

/// App-wide serialization for **all** SweetCookieKit browser reads.
///
/// SweetCookieKit's reader is not safe to drive from multiple threads at once
/// (concurrent SQLite + keychain decryption corrupts the heap → `EXC_BREAKPOINT`
/// "memory corruption of free block"). `QuotaService.refresh` fans every
/// provider's `fetch()` out across a `TaskGroup`, so Claude (`ClaudeWebCookieReader`)
/// and the cookie providers (`ProviderCookieReader`) used to read browsers
/// concurrently behind two *independent* locks. They must share **one** lock so
/// only a single browser read runs at a time. The lock is held only for the
/// cookie-store read, never across network I/O.
enum BrowserCookieSerialGate {
    static let lock = NSLock()
}

// MARK: - ProviderCookieReader

/// Generic browser-cookie reader for providers that authenticate via session cookies.
///
/// Mirrors ClaudeWebCookieReader's cooldown-gate pattern but is parameterised by
/// domain so any provider can reuse it without duplicating the SweetCookieKit wiring.
///
/// Usage:
/// ```swift
/// let header = ProviderCookieReader.cookieHeader(domain: "commandcode.ai")
/// ```
enum ProviderCookieReader {

    // MARK: - Cooldown gate

    /// UserDefaults key prefix; append the domain to avoid key collisions.
    private static let deniedUntilKeyPrefix = "providerCookieDeniedUntil_"

    /// Why a browser's data could not be read — mirrors upstream CodexBar's
    /// `BrowserProfileAccessIssue`: "macOS blocked access" (fixable via
    /// Privacy & Security) is a different problem from "the store itself is
    /// broken" (transient I/O, corruption — no toggle helps).
    enum AccessIssueKind {
        case accessDenied
        case unreadable
    }

    /// Which browsers were blocked and how — the provider surfaces this as its
    /// error text so the user sees exactly which browser toggle to flip.
    struct AccessIssue {
        var kind: AccessIssueKind
        var browserNames: [String]

        var message: String {
            let names = browserNames.joined(separator: ", ")
            switch kind {
            case .accessDenied:
                return "macOS đã chặn BirdNion đọc phiên đăng nhập trong \(names) — bật quyền truy cập trình duyệt cho app trong Privacy & Security → Files & Folders rồi thử lại"
            case .unreadable:
                return "Không đọc được dữ liệu trình duyệt \(names) — thử lại sau, hoặc đổi Cookie source sang Manual"
            }
        }
    }

    /// Generic access-denied text for callers that cannot name the browser
    /// (Claude's session-key sweep reports a Bool, not an AccessIssue).
    static let browserDataDeniedMessage =
        "Thiếu quyền đọc dữ liệu trình duyệt — bật quyền truy cập trình duyệt " +
        "cho app trong Privacy & Security → Files & Folders rồi thử lại"

    // MARK: - Public API

    /// Returns a `Cookie:` header value for `domain`, built from all cookie records
    /// in the first browser store that has cookies for that domain.
    ///
    /// Returns `nil` when:
    /// - No browser has cookies for this domain.
    /// - The cooldown gate is active (a previous read was denied by Full Disk Access / Keychain).
    ///
    /// Tries Safari first (no Keychain prompt), then `Browser.defaultImportOrder`.
    ///
    /// No pre-emptive cooldown block: every call attempts the read so the macOS
    /// Keychain "<Browser> Safe Storage" prompt can appear (and the user can pick
    /// "Always Allow"). Once granted, SweetCookieKit caches the key so there's no
    /// repeat prompt; the cooldown is only recorded for telemetry/back-off hints.
    /// - Parameter requiredCookie: when set (e.g. a session cookie name), only a
    ///   browser store that actually contains that cookie is accepted; stores
    ///   that merely have *some* cookies for the domain (stale analytics/Stripe
    ///   leftovers in another browser) are skipped. nil keeps the legacy
    ///   "first store with any cookie wins" behavior.
    static func cookieHeader(
        domain: String,
        requiredCookie: String? = nil,
        accessIssue: UnsafeMutablePointer<AccessIssue?>? = nil
    ) -> String? {
        cookieHeader(
            domain: domain,
            matchingSession: requiredCookie.map { name in { $0 == name } },
            accessIssue: accessIssue)
    }

    /// Same, but the session cookie is identified by a predicate — for providers
    /// whose session cookie name varies by deployment (CommandCode ships three
    /// prefixes, OpenCode two).
    /// - Parameter accessIssue: when non-nil, populated with the browsers and
    ///   failure kind when the read could not even look — macOS blocked access
    ///   (app-data protection / Full Disk Access / Keychain denial) or the
    ///   store was unreadable — rather than "no session found".
    static func cookieHeader(
        domain: String,
        matchingSession: ((String) -> Bool)?,
        accessIssue: UnsafeMutablePointer<AccessIssue?>? = nil
    ) -> String? {
        BrowserCookieSerialGate.lock.lock()
        defer { BrowserCookieSerialGate.lock.unlock() }
        return extractFromBrowsers(
            domain: domain, matchesSession: matchingSession,
            accessIssue: accessIssue)
    }

    /// Resolves the cookie header honoring the provider's "cookie source"
    /// preference (UserDefaults `<providerID>CookieSource`: auto/manual/off).
    /// `manual` reads a user-pasted Cookie header from `<providerID>ManualCookie`.
    static func resolvedCookieHeader(
        providerID: String,
        domain: String,
        requiredCookie: String? = nil,
        accessIssue: UnsafeMutablePointer<AccessIssue?>? = nil
    ) -> String? {
        resolvedCookieHeader(
            providerID: providerID,
            domain: domain,
            matchingSession: requiredCookie.map { name in { $0 == name } },
            accessIssue: accessIssue)
    }

    /// Same, with a predicate instead of an exact session cookie name.
    /// `accessIssue` is only ever set by the `auto` path — `off`/`manual`
    /// never touch the filesystem, so they never report an access failure.
    static func resolvedCookieHeader(
        providerID: String,
        domain: String,
        matchingSession: ((String) -> Bool)?,
        accessIssue: UnsafeMutablePointer<AccessIssue?>? = nil
    ) -> String? {
        let source = UserDefaults.standard.string(forKey: "\(providerID)CookieSource") ?? "auto"
        switch source {
        case "off":
            return nil
        case "manual":
            let raw = UserDefaults.standard.string(forKey: "\(providerID)ManualCookie")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw?.isEmpty ?? true) ? nil : raw
        default:
            return cookieHeader(
                domain: domain, matchingSession: matchingSession,
                accessIssue: accessIssue)
        }
    }

    /// One signed-in browser session for a domain: which browser and the full
    /// cookie header from that browser's store.
    struct BrowserSession {
        /// Stable id (`Browser.rawValue`, e.g. "chrome").
        let browserID: String
        /// Human name ("Chrome", "Brave"…).
        let browserName: String
        let cookieHeader: String
    }

    /// EVERY browser whose store holds `requiredCookie` for `domain`, in scan
    /// order — lets multi-account UIs surface each signed-in browser as its
    /// own selectable session (two browsers logged in to two accounts).
    static func allBrowserSessions(
        domain: String,
        requiredCookie: String,
        accessIssue: UnsafeMutablePointer<AccessIssue?>? = nil
    ) -> [BrowserSession] {
        BrowserCookieSerialGate.lock.lock()
        defer { BrowserCookieSerialGate.lock.unlock() }

        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: [domain])
        var sessions: [BrowserSession] = []

        func collect(_ browser: Browser) {
            // Preflight probe (upstream CodexBar does the same in
            // `isCookieSourceAvailable`): a browser whose data dir macOS
            // refuses to enumerate can never yield cookies — skip it before
            // the read, so it cannot even trigger a wasted "Safe Storage"
            // Keychain prompt.
            if let issue = browserAccessIssue(browser) {
                note(issue, browser: browser, into: accessIssue)
                if issue == .accessDenied {
                    recordCooldownIfNeeded(
                        .accessDenied(
                            browser: browser,
                            details: "macOS blocked browser data access"),
                        domain: domain)
                }
                return
            }
            do {
                let storeRecords = try client.records(matching: query, in: browser)
                // Same detached-snapshot dance as extractFromBrowsers (see the
                // memory-corruption note there).
                for store in storeRecords {
                    let pairs: [CookiePair] = store.records.map { rec in
                        CookiePair(
                            name: String(decoding: Array(rec.name.utf8), as: UTF8.self),
                            value: String(decoding: Array(rec.value.utf8), as: UTF8.self),
                            expires: rec.expires)
                    }
                    guard firstUsableStore([pairs], matchesSession: { $0 == requiredCookie }) != nil
                    else { continue }
                    sessions.append(BrowserSession(
                        browserID: browser.rawValue,
                        browserName: browser.displayName,
                        cookieHeader: buildCookieHeader(from: pairs)))
                    return // one session per browser (first matching store)
                }
            } catch let error as BrowserCookieError {
                if Self.permissionBlocksReads(of: browser, error: error) {
                    note(.accessDenied, browser: browser, into: accessIssue)
                    recordCooldownIfNeeded(
                        Self.cooldownCause(error, browser: browser), domain: domain)
                } else {
                    recordCooldownIfNeeded(error, domain: domain)
                }
            } catch {
                // browser not installed / store unreadable — skip
                if let issue = browserAccessIssue(browser) {
                    note(issue, browser: browser, into: accessIssue)
                    if issue == .accessDenied {
                        recordCooldownIfNeeded(
                            .accessDenied(
                                browser: browser,
                                details: "macOS blocked browser data access"),
                            domain: domain)
                    }
                }
            }
        }

        for browser in browserSearchOrder { collect(browser) }
        return sessions
    }

    /// Cookie header from ONE specific browser (by `Browser.rawValue`), gated
    /// on `requiredCookie` — used when the user pinned a per-browser account.
    static func cookieHeader(
        browserID: String,
        domain: String,
        requiredCookie: String,
        accessIssue: UnsafeMutablePointer<AccessIssue?>? = nil
    ) -> String? {
        allBrowserSessions(
            domain: domain, requiredCookie: requiredCookie,
            accessIssue: accessIssue)
            .first(where: { $0.browserID == browserID })?
            .cookieHeader
    }

    // MARK: - Browser iteration

    /// Browser precedence for cookie reads: Safari first because it is the one
    /// store that needs no Keychain prompt, then Brave ahead of Chrome, then
    /// SweetCookieKit's order. Rank only breaks ties — a browser without a live
    /// session is skipped no matter how early it sits.
    static let browserSearchOrder: [Browser] = {
        var order: [Browser] = [.safari, .brave]
        for browser in Browser.defaultImportOrder where !order.contains(browser) {
            order.append(browser)
        }
        return order
    }()

    /// Internal for testing: the search order as stable ids. The test target
    /// does not link SweetCookieKit, so it cannot name `Browser` itself.
    static var browserSearchOrderIDs: [String] {
        browserSearchOrder.map(\.rawValue)
    }

    private static func extractFromBrowsers(
        domain: String,
        matchesSession: ((String) -> Bool)?,
        accessIssue: UnsafeMutablePointer<AccessIssue?>? = nil
    ) -> String? {
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: [domain])

        func tryBrowser(_ browser: Browser) -> String? {
            // Preflight probe — same idea as CodexBar's isCookieSourceAvailable:
            // skip browsers macOS blocks before the read can reach Keychain.
            if let issue = browserAccessIssue(browser) {
                note(issue, browser: browser, into: accessIssue)
                if issue == .accessDenied {
                    recordCooldownIfNeeded(
                        .accessDenied(
                            browser: browser,
                            details: "macOS blocked browser data access"),
                        domain: domain)
                }
                return nil
            }
            do {
                let storeRecords = try client.records(matching: query, in: browser)
                // Snapshot name+value into freshly-allocated Strings *immediately*,
                // before any further SweetCookieKit access. SweetCookieKit's records
                // buffer can be freed/corrupted underneath us (use-after-free in its
                // Chromium cookie decryption → "memory corruption of free block" crash
                // in String append). Round-tripping through UTF8 bytes detaches every
                // downstream String from that storage so nothing afterwards touches
                // the dependency's (possibly freed) memory.
                let stores: [[CookiePair]] = storeRecords.map { store in
                    store.records.map { rec in
                        CookiePair(
                            name: String(decoding: Array(rec.name.utf8), as: UTF8.self),
                            value: String(decoding: Array(rec.value.utf8), as: UTF8.self),
                            expires: rec.expires)
                    }
                }
                guard let store = firstUsableStore(stores, matchesSession: matchesSession)
                else { return nil }
                let header = buildCookieHeader(from: store)
                return header.isEmpty ? nil : header
            } catch let error as BrowserCookieError {
                if Self.permissionBlocksReads(of: browser, error: error) {
                    note(.accessDenied, browser: browser, into: accessIssue)
                    recordCooldownIfNeeded(
                        Self.cooldownCause(error, browser: browser), domain: domain)
                } else {
                    recordCooldownIfNeeded(error, domain: domain)
                }
            } catch {
                // notFound / loadFailed — browser not installed or store unreadable; skip silently.
                if let issue = browserAccessIssue(browser) {
                    note(issue, browser: browser, into: accessIssue)
                    if issue == .accessDenied {
                        recordCooldownIfNeeded(
                            .accessDenied(
                                browser: browser,
                                details: "macOS blocked browser data access"),
                            domain: domain)
                    }
                }
            }
            return nil
        }

        for browser in browserSearchOrder {
            if let header = tryBrowser(browser) { return header }
        }
        // No browser carried a live session cookie for this domain.
        return nil
    }

    // MARK: - macOS app-data protection probe

    /// Merge one browser's access issue into the out-param: names are deduped,
    /// and `.accessDenied` outranks `.unreadable` for the headline kind (the
    /// permission grant fixes it; unreadable just means "retry later").
    private static func note(
        _ kind: AccessIssueKind, browser: Browser,
        into ptr: UnsafeMutablePointer<AccessIssue?>?
    ) {
        guard let ptr else { return }
        let name = browser.displayName
        if var issue = ptr.pointee {
            if !issue.browserNames.contains(name) { issue.browserNames.append(name) }
            if issue.kind != .accessDenied { issue.kind = kind }
            ptr.pointee = issue
        } else {
            ptr.pointee = AccessIssue(kind: kind, browserNames: [name])
        }
    }

    /// Whether a store failure means "blocked" rather than "no cookies".
    ///
    /// SweetCookieKit collapses several distinct failures into the same errors:
    /// a real `.accessDenied` (Safari needs Full Disk Access; a denied
    /// "<Browser> Safe Storage" keychain prompt) is already a permission
    /// problem, and since macOS 27 the app-data protection (`com.apple.macl`
    /// on Chrome/Brave/Edge/Firefox data dirs) makes profile enumeration fail
    /// with `EPERM` — but the dependency enumerates with `try?` and reports
    /// `notFound`, which would surface here as a fake "not signed in".
    private static func permissionBlocksReads(
        of browser: Browser, error: BrowserCookieError
    ) -> Bool {
        if case .accessDenied = error { return true }
        return browserAccessIssue(browser) == .accessDenied
    }

    /// Keeps the cooldown record honest: an EPERM-mapped `notFound` is logged
    /// as `.accessDenied` so telemetry reflects "blocked", while a genuine
    /// access-denied error keeps its original details.
    private static func cooldownCause(
        _ error: BrowserCookieError, browser: Browser
    ) -> BrowserCookieError {
        if case .accessDenied = error { return error }
        return .accessDenied(
            browser: browser, details: "macOS blocked browser data access")
    }

    /// Probe this browser's own data root — distinguishes "macOS blocked us"
    /// from "the store is broken" from "not installed", per browser.
    ///
    /// The app-data protection denies directory *contents* while plain `stat`
    /// still succeeds, so "root exists but `contentsOfDirectory` throws
    /// EPERM/EACCES" means `.accessDenied`; any other read error on an
    /// existing dir means `.unreadable`; missing/unreadable-free dirs mean
    /// nil (browser simply isn't there — not an access problem).
    ///
    /// Same model as upstream CodexBar's `BrowserDetection.probeProfileAccessIssue`.
    /// Probing only THIS browser's root (unlike the earlier any-dir heuristic)
    /// keeps the blame accurate — a blocked Firefox dir must not brand a
    /// failed Brave read as denied.
    ///
    /// Internal (not private): ClaudeWebCookieReader shares the same probe.
    static func browserAccessIssue(_ browser: Browser) -> AccessIssueKind? {
        let fm = FileManager.default
        let candidates: [URL]
        if browser == .firefox {
            candidates = BrowserCookieClient.defaultHomeDirectories().map {
                $0.appendingPathComponent("Library/Application Support/Firefox")
            }
        } else {
            candidates = ChromiumProfileLocator.roots(for: [browser]).map(\.url)
        }
        var sawUnreadable = false
        for root in candidates where fm.fileExists(atPath: root.path) {
            do {
                _ = try fm.contentsOfDirectory(atPath: root.path)
            } catch {
                if isPermissionError(error) { return .accessDenied }
                sawUnreadable = true
            }
        }
        return sawUnreadable ? .unreadable : nil
    }

    /// Recursive NSError classification — same set upstream treats as a
    /// permission problem: Cocoa `fileReadNoPermission` (257) and POSIX
    /// `EACCES`/`EPERM`, including errors wrapped in `NSUnderlyingErrorKey`.
    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileReadNoPermission.rawValue
        {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
        {
            return true
        }
        guard let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error
        else { return false }
        return isPermissionError(underlying)
    }

    // MARK: - Cookie header builder

    /// A detached snapshot of a single cookie's name+value. Holds no reference to
    /// SweetCookieKit storage, so it is safe to use after the source records array
    /// has been (potentially) freed/corrupted by the dependency.
    struct CookiePair {
        let name: String
        let value: String
        /// nil = session cookie (dies with the browser process, never stale on
        /// disk). A past date = the browser would no longer send it either.
        let expires: Date?

        init(name: String, value: String, expires: Date? = nil) {
            self.name = name
            self.value = value
            self.expires = expires
        }

        func isLive(now: Date = Date()) -> Bool {
            guard let expires else { return true }
            return expires > now
        }
    }

    /// Internal for testing. The first store that still holds a LIVE session
    /// cookie.
    ///
    /// "Has some cookie for this domain" is NOT evidence of a usable session:
    /// Chromium keeps expired rows in the store, and long-lived analytics
    /// cookies (`_ga`, `__stripe_mid`) outlive the login by months. Picking a
    /// store on that basis let a browser the user signed out of hours ago beat
    /// the one they are actually signed in to — measured on commandcode.ai,
    /// where Chrome's session died at 20:17 while Brave's was good for six more
    /// days.
    static func firstUsableStore(
        _ stores: [[CookiePair]],
        matchesSession: ((String) -> Bool)?,
        now: Date = Date()
    ) -> [CookiePair]? {
        stores.first { store in
            store.contains { pair in
                pair.isLive(now: now) && (matchesSession?(pair.name) ?? true)
            }
        }
    }

    /// Expired cookies are dropped: a real browser would not send them, and
    /// including one lets a dead session token shadow a live one.
    private static func buildCookieHeader(from records: [CookiePair], now: Date = Date()) -> String {
        records
            .filter { $0.isLive(now: now) }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    // MARK: - 6-hour cooldown gate

    private static func deniedUntilKey(domain: String) -> String {
        deniedUntilKeyPrefix + domain
    }

    private static func cooldownDate(domain: String) -> Date? {
        UserDefaults.standard.object(forKey: deniedUntilKey(domain: domain)) as? Date
    }

    /// Cooldown after an access-denied so we don't re-trigger the macOS Keychain
    /// prompt on every background poll. Kept SHORT (5 min) so a user who clicks
    /// Refresh — or grants "Always Allow" — gets a fresh attempt quickly rather
    /// than being locked out for hours.
    private static let cooldownSeconds: TimeInterval = 5 * 60

    private static func recordCooldownIfNeeded(_ error: BrowserCookieError, domain: String) {
        if case .accessDenied = error {
            let suppressUntil = Date().addingTimeInterval(cooldownSeconds)
            UserDefaults.standard.set(suppressUntil, forKey: deniedUntilKey(domain: domain))
        }
    }
}
