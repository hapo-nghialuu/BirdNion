import Foundation

/// Fetches the available model ids from an Anthropic-compatible provider's
/// `GET {baseURL}/v1/models` endpoint. Used by the "Claude Code" Settings tab
/// to populate the Haiku / Sonnet / Opus pickers.
///
/// Auth: tries `x-api-key` first (the Anthropic API convention), then falls
/// back to `Authorization: Bearer` on a 401/403 — gateways that proxy the
/// Anthropic API sometimes accept only one of the two.
enum ClaudeCodeModelsFetcher {
    enum FetchError: Error, Equatable {
        case badBaseURL
        case network(String)
        case http(Int)
        case decode
        case empty

        var message: String {
            switch self {
            case .badBaseURL: return "Base URL không hợp lệ"
            case .network(let s): return "Lỗi mạng: \(s)"
            case .http(let code): return "HTTP \(code)"
            case .decode: return "Không đọc được danh sách model"
            case .empty: return "Không có model nào"
            }
        }
    }

    /// Anthropic API version header. Matches `ClaudeAdminAPIUsage`.
    static let anthropicVersion = "2023-06-01"

    /// Return the model ids advertised by `{baseURL}/v1/models`.
    /// - Parameters:
    ///   - baseURL: API root without trailing `/v1` (e.g. `https://api.example.com`).
    ///   - token: provider API key.
    static func fetchModels(baseURL: String,
                            token: String,
                            session: URLSession = .shared) async throws -> [String] {
        guard let url = modelsURL(baseURL: baseURL) else { throw FetchError.badBaseURL }

        // First attempt: x-api-key.
        var (data, http) = try await send(url: url, token: token, useBearer: false, session: session)
        // Some Anthropic-compatible gateways only accept Bearer auth.
        if http == 401 || http == 403 {
            (data, http) = try await send(url: url, token: token, useBearer: true, session: session)
        }
        guard (200..<300).contains(http) else { throw FetchError.http(http) }

        let ids = try parse(data)
        guard !ids.isEmpty else { throw FetchError.empty }
        return ids
    }

    /// Build `{baseURL}/v1/models`, tolerating a trailing slash or an already
    /// `/v1`-suffixed base URL.
    static func modelsURL(baseURL: String) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix("/v1") {
            return URL(string: trimmed + "/models")
        }
        return URL(string: trimmed + "/v1/models")
    }

    /// Parse `{ "data": [ { "id": "..." } ] }` (Anthropic/OpenAI shape) into ids,
    /// **most-recent-first** using each model's `created_at` (ISO string) or
    /// `created` (unix seconds). Models without a timestamp keep API order at
    /// the end.
    static func parse(_ data: Data) throws -> [String] {
        guard let root = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
            throw FetchError.decode
        }
        let dated = root.data.filter { !$0.id.isEmpty }
        return dated.enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.sortKey, rhs.element.sortKey) {
                case let (l?, r?): return l > r                 // newest first
                case (_?, nil): return true                     // dated before undated
                case (nil, _?): return false
                case (nil, nil): return lhs.offset < rhs.offset  // stable API order
                }
            }
            .map(\.element.id)
    }

    private static func send(url: URL,
                             token: String,
                             useBearer: Bool,
                             session: URLSession) async throws -> (Data, Int) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if useBearer {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            req.setValue(token, forHTTPHeaderField: "x-api-key")
        }
        req.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw FetchError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.network("Response không phải HTTP")
        }
        return (data, http.statusCode)
    }

    private struct ModelsResponse: Decodable {
        let data: [Model]
        struct Model: Decodable {
            let id: String
            let createdAt: String?   // Anthropic: ISO 8601
            let created: Int?        // OpenAI-style: unix seconds

            enum CodingKeys: String, CodingKey {
                case id
                case createdAt = "created_at"
                case created
            }

            /// Comparable recency key (unix seconds), or nil if undated.
            var sortKey: Double? {
                if let created { return Double(created) }
                if let createdAt { return Self.epoch(createdAt) }
                return nil
            }

            private static func epoch(_ iso: String) -> Double? {
                let withFraction = ISO8601DateFormatter()
                withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = withFraction.date(from: iso) { return d.timeIntervalSince1970 }
                let plain = ISO8601DateFormatter()
                plain.formatOptions = [.withInternetDateTime]
                return plain.date(from: iso)?.timeIntervalSince1970
            }
        }
    }
}
