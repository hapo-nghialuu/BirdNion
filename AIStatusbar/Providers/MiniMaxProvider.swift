import Foundation

/// MiniMax Token Plan quota provider.
///
/// Endpoint: `GET https://api.minimax.io/v1/token_plan/remains`
/// Auth: `Authorization: Bearer <key>` (verified 2026-06-23 against the live
///   endpoint; raw token without `Bearer ` returns `status_code: 1004`).
///
/// Response envelope (verified live):
/// ```json
/// {
///   "base_resp": { "status_code": 0, "status_msg": "success" },
///   "model_remains": [
///     {
///       "model_name": "general",
///       "current_interval_remaining_percent": 69,
///       "current_weekly_remaining_percent": 96,
///       ...
///     },
///     {
///       "model_name": "video",
///       "current_interval_remaining_percent": 100,
///       "current_weekly_remaining_percent": 100,
///       ...
///     }
///   ]
/// }
/// ```
///
/// Multi-model handling: each model becomes its own pair of windows
/// (interval + weekly). This makes the breakdown visible per-model
/// instead of collapsing everything into one "min across models" number.
final class MiniMaxProvider: QuotaProvider {
    static let endpoint = URL(string: "https://api.minimax.io/v1/token_plan/remains")!

    let id = "minimax"
    let displayName = "MiniMax"
    private let session: URLSession
    private let keychain: KeychainService

    init(session: URLSession = .shared, keychain: KeychainService) {
        self.session = session
        self.keychain = keychain
    }

    func fetch() async throws -> ProviderStatus {
        let token: String
        do {
            token = try keychain.read(account: "minimax")
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
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "Network: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "Response không phải HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "HTTP \(http.statusCode)")
        }
        return parse(data)
    }

    func parse(_ data: Data) -> ProviderStatus {
        let decoder = JSONDecoder()
        guard let root = try? decoder.decode(RemainsResponse.self, from: data) else {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "Response thiếu trường")
        }
        // MiniMax returns HTTP 200 even for auth/permission failures; the
        // real status lives in `base_resp.status_code`. 0 == success.
        if root.base_resp.status_code != 0 {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: root.base_resp.status_msg)
        }
        guard !root.model_remains.isEmpty else {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "Không có model nào trong response")
        }
        // 1 model → compact labels ("5 giờ" / "Tuần")
        // ≥2 models → disambiguate with model name prefix ("general 5h" / etc.)
        let multiple = root.model_remains.count > 1
        var windows: [QuotaWindow] = []
        for m in root.model_remains {
            let prefix = multiple ? "\(m.model_name) " : ""
            windows.append(QuotaWindow(label: "\(prefix)5 giờ",
                                       usedPct: 100 - m.current_interval_remaining_percent,
                                       remainingPct: m.current_interval_remaining_percent))
            windows.append(QuotaWindow(label: "\(prefix)Tuần",
                                       usedPct: 100 - m.current_weekly_remaining_percent,
                                       remainingPct: m.current_weekly_remaining_percent))
        }
        return ProviderStatus(id: id, displayName: displayName,
                              windows: windows,
                              lastUpdated: Date(),
                              error: nil)
    }

    private struct RemainsResponse: Decodable {
        let base_resp: BaseResp
        let model_remains: [ModelRemain]
    }
    private struct BaseResp: Decodable {
        let status_code: Int
        let status_msg: String
    }
    private struct ModelRemain: Decodable {
        let model_name: String
        let current_interval_total_count: Int
        let current_interval_usage_count: Int
        let current_interval_remaining_percent: Int
        let current_weekly_total_count: Int
        let current_weekly_usage_count: Int
        let current_weekly_remaining_percent: Int
    }
}