import Foundation

/// OpenRouter credits provider.
///
/// Endpoint: `GET https://openrouter.ai/api/v1/credits`
/// Auth: `Authorization: Bearer <key>` (key prefix `sk-or-...`).
///
/// Response envelope:
/// ```json
/// { "data": { "total_credits": 10.0, "total_usage": 3.2 } }
/// ```
/// OpenRouter sells prepaid credits; `total_usage` accumulates against
/// `total_credits`. We surface a single window showing the % consumed plus a
/// dollar "remaining" figure. No reset (credits don't refill on a cadence).
final class OpenRouterProvider: QuotaProvider {
    let id = "openrouter"
    let displayName = "OpenRouter"

    static let endpoint = URL(string: "https://openrouter.ai/api/v1/credits")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func override() -> String? {
        BirdNionConfigStore.accountLabel(provider: id)
    }

    func fetch() async throws -> ProviderStatus {
        // Token resolution: single source of truth is
        // `~/.config/birdnion/settings.json` (via `BirdNionConfigStore`). The
        // 2026-06-25 storage refactor removed the Keychain / CodexBar
        // config file fallbacks.
        // Env override first (OPENROUTER_API_KEY), then config storage.
        let envToken = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (envToken?.isEmpty == false ? envToken : nil) ?? BirdNionConfigStore.apiKey(provider: id)
        guard let token, !token.isEmpty else {
            return failure("Chưa cấu hình token")
        }
        let accountLabel = override() ?? String(token.prefix(8))

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            return failure("Network: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { return failure("Response không phải HTTP") }
        guard (200..<300).contains(http.statusCode) else { return failure("HTTP \(http.statusCode)") }
        let base = parse(data, accountLabel: accountLabel)
        guard base.error == nil else { return base }
        // Non-fatal enrichment: add a per-key spending-limit window when the key
        // has a finite limit. Failures here never break the credits result.
        guard let keyWindow = await fetchKeyWindow(token: token) else { return base }
        return ProviderStatus(
            id: base.id,
            displayName: base.displayName,
            windows: base.windows + [keyWindow],
            lastUpdated: base.lastUpdated,
            error: nil,
            accountLabel: base.accountLabel,
            creditsRemaining: base.creditsRemaining)
    }

    /// Best-effort `GET /api/v1/key` → a "Hạn mức key" window when the API key
    /// carries a spending limit. Returns nil on any error or for unlimited keys.
    private func fetchKeyWindow(token: String) async -> QuotaWindow? {
        guard let url = URL(string: "https://openrouter.ai/api/v1/key") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://birdnion.app", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("BirdNion", forHTTPHeaderField: "X-Title")
        req.timeoutInterval = 1
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONDecoder().decode(KeyResponse.self, from: data),
              let limit = root.data.limit, limit > 0 else { return nil }
        let usage = root.data.usage ?? 0
        let usedPct = max(0, min(100, Int((usage / limit * 100).rounded())))
        let remaining = root.data.limitRemaining ?? max(0, limit - usage)
        return QuotaWindow(
            label: "Hạn mức key",
            usedPct: usedPct,
            remainingPct: 100 - usedPct,
            subtitle: String(format: "$%.2f / $%.2f", remaining, limit))
    }

    func parse(_ data: Data, accountLabel: String) -> ProviderStatus {
        guard let root = try? JSONDecoder().decode(CreditsResponse.self, from: data) else {
            return failure("Response thiếu trường")
        }
        let total = root.data.totalCredits
        let used = root.data.totalUsage
        let remaining = max(0, total - used)
        let usedPct = total > 0 ? max(0, min(100, Int((used / total * 100).rounded()))) : 0
        let window = QuotaWindow(
            label: "Tín dụng",
            usedPct: usedPct,
            remainingPct: 100 - usedPct,
            subtitle: String(format: "$%.2f / $%.2f", remaining, total))
        return ProviderStatus(
            id: id,
            displayName: displayName,
            windows: [window],
            lastUpdated: Date(),
            error: nil,
            accountLabel: accountLabel,
            creditsRemaining: remaining)
    }

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }

    private struct CreditsResponse: Decodable {
        let data: CreditsData
        struct CreditsData: Decodable {
            let totalCredits: Double
            let totalUsage: Double
            enum CodingKeys: String, CodingKey {
                case totalCredits = "total_credits"
                case totalUsage = "total_usage"
            }
        }
    }

    private struct KeyResponse: Decodable {
        let data: KeyData
        struct KeyData: Decodable {
            let usage: Double?
            let limit: Double?
            let limitRemaining: Double?
            enum CodingKeys: String, CodingKey {
                case usage, limit
                case limitRemaining = "limit_remaining"
            }
        }
    }
}
