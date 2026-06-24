import Foundation

/// "Manual reset" credits granted by OpenAI. Each one lets the user reset a
/// rate-limit window before its natural reset time. Mirrors CodexBar's
/// `CodexRateLimitResetCreditsSnapshot` + `CodexRateLimitResetCredit` +
/// `CodexRateLimitResetCreditStatus` (the latter trimmed to a plain string
/// so we don't have to thread the enum's `unknown` case through Codable).
struct CodexRateLimitResetCreditsSnapshot: Equatable {
    let credits: [Credit]
    let availableCount: Int
    let updatedAt: Date

    struct Credit: Equatable, Identifiable {
        let id: String
        let resetType: String
        let status: String   // "available" | "redeeming" | "redeemed" | "expired" | other
        let grantedAt: Date
        let expiresAt: Date?
        let title: String?
    }
}

enum CodexResetCreditsError: Error, Equatable {
    case unauthorized
    case invalidResponse
    case serverError(Int)
}

/// Fetches the user's manual-reset credits from
/// `https://chatgpt.com/backend-api/wham/rate-limit-reset-credits`. Mirrors
/// CodexBar's `CodexOAuthUsageFetcher.fetchRateLimitResetCredits` but uses
/// `URLSession` (no internal ProviderHTTPTransport). All fields are
/// optional so a partial payload still decodes.
enum CodexResetCreditsAPI {
    static let url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

    static func fetch(
        accessToken: String,
        accountId: String?,
        session: URLSession = .shared,
        now: Date = Date()) async throws -> CodexRateLimitResetCreditsSnapshot
    {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("AIStatusbar", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        req.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        if let accountId, !accountId.isEmpty {
            req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw CodexResetCreditsError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            return try Self.decode(data, now: now)
        case 401, 403:
            throw CodexResetCreditsError.unauthorized
        default:
            throw CodexResetCreditsError.serverError(http.statusCode)
        }
    }

    static func decode(_ data: Data, now: Date) throws -> CodexRateLimitResetCreditsSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
            return f1.date(from: s) ?? f2.date(from: s) ?? now
        }
        let payload = try decoder.decode(Payload.self, from: data)
        guard payload.availableCount >= 0 else { throw CodexResetCreditsError.invalidResponse }
        return CodexRateLimitResetCreditsSnapshot(
            credits: payload.credits.map { c in
                .init(id: c.id, resetType: c.resetType, status: c.status,
                      grantedAt: c.grantedAt, expiresAt: c.expiresAt, title: c.title)
            },
            availableCount: payload.availableCount,
            updatedAt: now)
    }

    private struct Payload: Decodable {
        let credits: [CreditWire]
        let availableCount: Int

        enum CodingKeys: String, CodingKey {
            case credits
            case availableCount = "available_count"
        }
    }

    private struct CreditWire: Decodable {
        let id: String
        let resetType: String
        let status: String
        let grantedAt: Date
        let expiresAt: Date?
        let title: String?

        enum CodingKeys: String, CodingKey {
            case id
            case resetType = "reset_type"
            case status
            case grantedAt = "granted_at"
            case expiresAt = "expires_at"
            case title
        }
    }
}
