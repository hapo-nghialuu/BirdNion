import Foundation
import CodexBarCore

/// Ollama Cloud quota provider (CodexBar parity).
///
/// Sources:
/// 1. **Web (preferred for quota bars):** browser/manual cookies → scrape
///    `https://ollama.com/settings` (Session + Weekly % via `OllamaUsageFetcher`)
/// 2. **API key:** `OLLAMA_API_KEY` / config token verifies Cloud API access
///    (model catalog); does not expose session/weekly limits by itself
///
/// Cookie source: UserDefaults `ollamaCookieSource` / `ollamaManualCookie`
/// (Auto / Manual / Off) via `ProviderCookieReader`.
final class OllamaProvider: QuotaProvider {
    let id = "ollama"
    let displayName = "Ollama"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch() async throws -> ProviderStatus {
        let override = BirdNionConfigStore.accountLabel(provider: id)
        var lastError: Error?

        // 1) Cookie / web settings scrape
        let cookieMode = UserDefaults.standard.string(forKey: "\(id)CookieSource") ?? "auto"
        if cookieMode != "off" {
            do {
                let manual = cookieMode == "manual"
                    ? UserDefaults.standard.string(forKey: "\(id)ManualCookie")?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil
                let overrideHeader: String? = {
                    if let manual, !manual.isEmpty { return manual }
                    return ProviderCookieReader.resolvedCookieHeader(
                        providerID: id,
                        domain: "ollama.com")
                }()

                let fetcher = OllamaUsageFetcher(browserDetection: BrowserDetection())
                let snap = try await fetcher.fetch(
                    cookieHeaderOverride: overrideHeader,
                    manualCookieMode: cookieMode == "manual")
                return Self.mapWeb(snap, accountLabel: override)
            } catch {
                lastError = error
            }
        }

        // 2) API key — prove auth + show model count (no quota %)
        if let token = Self.resolveToken(), !token.isEmpty {
            do {
                let api = try await OllamaAPIUsageFetcher.fetchUsage(apiKey: token)
                return Self.mapAPI(api, accountLabel: override ?? String(token.prefix(8)))
            } catch {
                lastError = error
            }
        }

        return failure(Self.friendly(lastError))
    }

    static func resolveToken(
        env: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        if let t = env["OLLAMA_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        return BirdNionConfigStore.apiKey(provider: "ollama")
    }

    // MARK: - Mapping

    static func mapWeb(_ snap: OllamaUsageSnapshot, accountLabel: String?) -> ProviderStatus {
        var windows: [QuotaWindow] = []
        if let pct = snap.sessionUsedPercent {
            let used = max(0, min(100, Int(pct.rounded())))
            windows.append(QuotaWindow(
                label: "Session",
                usedPct: used,
                remainingPct: 100 - used,
                resetDate: snap.sessionResetsAt,
                windowSeconds: (snap.sessionWindowMinutes ?? 5 * 60) * 60))
        }
        if let pct = snap.weeklyUsedPercent {
            let used = max(0, min(100, Int(pct.rounded())))
            windows.append(QuotaWindow(
                label: "Tuần",
                usedPct: used,
                remainingPct: 100 - used,
                resetDate: snap.weeklyResetsAt,
                windowSeconds: 7 * 24 * 3600))
        }
        if windows.isEmpty {
            return ProviderStatus(
                id: "ollama",
                displayName: "Ollama",
                windows: [],
                lastUpdated: snap.updatedAt,
                error: "Ollama: không parse được Session/Weekly usage",
                accountLabel: accountLabel ?? snap.accountEmail,
                planName: snap.planName)
        }
        return ProviderStatus(
            id: "ollama",
            displayName: "Ollama",
            windows: windows,
            lastUpdated: snap.updatedAt,
            error: nil,
            accountLabel: accountLabel ?? snap.accountEmail,
            planName: snap.planName,
            sourceLabel: "web")
    }

    static func mapAPI(_ snap: OllamaAPIUsageSnapshot, accountLabel: String?) -> ProviderStatus {
        // API key path only verifies access + catalog size (no hard quota).
        let window = QuotaWindow(
            label: "Cloud API",
            usedPct: 0,
            remainingPct: 100,
            subtitle: "\(snap.modelCount) models · key OK")
        return ProviderStatus(
            id: "ollama",
            displayName: "Ollama",
            windows: [window],
            lastUpdated: snap.updatedAt,
            error: nil,
            accountLabel: accountLabel,
            planName: "API key",
            sourceLabel: "api")
    }

    /// Unit-test hook: parse settings HTML without network.
    static func _parseHTMLForTesting(_ html: String, now: Date = Date()) throws -> ProviderStatus {
        // OllamaUsageParser is internal — re-fetch path uses public fetcher only.
        // For tests we construct snapshot via a minimal public path if available.
        // Fall back to calling parse through a thin local regex for Session/Weekly.
        let snap = try parseHTMLLocally(html, now: now)
        return mapWeb(snap, accountLabel: nil)
    }

    /// Minimal local HTML parse for tests (mirrors CodexBar labels).
    static func parseHTMLLocally(_ html: String, now: Date = Date()) throws -> OllamaUsageSnapshot {
        func percent(after label: String) -> Double? {
            guard let r = html.range(of: label) else { return nil }
            let tail = String(html[r.upperBound...].prefix(2000))
            let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                return nil
            }
            let range = NSRange(tail.startIndex..<tail.endIndex, in: tail)
            guard let m = re.firstMatch(in: tail, range: range), m.numberOfRanges > 1,
                  let cap = Range(m.range(at: 1), in: tail)
            else { return nil }
            return Double(tail[cap])
        }
        let session = percent(after: "Session usage") ?? percent(after: "Hourly usage")
        let weekly = percent(after: "Weekly usage")
        guard session != nil || weekly != nil else {
            throw OllamaUsageError.parseFailed("Missing Ollama usage data.")
        }
        return OllamaUsageSnapshot(
            planName: nil,
            accountEmail: nil,
            sessionUsedPercent: session,
            weeklyUsedPercent: weekly,
            sessionResetsAt: nil,
            weeklyResetsAt: nil,
            sessionWindowMinutes: 5 * 60,
            updatedAt: now)
    }

    private static func friendly(_ error: Error?) -> String {
        if let e = error as? OllamaUsageError { return e.localizedDescription }
        if let e = error { return e.localizedDescription }
        return "Chưa đăng nhập Ollama. Login ollama.com (Chrome) hoặc dán API key / cookie."
    }

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }
}
