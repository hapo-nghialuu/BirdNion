import Foundation
import SQLite3

// MARK: - CursorProvider

/// Cursor usage provider — no CodexBarCore dependency.
///
/// Auth priority:
///   1. SQLite DB: ~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
///      table: ItemTable, key: "cursorAuth/accessToken"
///      The JWT access token is used to build a WorkosCursorSessionToken cookie header.
///   2. Browser cookies via ProviderCookieReader (cursor.com) as fallback.
///
/// Endpoints (host: https://cursor.com):
///   - GET /api/usage-summary  → plan + on-demand USD amounts, membership type, billing cycle
///   - GET /api/auth/me        → email, sub (user ID) — parallel fetch, best-effort
///
/// Usage-summary response values are in *cents*. Divide by 100.0 for USD.
final class CursorProvider: QuotaProvider {
    let id = "cursor"
    let displayName = "Cursor"

    private static let baseURL = URL(string: "https://cursor.com")!
    private static let dbPath: String = {
        "\(NSHomeDirectory())/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - QuotaProvider

    func fetch() async throws -> ProviderStatus {
        // Attempt SQLite auth first; fall back to browser cookies.
        var browserDenied = false
        let cookieHeader: String
        if let dbCookie = Self.cookieHeaderFromDB() {
            cookieHeader = dbCookie
        } else if let browserCookie = ProviderCookieReader.resolvedCookieHeader(
                      providerID: id, domain: "cursor.com",
                      permissionDenied: &browserDenied) {
            cookieHeader = browserCookie
        } else {
            return failure(browserDenied
                ? ProviderCookieReader.browserDataDeniedMessage
                : "Chưa đăng nhập Cursor (mở app Cursor hoặc đăng nhập cursor.com)")
        }
        return try await fetchStatus(cookieHeader: cookieHeader)
    }

    // MARK: - Internal fetch

    private func fetchStatus(cookieHeader: String) async throws -> ProviderStatus {
        // Fetch usage-summary and auth/me in parallel; /api/auth/me is best-effort.
        async let summaryResult = fetchUsageSummary(cookieHeader: cookieHeader)
        async let userResult = fetchUserInfo(cookieHeader: cookieHeader)

        let summary: CursorUsageSummary
        do {
            summary = try await summaryResult
        } catch let err as CursorFetchError {
            switch err {
            case .notLoggedIn:
                return failure("Chưa đăng nhập Cursor (mở app Cursor hoặc đăng nhập cursor.com)")
            case .network(let msg):
                return failure("Lỗi mạng Cursor: \(msg)")
            case .parse(let msg):
                return failure("Lỗi phân tích dữ liệu Cursor: \(msg)")
            }
        }

        let userInfo = try? await userResult

        // Fetch request-based usage best-effort: requires sub from auth/me.
        let requestUsage: CursorUsageResponse? = await {
            guard let sub = userInfo?.sub, !sub.isEmpty else { return nil }
            return try? await fetchRequestUsage(userID: sub, cookieHeader: cookieHeader)
        }()

        return Self._parseForTesting(usageJSON: summary, userInfo: userInfo, requestUsage: requestUsage, providerID: id, displayName: displayName)
    }

    // MARK: - API fetchers

    private func fetchUsageSummary(cookieHeader: String) async throws -> CursorUsageSummary {
        let url = Self.baseURL.appendingPathComponent("api/usage-summary")
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw CursorFetchError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CursorFetchError.network("Response không phải HTTP")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw CursorFetchError.notLoggedIn
        }
        guard http.statusCode == 200 else {
            throw CursorFetchError.network("HTTP \(http.statusCode)")
        }

        do {
            return try JSONDecoder().decode(CursorUsageSummary.self, from: data)
        } catch {
            let preview = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? "<binary>"
            throw CursorFetchError.parse("JSON decode thất bại: \(error.localizedDescription). Preview: \(preview)")
        }
    }

    private func fetchRequestUsage(userID: String, cookieHeader: String) async throws -> CursorUsageResponse {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("api/usage"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user", value: userID)]
        guard let url = components.url else { throw CursorFetchError.network("URL không hợp lệ") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CursorFetchError.network("/api/usage thất bại")
        }
        return try JSONDecoder().decode(CursorUsageResponse.self, from: data)
    }

    private func fetchUserInfo(cookieHeader: String) async throws -> CursorUserInfo {
        let url = Self.baseURL.appendingPathComponent("api/auth/me")
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CursorFetchError.network("auth/me thất bại")
        }
        return try JSONDecoder().decode(CursorUserInfo.self, from: data)
    }

    // MARK: - Parse (testable, no network/SQLite)

    /// Parse a pre-decoded CursorUsageSummary into ProviderStatus.
    /// Exposed as `static func _parseForTesting` so unit tests can inject JSON
    /// without touching SQLite or URLSession.
    ///
    /// Usage in tests:
    /// ```swift
    /// let status = CursorProvider._parseForTesting(usageJSON: summary, userInfo: nil,
    ///                                               providerID: "cursor", displayName: "Cursor")
    /// ```
    static func _parseForTesting(
        usageJSON summary: CursorUsageSummary,
        userInfo: CursorUserInfo?,
        requestUsage: CursorUsageResponse? = nil,
        providerID: String,
        displayName: String
    ) -> ProviderStatus {
        // Parse billing cycle dates (ISO-8601 with optional fractional seconds).
        func parseDate(_ s: String?) -> Date? {
            guard let s else { return nil }
            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f1.date(from: s) { return d }
            return ISO8601DateFormatter().date(from: s)
        }
        let cycleStart = parseDate(summary.billingCycleStart)
        let cycleEnd   = parseDate(summary.billingCycleEnd)
        let windowSecs: Int? = {
            guard let s = cycleStart, let e = cycleEnd else { return nil }
            let secs = Int(e.timeIntervalSince(s).rounded())
            return secs > 0 ? secs : nil
        }()

        // --- Plan (included budget) ---
        // Cents → USD. plan.limit is the included budget (not breakdown.total).
        let planUsedCents  = Double(summary.individualUsage?.plan?.used  ?? 0)
        let planLimitCents = Double(summary.individualUsage?.plan?.limit ?? 0)

        // Enterprise/Team personal cap fallback (individualUsage.overall).
        let overallUsedCents  = summary.individualUsage?.overall?.used.map(Double.init)
        let overallLimitCents = summary.individualUsage?.overall?.limit.map(Double.init)

        // Shared pool fallback (teamUsage.pooled).
        let pooledUsedCents  = summary.teamUsage?.pooled?.used.map(Double.init)
        let pooledLimitCents = summary.teamUsage?.pooled?.limit.map(Double.init)

        let planUsedUSD: Double
        let planLimitUSD: Double
        if planLimitCents > 0 || planUsedCents > 0 {
            planUsedUSD  = planUsedCents  / 100.0
            planLimitUSD = planLimitCents / 100.0
        } else if let u = overallUsedCents, let l = overallLimitCents {
            planUsedUSD  = u / 100.0
            planLimitUSD = l / 100.0
        } else if let u = pooledUsedCents, let l = pooledLimitCents {
            planUsedUSD  = u / 100.0
            planLimitUSD = l / 100.0
        } else {
            planUsedUSD  = 0
            planLimitUSD = 0
        }

        // Plan percentage (already in % units from the API, not 0–1).
        func clamp(_ v: Double) -> Double { max(0, min(100, v)) }
        let autoPercent = summary.individualUsage?.plan?.autoPercentUsed.map(clamp)
        let apiPercent  = summary.individualUsage?.plan?.apiPercentUsed.map(clamp)

        let planPct: Int = {
            if let total = summary.individualUsage?.plan?.totalPercentUsed {
                return Int(clamp(total).rounded())
            }
            if let a = autoPercent, let b = apiPercent { return Int(clamp((a + b) / 2).rounded()) }
            if let a = autoPercent { return Int(a.rounded()) }
            if let b = apiPercent  { return Int(b.rounded()) }
            if planLimitUSD > 0    { return Int(clamp(planUsedUSD / planLimitUSD * 100).rounded()) }
            if let u = overallUsedCents, let l = overallLimitCents, l > 0 {
                return Int(clamp(u / l * 100).rounded())
            }
            if let u = pooledUsedCents, let l = pooledLimitCents, l > 0 {
                return Int(clamp(u / l * 100).rounded())
            }
            return 0
        }()

        let planSubtitle = planLimitUSD > 0
            ? "\(UsageFormatter.usdString(planUsedUSD)) / \(UsageFormatter.usdString(planLimitUSD))"
            : UsageFormatter.usdString(planUsedUSD)

        // Primary window label: "Total" when breakdown lanes are present, otherwise "Plan".
        let primaryLabel = (autoPercent != nil || apiPercent != nil) ? "Total" : "Plan"
        let planWindow = QuotaWindow(
            label: primaryLabel,
            usedPct: planPct,
            remainingPct: max(0, 100 - planPct),
            subtitle: planSubtitle,
            resetDate: cycleEnd,
            windowSeconds: windowSecs)

        // --- On-demand ---
        // Prefer personal cap; fall back to team shared pool.
        let onDemandUsedCents  = Double(summary.individualUsage?.onDemand?.used  ?? 0)
        let onDemandLimitCents = summary.individualUsage?.onDemand?.limit.map(Double.init)
        let teamODUsedCents    = summary.teamUsage?.onDemand?.used.map(Double.init)
        let teamODLimitCents   = summary.teamUsage?.onDemand?.limit.map(Double.init)

        let resolvedODUsed: Double
        let resolvedODLimit: Double?
        if (onDemandLimitCents ?? 0) > 0 {
            resolvedODUsed  = onDemandUsedCents / 100.0
            resolvedODLimit = onDemandLimitCents.map { $0 / 100.0 }
        } else if (teamODLimitCents ?? 0) > 0 {
            resolvedODUsed  = (teamODUsedCents ?? 0) / 100.0
            resolvedODLimit = teamODLimitCents.map { $0 / 100.0 }
        } else {
            resolvedODUsed  = onDemandUsedCents / 100.0
            resolvedODLimit = onDemandLimitCents.map { $0 / 100.0 }
        }

        // --- Auto lane window (secondary) ---
        // Only added when autoPercentUsed is present in the response.
        var windows: [QuotaWindow] = [planWindow]
        if let autoPct = autoPercent {
            let autoPctInt = Int(autoPct.rounded())
            let autoWindow = QuotaWindow(
                label: "Auto",
                usedPct: autoPctInt,
                remainingPct: max(0, 100 - autoPctInt),
                subtitle: nil,
                resetDate: cycleEnd,
                windowSeconds: windowSecs)
            windows.append(autoWindow)
        }

        // --- API lane window (tertiary) ---
        // Only added when apiPercentUsed is present in the response.
        if let apiPctVal = apiPercent {
            let apiPctInt = Int(apiPctVal.rounded())
            let apiWindow = QuotaWindow(
                label: "API",
                usedPct: apiPctInt,
                remainingPct: max(0, 100 - apiPctInt),
                subtitle: nil,
                resetDate: cycleEnd,
                windowSeconds: windowSecs)
            windows.append(apiWindow)
        }

        // Build on-demand window only when there is spend or a cap.
        if resolvedODUsed > 0 || (resolvedODLimit ?? 0) > 0 {
            let odPct: Int = {
                guard let lim = resolvedODLimit, lim > 0 else { return 0 }
                return Int(clamp(resolvedODUsed / lim * 100).rounded())
            }()
            let odSubtitle: String = {
                if let lim = resolvedODLimit {
                    return "\(UsageFormatter.usdString(resolvedODUsed)) / \(UsageFormatter.usdString(lim))"
                }
                return UsageFormatter.usdString(resolvedODUsed)
            }()
            let odWindow = QuotaWindow(
                label: "On-demand",
                usedPct: odPct,
                remainingPct: max(0, 100 - odPct),
                subtitle: odSubtitle,
                resetDate: cycleEnd,
                windowSeconds: windowSecs)
            windows.append(odWindow)
        }

        // --- Request-based plan window (legacy plans with a fixed request cap) ---
        // Only added when /api/usage returns a positive maxRequestUsage for gpt-4.
        if let model = requestUsage?.gpt4,
           let maxReq = model.maxRequestUsage, maxReq > 0 {
            let usedReq = model.numRequestsTotal ?? model.numRequests ?? 0
            let reqPct = Int(clamp(Double(usedReq) / Double(maxReq) * 100).rounded())
            let reqWindow = QuotaWindow(
                label: "Yêu cầu",
                usedPct: reqPct,
                remainingPct: max(0, 100 - reqPct),
                subtitle: "\(usedReq) / \(maxReq) requests",
                resetDate: cycleEnd,
                windowSeconds: windowSecs)
            windows.append(reqWindow)
        }

        // --- ProviderCostSnapshot (on-demand spend) ---
        let costSnapshot: ProviderCostSnapshot? = (resolvedODUsed > 0 || (resolvedODLimit ?? 0) > 0)
            ? ProviderCostSnapshot(
                used: resolvedODUsed,
                limit: resolvedODLimit ?? 0,
                currencyCode: "USD",
                period: "Billing cycle",
                resetsAt: cycleEnd,
                updatedAt: Date())
            : nil

        // --- Membership / plan name ---
        let membershipType = summary.membershipType
        let planName: String? = membershipType.map { formatMembership($0) }

        // --- Account label ---
        let accountLabel: String? = userInfo?.email

        return ProviderStatus(
            id: providerID,
            displayName: displayName,
            windows: windows,
            lastUpdated: Date(),
            error: nil,
            accountLabel: accountLabel,
            planName: planName,
            cost: costSnapshot)
    }

    // MARK: - Helpers

    private static func formatMembership(_ type: String) -> String {
        switch type.lowercased() {
        case "enterprise": return "Cursor Enterprise"
        case "pro":        return "Cursor Pro"
        case "hobby":      return "Cursor Hobby"
        case "team":       return "Cursor Team"
        default:           return "Cursor \(type.capitalized)"
        }
    }

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }

    // MARK: - SQLite auth

    /// Reads the Cursor access token from the app's VSCode state DB (readonly + immutable URI
    /// to avoid locking the running Cursor process).
    /// Returns a `WorkosCursorSessionToken=<userID>::<token>` cookie header string, or nil.
    static func cookieHeaderFromDB() -> String? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        guard let token = readTokenFromDB(path: dbPath), !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        // Decode JWT payload to extract the user sub ("user|<userID>").
        guard let userID = extractUserID(fromJWT: token) else { return nil }

        // URL-encode "::" as "%3A%3A" to match Cursor's web session format.
        return "WorkosCursorSessionToken=\(userID)%3A%3A\(token)"
    }

    /// Opens the SQLite DB read-only with the `immutable=1` URI flag so the WAL
    /// file is never written and we don't conflict with a running Cursor process.
    private static func readTokenFromDB(path: String) -> String? {
        // Use URI filename with immutable=1 to prevent WAL writes.
        let uri = "file:\(path)?immutable=1&mode=ro"
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        // Short busy timeout — Cursor is likely running, don't block the refresh cycle.
        sqlite3_busy_timeout(db, 200)

        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        let key = "cursorAuth/accessToken"
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT_CURSOR)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        // Value may be stored as TEXT or BLOB (UTF-8).
        switch sqlite3_column_type(stmt, 0) {
        case SQLITE_TEXT:
            guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: cStr)
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
            return String(data: data, encoding: .utf8)
        default:
            return nil
        }
    }

    /// Decodes the JWT payload (base64url) and extracts the user ID from `sub` claim.
    /// `sub` format: "auth0|<userID>" or "user|<userID>" — we want the part after `|`.
    private static func extractUserID(fromJWT jwt: String) -> String? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }

        // Base64url → base64 padding.
        var b64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)

        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub  = json["sub"] as? String,
              let userID = sub.split(separator: "|", omittingEmptySubsequences: true).last.map(String.init),
              !userID.isEmpty
        else { return nil }

        // Validate: only alphanumerics, dots, underscores, hyphens.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard userID.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return userID
    }
}

// Stable transient destructor constant — avoids the unsafeBitCast at call sites.
private let SQLITE_TRANSIENT_CURSOR = unsafeBitCast(-1 as Int, to: sqlite3_destructor_type.self)

// MARK: - API models

struct CursorUsageSummary: Decodable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let membershipType: String?
    let individualUsage: CursorIndividualUsage?
    let teamUsage: CursorTeamUsage?
}

struct CursorIndividualUsage: Decodable {
    let plan: CursorPlanUsage?
    let onDemand: CursorOnDemandUsage?
    /// Enterprise/Team personal cap (cents).
    let overall: CursorOverallUsage?
}

struct CursorPlanUsage: Decodable {
    /// Usage in cents.
    let used: Int?
    /// Limit in cents (included plan budget).
    let limit: Int?
    /// % of auto+composer usage (already in percentage units, e.g. 36.4 = 36.4%).
    let autoPercentUsed: Double?
    /// % of API (named model) usage.
    let apiPercentUsed: Double?
    /// Combined total %.
    let totalPercentUsed: Double?
}

struct CursorOnDemandUsage: Decodable {
    let used: Int?
    let limit: Int?
}

struct CursorOverallUsage: Decodable {
    let used: Int?
    let limit: Int?
}

struct CursorTeamUsage: Decodable {
    let onDemand: CursorOnDemandUsage?
    let pooled: CursorPooledUsage?
}

struct CursorPooledUsage: Decodable {
    let used: Int?
    let limit: Int?
}

/// Response from GET /api/usage?user=<sub> (legacy request-based plans).
struct CursorUsageResponse: Decodable {
    /// Key is literally "gpt-4" in the JSON.
    let gpt4: CursorModelUsage?

    enum CodingKeys: String, CodingKey {
        case gpt4 = "gpt-4"
    }
}

struct CursorModelUsage: Decodable {
    let numRequests: Int?
    let numRequestsTotal: Int?
    let numTokens: Int?
    let maxRequestUsage: Int?
    let maxTokenUsage: Int?
}

struct CursorUserInfo: Decodable {
    let email: String?
    let sub: String?

    enum CodingKeys: String, CodingKey {
        case email
        case sub
    }
}

// MARK: - Internal error

private enum CursorFetchError: Error {
    case notLoggedIn
    case network(String)
    case parse(String)
}
