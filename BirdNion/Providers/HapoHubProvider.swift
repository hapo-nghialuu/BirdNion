import Foundation

/// Hapo Hub quota provider.
///
/// Two HTTP calls per fetch:
///  - `GET /v1/me`         — returns { email, name, ... } for the account.
///                          Used to populate accountLabel so the UI can
///                          show "nghialt@haposoft.com" instead of a
///                          token-prefix hash.
///  - `GET /v1/budget/week` — returns weekly quota (percent + dollar).
///
/// Both are issued in parallel via `async let`. The budget response is
/// the source of truth for the quota panel; /v1/me is best-effort — if
/// it errors out, we fall back to user override then token-prefix.
final class HapoHubProvider: QuotaProvider {
    var id: String { config.id }
    var displayName: String { config.displayName }

    private let config: HapoHubConfig
    private let session: URLSession

    init(session: URLSession = .shared, config: HapoHubConfig) {
        self.session = session
        self.config = config
    }

    static let tokenCharacterSet: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "._-")
        return s
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Identity endpoint — resolved from `config.meURL` so the source
    /// doesn't hardcode any hostnames. Lazily built so a missing/invalid
    /// `HAPO_ME_URL` env doesn't crash the whole process at boot.
    private var meURL: URL? {
        URL(string: config.meURL)
    }

    /// User-set accountLabel override from the BirdNion config.
    private func override() -> String? {
        BirdNionConfigStore.accountLabel(provider: id)
    }

    /// Resolve accountLabel: real email from API > user override (if set
    /// and non-empty) > token-prefix fallback.
    static func deriveAccountLabel(override: String?, token: String, email: String? = nil) -> String {
        if let e = email, !e.isEmpty { return e }
        if let o = override, !o.isEmpty { return o }
        return String(token.prefix(8))
    }

    func fetch() async throws -> ProviderStatus {
        // 0. Endpoint sanity. The base URL is resolved at startup from
        // `HAPO_BASE_URL` env. If the host didn't set it, we fail loud
        // instead of silently contacting the wrong host.
        guard !config.baseURL.isEmpty else {
            return errorStatus("HAPO_BASE_URL chưa được set")
        }

        // 1. Token read + validation.
        //    Single source of truth: `~/.config/birdnion/settings.json` (via
        //    `BirdNionConfigStore`). No more Keychain fallback — the
        //    2026-06-25 storage refactor consolidated all secrets into
        //    the config file.
        let token = BirdNionConfigStore.apiKey(provider: config.id)
        guard let token, !token.isEmpty else {
            return errorStatus("Chưa cấu hình token")
        }

        if token.unicodeScalars.contains(where: { !Self.tokenCharacterSet.contains($0) }) {
            return errorStatus("Token chứa ký tự không hợp lệ")
        }

        // 2. Sequential calls — budget first (it's the data we render);
        //    /v1/me is best-effort identity enrichment fired only after
        //    budget succeeds. Sequential (rather than async let) keeps
        //    the email fetch from racing with the budget's URLSession
        //    call under macOS's default connection pool.
        let budgetStatus = await fetchBudget(token: token)
        var status = budgetStatus

        // 3. Account label: API email > user override > token prefix.
        //    /v1/me is fetched only when the budget call succeeded so we
        //    don't burn a second request on every failed keychain read.
        var resolvedEmail: String? = nil
        if status.error == nil {
            resolvedEmail = await fetchEmail(token: token)
        }
        let ovr = override()
        let label = Self.deriveAccountLabel(
            override: ovr,
            token: token,
            email: resolvedEmail
        )
        status = ProviderStatus(
            id: status.id,
            displayName: status.displayName,
            windows: status.windows,
            lastUpdated: status.lastUpdated,
            error: status.error,
            accountLabel: label
        )
        return status
    }

    // MARK: - Budget call

    private func fetchBudget(token: String) async -> ProviderStatus {
        guard let url = URL(string: config.baseURL) else {
            return errorStatus("baseURL không hợp lệ")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(config.authHeaderTemplate.replacingOccurrences(of: "{token}", with: token),
                     forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            return errorStatus("Network: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            return errorStatus("Response không phải HTTP")
        }
        let ct = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if !(200..<300).contains(http.statusCode) {
            return errorStatus("HTTP \(http.statusCode)")
        }
        if !ct.hasPrefix("application/json") {
            return errorStatus("Endpoint trả về non-JSON (Content-Type: \(ct))")
        }
        return parseBudget(data)
    }

    private func parseBudget(_ data: Data) -> ProviderStatus {
        let decoder = JSONDecoder()
        guard let r = try? decoder.decode(BudgetResponse.self, from: data) else {
            return errorStatus("Response thiếu trường")
        }
        let remainingPct = max(0, min(100, Int((100.0 - r.usage_percentage).rounded())))
        let usedPct = 100 - remainingPct
        let subtitle = String(format: "$%.2f / $%.2f",
                              r.remaining_budget_usd, r.weekly_budget_usd)
        let resetDate = Self.iso8601.date(from: r.budget_week_ends_at)
        let win = QuotaWindow(label: "Tuần",
                              usedPct: usedPct,
                              remainingPct: remainingPct,
                              subtitle: subtitle,
                              resetDate: resetDate)
        return ProviderStatus(id: id, displayName: displayName,
                              windows: [win],
                              lastUpdated: Date(),
                              error: nil)
    }

    // MARK: - Identity call (best-effort)

    private func fetchEmail(token: String) async -> String? {
        guard let url = meURL else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(config.authHeaderTemplate.replacingOccurrences(of: "{token}", with: token),
                     forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return (try? JSONDecoder().decode(MeResponse.self, from: data))?.email
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private func errorStatus(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [],
                       lastUpdated: Date(), error: message)
    }

    private struct BudgetResponse: Decodable {
        let usage_percentage: Double
        let remaining_budget_usd: Double
        let used_budget_usd: Double
        let weekly_budget_usd: Double
        let budget_week_ends_at: String
        let budget_week_start_at: String
        let timezone: String
    }

    private struct MeResponse: Decodable {
        let email: String?
        let name: String?
    }
}