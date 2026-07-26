import Foundation
import SweetCookieKit

// MARK: - SessionKeyInfo

struct SessionKeyInfo: Sendable {
    let key: String
    let cookieHeader: String
}

// MARK: - ClaudeWebCookieReader

/// Native claude.ai sessionKey extractor using SweetCookieKit directly.
/// Mirrors CodexBar's BrowserCookieAccessGate + extractSessionKeyInfo pattern
/// but self-contained — no CodexBarCore dependency.
enum ClaudeWebCookieReader {

    // MARK: - UserDefaults keys

    /// Cooldown gate key. Must not collide with CodexBar's key.
    private static let deniedUntilKey = "claudeBrowserCookieDeniedUntil"

    // MARK: - Public API

    /// True while browser cookie reads are in the denial-cooldown window.
    /// The source planner uses this to drop the web step from the auto plan —
    /// otherwise the step runs, fails instantly on the suppressed cookie read,
    /// and its error masks the (more informative) CLI error.
    static var isAutoSuppressed: Bool {
        guard let until = cooldownDate() else { return false }
        return Date() < until
    }

    /// Auto-detect the claude.ai sessionKey across browsers.
    ///
    /// Tries Safari first (no Keychain prompt), then iterates Browser.defaultImportOrder.
    /// Returns nil if no valid sessionKey is found (rather than throwing), so callers
    /// can fall through to a manual-cookie path without interrupting the main flow.
    ///
    /// - Parameter allowAuto: When false, skips browser detection entirely and returns nil.
    static func sessionKeyInfo(allowAuto: Bool) throws -> SessionKeyInfo? {
        guard allowAuto else { return nil }

        // Check cooldown — skip browser reads while in the suppression window.
        if let suppressedUntil = cooldownDate(), Date() < suppressedUntil {
            return nil
        }

        // Shared with ProviderCookieReader — SweetCookieKit is not safe to drive
        // concurrently, and QuotaService fans provider fetches out in parallel.
        BrowserCookieSerialGate.lock.lock()
        defer { BrowserCookieSerialGate.lock.unlock() }
        return try extractFromBrowsers()
    }

    /// Parse a user-pasted Cookie header string for a sessionKey.
    ///
    /// - Parameter cookieHeader: Raw `Cookie:` header value (e.g. `"sessionKey=sk-ant-..."`).
    /// - Returns: SessionKeyInfo if a valid `sessionKey` beginning with `sk-ant-` is found.
    static func sessionKeyInfo(cookieHeader: String) -> SessionKeyInfo? {
        let pairs = parseCookieHeader(cookieHeader)
        guard let key = findSessionKey(in: pairs) else { return nil }
        // Rebuild a minimal cookie header containing only the sessionKey.
        return SessionKeyInfo(key: key, cookieHeader: "sessionKey=\(key)")
    }

    // MARK: - Private helpers

    private static func extractFromBrowsers() throws -> SessionKeyInfo? {
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: ["claude.ai"])

        // Safari first — no Keychain prompt needed on macOS.
        if let info = tryBrowser(.safari, client: client, query: query) {
            return info
        }

        // Remaining browsers in default order (skipping safari — already tried).
        let remaining = Browser.defaultImportOrder.filter { $0 != .safari }
        for browser in remaining {
            if let info = tryBrowser(browser, client: client, query: query) {
                return info
            }
        }

        return nil
    }

    private static func tryBrowser(
        _ browser: Browser,
        client: BrowserCookieClient,
        query: BrowserCookieQuery) -> SessionKeyInfo?
    {
        do {
            let storeRecords = try client.records(matching: query, in: browser)
            for storeRecord in storeRecords {
                // Snapshot name+value into freshly-allocated Strings *immediately*,
                // before any further SweetCookieKit access. SweetCookieKit's records
                // buffer can be freed/corrupted underneath us (use-after-free in its
                // Chromium cookie decryption → "memory corruption of free block" crash
                // inside String append). Round-tripping through UTF8 bytes detaches
                // every String from that storage so nothing afterwards touches it.
                let pairs: [(name: String, value: String)] = storeRecord.records.map { rec in
                    (name: String(decoding: Array(rec.name.utf8), as: UTF8.self),
                     value: String(decoding: Array(rec.value.utf8), as: UTF8.self))
                }
                if let key = findSessionKey(in: pairs) {
                    // Build a cookie header from all cookies in this store
                    // (some endpoints validate additional cookies alongside sessionKey).
                    let header = buildCookieHeader(from: pairs)
                    return SessionKeyInfo(key: key, cookieHeader: header)
                }
            }
        } catch let error as BrowserCookieError {
            // Record access-denied errors for the cooldown gate.
            recordCooldownIfNeeded(error)
        } catch {
            // notFound / loadFailed — browser not installed or store unreadable, skip silently.
        }
        return nil
    }

    private static func findSessionKey(in cookies: [(name: String, value: String)]) -> String? {
        for cookie in cookies where cookie.name == "sessionKey" {
            let trimmed = cookie.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("sk-ant-") { return trimmed }
        }
        return nil
    }

    private static func buildCookieHeader(from records: [(name: String, value: String)]) -> String {
        records
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    // MARK: - Cookie header parsing (manual path)

    private static func parseCookieHeader(_ header: String) -> [(name: String, value: String)] {
        header.split(separator: ";").compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let eqRange = trimmed.range(of: "=") else { return nil }
            let name = String(trimmed[..<eqRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[eqRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return (name, value)
        }
    }

    // MARK: - 6-hour cooldown gate

    private static func cooldownDate() -> Date? {
        guard let ts = UserDefaults.standard.object(forKey: deniedUntilKey) as? Date else {
            return nil
        }
        return ts
    }

    private static func recordCooldownIfNeeded(_ error: BrowserCookieError) {
        // Only suppress on access-denied (Keychain refusal). Short 5-min cooldown
        // so a user-initiated Refresh / "Always Allow" gets a fresh attempt fast.
        if case .accessDenied = error {
            let suppressUntil = Date().addingTimeInterval(5 * 60)
            UserDefaults.standard.set(suppressUntil, forKey: deniedUntilKey)
        }
    }
}
