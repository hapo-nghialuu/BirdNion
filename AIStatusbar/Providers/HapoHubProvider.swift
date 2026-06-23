import Foundation

/// Hapo Hub quota provider.
///
/// Real adapter (verified 2026-06-23):
/// `GET <baseURL>` with `Authorization: Bearer <token>`.
/// Response shape:
/// ```json
/// {
///   "usage_percentage":       19.07,
///   "remaining_budget_usd":   16.19,
///   "used_budget_usd":         3.81,
///   "weekly_budget_usd":      20,
///   "budget_week_ends_at":   "2026-06-29T00:00:00+07:00",
///   "budget_week_start_at":  "2026-06-22T00:00:00+07:00",
///   "timezone": "Asia/Hanoi"
/// }
/// ```
///
/// The window's `subtitle` carries "$16.19 / $20.00" and `resetDate`
/// is parsed from `budget_week_ends_at` so the UI can show
/// "Resets in 6d 1h" instead of a hardcoded "weekly" hint.
final class HapoHubProvider: QuotaProvider {
    var id: String { config.id }
    var displayName: String { config.displayName }

    private let config: HapoHubConfig
    private let session: URLSession
    private let keychain: KeychainService

    init(session: URLSession = .shared, config: HapoHubConfig, keychain: KeychainService) {
        self.session = session
        self.config = config
        self.keychain = keychain
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

    func fetch() async throws -> ProviderStatus {
        let token: String
        do {
            token = try keychain.read(account: config.id)
        } catch KeychainError.itemNotFound {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "Chưa cấu hình token")
        } catch let e as KeychainError {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "Keychain error: \(e)")
        } catch {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "\(error)")
        }

        if token.unicodeScalars.contains(where: { !Self.tokenCharacterSet.contains($0) }) {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "Token chứa ký tự không hợp lệ")
        }

        guard let url = URL(string: config.baseURL) else {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "baseURL không hợp lệ")
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
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "Network: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "Response không phải HTTP")
        }
        let ct = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if !(200..<300).contains(http.statusCode) {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "HTTP \(http.statusCode)")
        }
        if !ct.hasPrefix("application/json") {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "Endpoint trả về non-JSON (Content-Type: \(ct))")
        }
        return parse(data)
    }

    func parse(_ data: Data) -> ProviderStatus {
        let decoder = JSONDecoder()
        guard let r = try? decoder.decode(BudgetResponse.self, from: data) else {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "Response thiếu trường")
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

    private struct BudgetResponse: Decodable {
        let usage_percentage: Double
        let remaining_budget_usd: Double
        let used_budget_usd: Double
        let weekly_budget_usd: Double
        let budget_week_ends_at: String
        let budget_week_start_at: String
        let timezone: String
    }
}