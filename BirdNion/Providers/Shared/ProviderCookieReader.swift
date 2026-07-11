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
    static func cookieHeader(domain: String, requiredCookie: String? = nil) -> String? {
        BrowserCookieSerialGate.lock.lock()
        defer { BrowserCookieSerialGate.lock.unlock() }
        return extractFromBrowsers(domain: domain, requiredCookie: requiredCookie)
    }

    /// Resolves the cookie header honoring the provider's "cookie source"
    /// preference (UserDefaults `<providerID>CookieSource`: auto/manual/off).
    /// `manual` reads a user-pasted Cookie header from `<providerID>ManualCookie`.
    static func resolvedCookieHeader(providerID: String, domain: String, requiredCookie: String? = nil) -> String? {
        let source = UserDefaults.standard.string(forKey: "\(providerID)CookieSource") ?? "auto"
        switch source {
        case "off":
            return nil
        case "manual":
            let raw = UserDefaults.standard.string(forKey: "\(providerID)ManualCookie")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw?.isEmpty ?? true) ? nil : raw
        default:
            return cookieHeader(domain: domain, requiredCookie: requiredCookie)
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
    static func allBrowserSessions(domain: String, requiredCookie: String) -> [BrowserSession] {
        BrowserCookieSerialGate.lock.lock()
        defer { BrowserCookieSerialGate.lock.unlock() }

        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: [domain])
        var sessions: [BrowserSession] = []

        func collect(_ browser: Browser) {
            do {
                let storeRecords = try client.records(matching: query, in: browser)
                // Same detached-snapshot dance as extractFromBrowsers (see the
                // memory-corruption note there).
                for store in storeRecords {
                    let pairs: [CookiePair] = store.records.map { rec in
                        CookiePair(
                            name: String(decoding: Array(rec.name.utf8), as: UTF8.self),
                            value: String(decoding: Array(rec.value.utf8), as: UTF8.self))
                    }
                    guard !pairs.isEmpty, pairs.contains(where: { $0.name == requiredCookie }) else { continue }
                    sessions.append(BrowserSession(
                        browserID: browser.rawValue,
                        browserName: browser.displayName,
                        cookieHeader: buildCookieHeader(from: pairs)))
                    return // one session per browser (first matching store)
                }
            } catch let error as BrowserCookieError {
                recordCooldownIfNeeded(error, domain: domain)
            } catch {
                // browser not installed / store unreadable — skip
            }
        }

        collect(.safari)
        for browser in Browser.defaultImportOrder where browser != .safari {
            collect(browser)
        }
        return sessions
    }

    /// Cookie header from ONE specific browser (by `Browser.rawValue`), gated
    /// on `requiredCookie` — used when the user pinned a per-browser account.
    static func cookieHeader(browserID: String, domain: String, requiredCookie: String) -> String? {
        allBrowserSessions(domain: domain, requiredCookie: requiredCookie)
            .first(where: { $0.browserID == browserID })?
            .cookieHeader
    }

    // MARK: - Browser iteration

    private static func extractFromBrowsers(domain: String, requiredCookie: String?) -> String? {
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: [domain])

        func tryBrowser(_ browser: Browser) -> String? {
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
                            value: String(decoding: Array(rec.value.utf8), as: UTF8.self))
                    }
                }
                guard let requiredCookie else {
                    // Legacy path: first store with any cookie wins.
                    if let first = stores.first, !first.isEmpty {
                        return buildCookieHeader(from: first)
                    }
                    return nil
                }
                // Session-aware path: only accept a store that actually holds the
                // required cookie. A browser carrying just stale analytics/Stripe
                // cookies for this domain is skipped — we never return a header that
                // is missing the required cookie (the parameter name promises it is
                // present, so callers may rely on that).
                for store in stores where !store.isEmpty {
                    if store.contains(where: { $0.name == requiredCookie }) {
                        return buildCookieHeader(from: store)
                    }
                }
                return nil
            } catch let error as BrowserCookieError {
                recordCooldownIfNeeded(error, domain: domain)
            } catch {
                // notFound / loadFailed — browser not installed or store unreadable; skip silently.
            }
            return nil
        }

        // Safari first — no Keychain prompt needed.
        if let header = tryBrowser(.safari) { return header }
        for browser in Browser.defaultImportOrder where browser != .safari {
            if let header = tryBrowser(browser) { return header }
        }
        // No browser carried the required cookie (or any cookie on the legacy path).
        return nil
    }

    // MARK: - Cookie header builder

    /// A detached snapshot of a single cookie's name+value. Holds no reference to
    /// SweetCookieKit storage, so it is safe to use after the source records array
    /// has been (potentially) freed/corrupted by the dependency.
    private struct CookiePair {
        let name: String
        let value: String
    }

    private static func buildCookieHeader(from records: [CookiePair]) -> String {
        records.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
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
