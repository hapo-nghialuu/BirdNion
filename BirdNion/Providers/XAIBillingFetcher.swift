import Foundation

public enum XAIBillingError: Error, Equatable, Sendable {
    case missingCredentials
    case invalidTeamID
    case invalidBaseURL
    case authenticationRejected
    case teamNotFound
    case rateLimited
    case apiError(Int)
    case parseError
}

public struct XAIDailyUsage: Equatable, Sendable {
    public let day: Date
    public let usd: Double
}

public struct XAIUsageSnapshot: Equatable, Sendable {
    public let balanceUSD: Double
    public let daily: [XAIDailyUsage]
    public let limitReached: Bool
}

public protocol XAITransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionXAITransport: XAITransport {
    private let session: URLSession

    public init() {
        let redirectDelegate = XAIHTTPSOnlyRedirectDelegate()
        self.session = URLSession(configuration: .ephemeral, delegate: redirectDelegate, delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

final class XAIHTTPSOnlyRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private static func originKey(_ url: URL?) -> String? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host?.lowercased() else {
            return nil
        }
        let port = url.port ?? 443
        return "\(scheme)://\(host):\(port)"
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let source = Self.originKey(task.originalRequest?.url),
              let destination = Self.originKey(request.url),
              source == destination else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

public struct XAIBillingFetcher: Sendable {
    private let apiKey: String
    public let teamID: String
    public let baseURL: URL
    private let transport: any XAITransport

    init(
        apiKey: String,
        teamID: String,
        baseURL: URL = URL(string: "https://management-api.x.ai/v1/billing/teams")!,
        transport: any XAITransport = URLSessionXAITransport()
    ) throws {
        let key = Self.normalize(apiKey)
        let team = Self.normalize(teamID)
        guard !key.isEmpty else { throw XAIBillingError.missingCredentials }
        guard Self.validTeamID(team) else { throw XAIBillingError.invalidTeamID }
        guard baseURL.scheme?.caseInsensitiveCompare("https") == .orderedSame, baseURL.host != nil else {
            throw XAIBillingError.invalidBaseURL
        }
        self.apiKey = key
        self.teamID = team
        self.baseURL = baseURL
        self.transport = transport
    }

    public func fetch(historyDays: Int = 30, now: Date = Date()) async throws -> XAIUsageSnapshot {
        try Task.checkCancellation()
        let balance = try await requestBalance()
        try Task.checkCancellation()

        do {
            let usage = try await requestUsage(historyDays: historyDays, now: now)
            try Task.checkCancellation()
            return XAIUsageSnapshot(balanceUSD: balance, daily: usage.daily, limitReached: usage.limitReached)
        } catch {
            guard Self.shouldPropagate(error) == false else { throw error }
            return XAIUsageSnapshot(balanceUSD: balance, daily: [], limitReached: false)
        }
    }

    func balanceRequest() -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(teamID).appendingPathComponent("prepaid/balance"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        addHeaders(&request, includeContentType: false)
        return request
    }

    func usageRequest(historyDays: Int = 30, now: Date = Date()) throws -> URLRequest {
        guard historyDays > 0 else { throw XAIBillingError.parseError }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let rangeStart = calendar.date(byAdding: .day, value: -(historyDays - 1), to: now) else {
            throw XAIBillingError.parseError
        }

        var request = URLRequest(url: baseURL.appendingPathComponent(teamID).appendingPathComponent("usage"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        addHeaders(&request, includeContentType: true)

        let start = calendar.startOfDay(for: rangeStart)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let body: [String: Any] = [
            "analyticsRequest": [
                "timeRange": [
                    "startTime": formatter.string(from: start),
                    "endTime": formatter.string(from: now),
                    "timezone": "Etc/GMT"
                ],
                "timeUnit": "TIME_UNIT_DAY",
                "values": [["name": "usd", "aggregation": "AGGREGATION_SUM"]],
                "groupBy": [],
                "filters": []
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func requestBalance() async throws -> Double {
        try Task.checkCancellation()
        let (data, response) = try await transport.send(balanceRequest())
        try Task.checkCancellation()
        try Self.check(response)

        struct Envelope: Decodable {
            struct Total: Decodable { let val: String }
            let total: Total
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw XAIBillingError.parseError
        }
        guard let value = Self.parseBalanceCents(envelope.total.val), value.isFinite else {
            throw XAIBillingError.parseError
        }
        return -value / 100
    }

    private func requestUsage(historyDays: Int, now: Date) async throws -> (daily: [XAIDailyUsage], limitReached: Bool) {
        try Task.checkCancellation()
        let (data, response) = try await transport.send(try usageRequest(historyDays: historyDays, now: now))
        try Task.checkCancellation()
        try Self.check(response)

        struct Point: Decodable {
            let timestamp: Date
            let values: [Double]
        }
        struct Series: Decodable { let dataPoints: [Point] }
        struct Envelope: Decodable {
            let timeSeries: [Series]
            let limitReached: Bool?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw XAIBillingError.parseError
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var sums: [Date: Double] = [:]
        for point in envelope.timeSeries.flatMap(\.dataPoints) {
            let value = point.values.first ?? 0
            guard value.isFinite else { throw XAIBillingError.parseError }
            let day = calendar.startOfDay(for: point.timestamp)
            let updated = (sums[day] ?? 0) + value
            guard updated.isFinite else { throw XAIBillingError.parseError }
            sums[day] = updated
        }
        return (
            sums.keys.sorted().map { XAIDailyUsage(day: $0, usd: sums[$0] ?? 0) },
            envelope.limitReached ?? false
        )
    }

    private func addHeaders(_ request: inout URLRequest, includeContentType: Bool) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if includeContentType {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
    }

    private static func normalize(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if (normalized.hasPrefix("\"") && normalized.hasSuffix("\"")) ||
            (normalized.hasPrefix("'") && normalized.hasSuffix("'")) {
            normalized = String(normalized.dropFirst().dropLast())
        }
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func validTeamID(_ value: String) -> Bool {
        let normalized = normalize(value)
        guard !normalized.isEmpty, normalized != ".", normalized != ".." else { return false }
        guard !normalized.contains("/"), !normalized.contains("\\") else { return false }
        return !normalized.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    private static func shouldPropagate(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        switch error as? XAIBillingError {
        case .authenticationRejected:
            return true
        default:
            return false
        }
    }

    private static func parseBalanceCents(_ value: String) -> Double? {
        guard value.range(of: #"^-?\d+(?:\.\d+)?$"#, options: .regularExpression) != nil else {
            return nil
        }
        return Double(value)
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw XAIBillingError.apiError(0) }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401, 403: throw XAIBillingError.authenticationRejected
            case 404: throw XAIBillingError.teamNotFound
            case 429: throw XAIBillingError.rateLimited
            default: throw XAIBillingError.apiError(http.statusCode)
            }
        }
    }
}
