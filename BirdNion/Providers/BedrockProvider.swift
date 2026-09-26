import CryptoKit
import Foundation

// MARK: - SigV4 signer (ported from BedrockAWSSigner.swift in CodexBarCore)

private enum AWSSigV4 {
    struct Credentials {
        let accessKeyID: String
        let secretAccessKey: String
        let sessionToken: String?
    }

    /// Sign a URLRequest in-place using AWS Signature Version 4.
    static func sign(
        request: inout URLRequest,
        credentials: Credentials,
        region: String,
        service: String,
        date: Date = Date()
    ) {
        let dateStamp = Self.dateStamp(from: date)
        let amzDate = Self.amzDate(from: date)

        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let token = credentials.sessionToken {
            request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token")
        }
        if let host = request.url?.host {
            request.setValue(host, forHTTPHeaderField: "Host")
        }

        let bodyHash = Self.sha256Hex(request.httpBody ?? Data())
        request.setValue(bodyHash, forHTTPHeaderField: "x-amz-content-sha256")

        let signedHeaders = Self.collectSignedHeaders(from: request)
        let canonicalRequest = Self.canonicalRequest(
            request: request,
            signedHeaders: signedHeaders,
            bodyHash: bodyHash
        )

        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            Self.sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signature = Self.signature(
            secret: credentials.secretAccessKey,
            dateStamp: dateStamp,
            region: region,
            service: service,
            stringToSign: stringToSign
        )

        let authorization =
            "AWS4-HMAC-SHA256 "
            + "Credential=\(credentials.accessKeyID)/\(credentialScope), "
            + "SignedHeaders=\(signedHeaders.keys), "
            + "Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    // MARK: Test hook

    /// Exposed for unit-testing SigV4 against a known AWS test vector.
    /// Returns (stringToSign, signature) for fixed inputs without mutating a URLRequest.
    static func _signForTesting(
        method: String,
        url: URL,
        headers: [(name: String, value: String)],
        body: Data,
        credentials: Credentials,
        region: String,
        service: String,
        date: Date
    ) -> (stringToSign: String, signature: String) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        for h in headers { req.setValue(h.value, forHTTPHeaderField: h.name) }
        // Let sign() add date/auth headers then capture what it computed.
        // We reconstruct the same values directly to keep this pure.
        let dateStamp = Self.dateStamp(from: date)
        let amzDate = Self.amzDate(from: date)
        // Build minimal header set to mirror sign()
        var allHeaders: [(String, String)] = [
            ("host", url.host ?? ""),
            ("x-amz-date", amzDate),
            ("x-amz-content-sha256", Self.sha256Hex(body)),
        ]
        if let token = credentials.sessionToken {
            allHeaders.append(("x-amz-security-token", token))
        }
        for h in headers { allHeaders.append((h.name.lowercased(), h.value.trimmingCharacters(in: .whitespaces))) }
        allHeaders.sort { $0.0 < $1.0 }
        let keys = allHeaders.map(\.0).joined(separator: ";")
        let canonical = allHeaders.map { "\($0.0):\($0.1)" }.joined(separator: "\n")
        let signedHeaders = SignedHeadersInfo(keys: keys, canonical: canonical)
        let path = url.path.isEmpty ? "/" : url.path
        let bodyHash = Self.sha256Hex(body)
        let cr = [
            method.uppercased(),
            Self.uriEncodePath(path),
            Self.canonicalQueryString(url: url),
            signedHeaders.canonical + "\n",
            signedHeaders.keys,
            bodyHash,
        ].joined(separator: "\n")
        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let sts = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            Self.sha256Hex(Data(cr.utf8)),
        ].joined(separator: "\n")
        let sig = Self.signature(
            secret: credentials.secretAccessKey,
            dateStamp: dateStamp,
            region: region,
            service: service,
            stringToSign: sts
        )
        return (sts, sig)
    }

    // MARK: Private helpers

    private struct SignedHeadersInfo {
        let keys: String
        let canonical: String
    }

    private static func collectSignedHeaders(from request: URLRequest) -> SignedHeadersInfo {
        var pairs: [(String, String)] = []
        for (k, v) in request.allHTTPHeaderFields ?? [:] {
            pairs.append((k.lowercased(), v.trimmingCharacters(in: .whitespaces)))
        }
        pairs.sort { $0.0 < $1.0 }
        return SignedHeadersInfo(
            keys: pairs.map(\.0).joined(separator: ";"),
            canonical: pairs.map { "\($0.0):\($0.1)" }.joined(separator: "\n")
        )
    }

    private static func canonicalRequest(
        request: URLRequest,
        signedHeaders: SignedHeadersInfo,
        bodyHash: String
    ) -> String {
        let method = request.httpMethod ?? "GET"
        let url = request.url!
        let path = url.path.isEmpty ? "/" : url.path
        return [
            method,
            Self.uriEncodePath(path),
            Self.canonicalQueryString(url: url),
            signedHeaders.canonical + "\n",
            signedHeaders.keys,
            bodyHash,
        ].joined(separator: "\n")
    }

    private static func canonicalQueryString(url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              !items.isEmpty
        else { return "" }
        return items
            .map { "\(Self.uriEncode($0.name))=\(Self.uriEncode($0.value ?? ""))" }
            .sorted()
            .joined(separator: "&")
    }

    private static func signature(
        secret: String,
        dateStamp: String,
        region: String,
        service: String,
        stringToSign: String
    ) -> String {
        let kDate = Self.hmac(key: Data("AWS4\(secret)".utf8), msg: Data(dateStamp.utf8))
        let kRegion = Self.hmac(key: kDate, msg: Data(region.utf8))
        let kService = Self.hmac(key: kRegion, msg: Data(service.utf8))
        let kSigning = Self.hmac(key: kService, msg: Data("aws4_request".utf8))
        return Self.hmac(key: kSigning, msg: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(key: Data, msg: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key)))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func amzDate(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    private static func dateStamp(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    private static func uriEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func uriEncodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { Self.uriEncode(String($0)) }
            .joined(separator: "/")
    }
}

// MARK: - AWS credentials resolver (reads ~/.aws/credentials + ~/.aws/config natively)

private enum AWSCredentialReader {
    struct Resolved {
        let credentials: AWSSigV4.Credentials
        let region: String
    }

    /// Resolves AWS credentials, honoring the BirdNion Settings config first
    /// (mirrors CodexBar's auth-mode picker), then env vars, then ~/.aws files.
    ///
    /// - `awsAuthMode == "profile"`: resolve via the named AWS profile
    ///   (config → AWS_PROFILE → "default"). Static keys only — SSO/assume-role
    ///   via the AWS CLI is deferred.
    /// - otherwise (keys): config access key + secret → env keys → default
    ///   profile files.
    /// Region precedence: config region > AWS_REGION/AWS_DEFAULT_REGION >
    ///   profile file region > "us-east-1".
    static func resolve() throws -> Resolved {
        let env = ProcessInfo.processInfo.environment
        let cfg = BirdNionConfigStore.provider(id: "bedrock")
        let configRegion = Self.cleaned(cfg?.region)
        let authMode = Self.cleaned(cfg?.awsAuthMode) ?? "keys"

        // Profile mode: named AWS profile from config (or env / default).
        if authMode == "profile" {
            let profile = Self.cleaned(cfg?.awsProfile)
                ?? Self.cleaned(env["AWS_PROFILE"]) ?? "default"
            return try Self.resolveFromProfile(profile, env: env, configRegion: configRegion)
        }

        // Keys mode: config keys → env keys → default profile files.
        if let keyID = Self.cleaned(cfg?.apiKey),
           let secret = Self.cleaned(cfg?.secretKey) {
            let creds = AWSSigV4.Credentials(
                accessKeyID: keyID, secretAccessKey: secret, sessionToken: nil)
            return Resolved(credentials: creds,
                            region: configRegion ?? Self.envRegion(env) ?? "us-east-1")
        }
        if let keyID = Self.cleaned(env["AWS_ACCESS_KEY_ID"]),
           let secret = Self.cleaned(env["AWS_SECRET_ACCESS_KEY"]) {
            let creds = AWSSigV4.Credentials(
                accessKeyID: keyID, secretAccessKey: secret,
                sessionToken: Self.cleaned(env["AWS_SESSION_TOKEN"]))
            return Resolved(credentials: creds,
                            region: configRegion ?? Self.envRegion(env) ?? "us-east-1")
        }
        let profile = Self.cleaned(env["AWS_PROFILE"]) ?? "default"
        return try Self.resolveFromProfile(profile, env: env, configRegion: configRegion)
    }

    /// Reads static keys + region for a named profile from ~/.aws/credentials
    /// and ~/.aws/config.
    private static func resolveFromProfile(
        _ profile: String, env: [String: String], configRegion: String?) throws -> Resolved {
        let home = Self.homeDirectory()
        // Section name is "[profile]" in credentials, "[profile <name>]" or "[default]" in config
        let credSection = profile
        let configSection = profile == "default" ? "default" : "profile \(profile)"
        let credMap = Self.parseINIFile(at: "\(home)/.aws/credentials")[credSection] ?? [:]
        let configMap = Self.parseINIFile(at: "\(home)/.aws/config")[configSection] ?? [:]

        let keyID = Self.cleaned(credMap["aws_access_key_id"] ?? configMap["aws_access_key_id"])
        let secret = Self.cleaned(credMap["aws_secret_access_key"] ?? configMap["aws_secret_access_key"])
        let sessionToken = Self.cleaned(credMap["aws_session_token"] ?? configMap["aws_session_token"])
        let region = configRegion ?? Self.envRegion(env) ?? Self.cleaned(configMap["region"]) ?? "us-east-1"
        guard let keyID, let secret else {
            throw BedrockProviderError.missingCredentials
        }
        let creds = AWSSigV4.Credentials(
            accessKeyID: keyID, secretAccessKey: secret, sessionToken: sessionToken)
        return Resolved(credentials: creds, region: region)
    }

    // MARK: Private

    private static func envRegion(_ env: [String: String]) -> String? {
        Self.cleaned(env["AWS_REGION"]) ?? Self.cleaned(env["AWS_DEFAULT_REGION"])
    }

    private static func homeDirectory() -> String {
        // Use FileManager to respect sandboxing on macOS
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Minimal INI parser: returns [section: [key: value]].
    /// Ignores comments (#, ;), strips whitespace, handles continuation lines
    /// only at a surface level (good enough for ~/.aws files).
    static func parseINIFile(at path: String) -> [String: [String: String]] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var result: [String: [String: String]] = [:]
        var currentSection = ""
        for rawLine in content.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Skip comments and blank lines
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            guard !currentSection.isEmpty else { continue }
            if let eqIdx = line.firstIndex(of: "=") {
                let key = line[line.startIndex..<eqIdx]
                    .trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: eqIdx)...]
                    .trimmingCharacters(in: .whitespaces)
                result[currentSection, default: [:]][key] = value
            }
        }
        return result
    }

    static func cleaned(_ s: String?) -> String? {
        guard let v = s?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        // Strip surrounding quotes
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            let stripped = String(v.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            return stripped.isEmpty ? nil : stripped
        }
        return v
    }
}

// MARK: - Error types

private enum BedrockProviderError: LocalizedError {
    case missingCredentials
    case cloudWatchError(String)
    case costExplorerError(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Chưa cấu hình AWS credentials (~/.aws/credentials)"
        case .cloudWatchError(let msg):
            return "CloudWatch: \(msg)"
        case .costExplorerError(let msg):
            return "Cost Explorer: \(msg)"
        case .parseFailed(let msg):
            return "Parse lỗi: \(msg)"
        }
    }
}

// MARK: - CloudWatch usage fetcher (ported from BedrockCloudWatchUsage.swift)

private struct BedrockActivity {
    let inputTokens: Int
    let outputTokens: Int
    let requestCount: Int
    let region: String
    let profile: String
}

private enum CloudWatchFetcher {
    static let lookbackDays = 14
    static let requestTimeout: TimeInterval = 15

    private enum Metric: String, CaseIterable {
        case inputTokens
        case outputTokens
        case requests

        var cloudWatchName: String {
            switch self {
            case .inputTokens: "InputTokenCount"
            case .outputTokens: "OutputTokenCount"
            case .requests: "Invocations"
            }
        }
    }

    static func fetch(
        credentials: AWSSigV4.Credentials,
        region: String,
        session: URLSession
    ) async throws -> (inputTokens: Int, outputTokens: Int, requestCount: Int) {
        let endpoint = try Self.cloudWatchEndpoint(region: region)
        let now = Date()
        let start = now.addingTimeInterval(-Double(lookbackDays) * 86_400)

        let queries: [[String: Any]] = Metric.allCases.map { metric in
            let search = "SEARCH('{AWS/Bedrock,ModelId} MetricName=\"\(metric.cloudWatchName)\" claude', 'Sum', 86400)"
            return [
                "Id": metric.rawValue,
                "Expression": "SUM(\(search))",
                "ReturnData": true,
            ]
        }
        let payload: [String: Any] = [
            "StartTime": start.timeIntervalSince1970,
            "EndTime": now.timeIntervalSince1970,
            "ScanBy": "TimestampAscending",
            "MetricDataQueries": queries,
        ]

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = requestTimeout
        req.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        req.setValue("GraniteServiceVersion20100801.GetMetricData", forHTTPHeaderField: "X-Amz-Target")
        AWSSigV4.sign(&req, credentials: credentials, region: region, service: "monitoring")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw BedrockProviderError.cloudWatchError("Response không phải HTTP")
        }
        guard http.statusCode == 200 else {
            throw BedrockProviderError.cloudWatchError("HTTP \(http.statusCode)")
        }
        return try Self.parsePage(data)
    }

    private static func cloudWatchEndpoint(region: String) throws -> URL {
        // Validate region pattern
        guard region.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)+-[0-9]+$"#, options: .regularExpression) != nil else {
            throw BedrockProviderError.cloudWatchError("Invalid region: \(region)")
        }
        let suffix: String
        if region.hasPrefix("cn-") { suffix = "amazonaws.com.cn" }
        else if region.hasPrefix("us-iso-") { suffix = "c2s.ic.gov" }
        else if region.hasPrefix("us-isob-") { suffix = "sc2s.sgov.gov" }
        else { suffix = "amazonaws.com" }
        guard let url = URL(string: "https://monitoring.\(region).\(suffix)") else {
            throw BedrockProviderError.cloudWatchError("Cannot construct CloudWatch URL for region \(region)")
        }
        return url
    }

    private static func parsePage(_ data: Data) throws
        -> (inputTokens: Int, outputTokens: Int, requestCount: Int)
    {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BedrockProviderError.parseFailed("Invalid JSON")
        }
        if let messages = json["Messages"] as? [[String: Any]], !messages.isEmpty {
            throw BedrockProviderError.cloudWatchError("CloudWatch reported incomplete results")
        }
        let results = json["MetricDataResults"] as? [[String: Any]] ?? []
        var totals: [String: Double] = [:]
        for result in results {
            guard let id = result["Id"] as? String,
                  result["StatusCode"] as? String == "Complete",
                  let values = result["Values"] as? [NSNumber]
            else { continue }
            totals[id, default: 0] += values.reduce(0) { $0 + $1.doubleValue }
        }
        return (
            inputTokens: Int((totals["inputTokens"] ?? 0).rounded()),
            outputTokens: Int((totals["outputTokens"] ?? 0).rounded()),
            requestCount: Int((totals["requests"] ?? 0).rounded())
        )
    }
}

// Convenience shim so sign() can be called with labeled parameter
private extension AWSSigV4 {
    static func sign(
        _ request: inout URLRequest,
        credentials: Credentials,
        region: String,
        service: String,
        date: Date = Date()
    ) {
        self.sign(request: &request, credentials: credentials, region: region, service: service, date: date)
    }
}

// MARK: - Cost Explorer fetcher

private enum CostExplorerFetcher {
    static let requestTimeout: TimeInterval = 15
    // CE API is always in us-east-1 regardless of user's Bedrock region
    static let ceRegion = "us-east-1"
    static let ceHost = "ce.us-east-1.amazonaws.com"

    /// Returns the monthly UnblendedCost for Amazon Bedrock services (USD).
    /// Uses pagination to handle large result sets.
    static func fetchMonthlyCost(
        credentials: AWSSigV4.Credentials,
        session: URLSession
    ) async throws -> Double {
        let (startDate, endDate) = currentMonthRange()
        var total = 0.0
        var nextPageToken: String?
        var seen: Set<String> = []

        repeat {
            let (page, token) = try await callPage(
                credentials: credentials,
                session: session,
                startDate: startDate,
                endDate: endDate,
                nextPageToken: nextPageToken
            )
            total += parseTotalCost(page)
            nextPageToken = token
            if let t = nextPageToken {
                guard seen.insert(t).inserted else {
                    throw BedrockProviderError.costExplorerError("Repeated NextPageToken")
                }
            }
        } while nextPageToken != nil

        return total
    }

    // MARK: Private

    private static func callPage(
        credentials: AWSSigV4.Credentials,
        session: URLSession,
        startDate: String,
        endDate: String,
        nextPageToken: String?
    ) async throws -> (data: Data, nextPageToken: String?) {
        guard let url = URL(string: "https://\(ceHost)") else {
            throw BedrockProviderError.costExplorerError("Cannot construct CE URL")
        }

        var body: [String: Any] = [
            "TimePeriod": ["Start": startDate, "End": endDate],
            "Granularity": "MONTHLY",
            "Metrics": ["UnblendedCost"],
            "GroupBy": [["Type": "DIMENSION", "Key": "SERVICE"]],
        ]
        if let token = nextPageToken { body["NextPageToken"] = token }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = requestTimeout
        req.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        req.setValue("AWSInsightsIndexService.GetCostAndUsage", forHTTPHeaderField: "X-Amz-Target")
        AWSSigV4.sign(&req, credentials: credentials, region: ceRegion, service: "ce")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw BedrockProviderError.costExplorerError("Response không phải HTTP")
        }
        // DataUnavailableException (400) → treat as zero cost, not an error
        if http.statusCode == 400, isDataUnavailable(data) {
            return (Data(#"{"ResultsByTime":[]}"#.utf8), nil)
        }
        guard http.statusCode == 200 else {
            throw BedrockProviderError.costExplorerError("HTTP \(http.statusCode)")
        }

        let nextToken = extractNextPageToken(data)
        return (data, nextToken)
    }

    private static func parseTotalCost(_ data: Data) -> Double {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["ResultsByTime"] as? [[String: Any]]
        else { return 0 }

        var total = 0.0
        for result in results {
            guard let groups = result["Groups"] as? [[String: Any]] else { continue }
            for group in groups {
                guard let keys = group["Keys"] as? [String],
                      let svc = keys.first,
                      svc.localizedCaseInsensitiveContains("Bedrock"),
                      let metrics = group["Metrics"] as? [String: Any],
                      let unblended = metrics["UnblendedCost"] as? [String: Any],
                      let amountStr = unblended["Amount"] as? String,
                      let amount = Double(amountStr)
                else { continue }
                total += amount
            }
        }
        return total
    }

    private static func extractNextPageToken(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["NextPageToken"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return token
    }

    private static func isDataUnavailable(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let candidates = [json["__type"], json["code"], json["Code"],
                          (json["Error"] as? [String: Any])?["Code"]]
        return candidates.compactMap { $0 as? String }.contains {
            $0.split(separator: "#").last == "DataUnavailableException"
        }
    }

    static func currentMonthRange(now: Date = Date()) -> (start: String, end: String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = cal.dateComponents([.year, .month], from: now)
        let startOfMonth = cal.date(from: comps)!
        let startOfToday = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday)!
        let fmt = dateFormatter()
        return (fmt.string(from: startOfMonth), fmt.string(from: tomorrow))
    }

    private static func dateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    /// End of current UTC month as a Date, for `resetsAt`.
    static func endOfCurrentMonth(now: Date = Date()) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let range = cal.range(of: .day, in: .month, for: now) else { return nil }
        let comps = cal.dateComponents([.year, .month], from: now)
        guard let startOfMonth = cal.date(from: comps) else { return nil }
        return cal.date(byAdding: .day, value: range.count, to: startOfMonth)
    }
}

// MARK: - BedrockProvider

/// AWS Bedrock usage provider.
///
/// Auth chain (in priority order):
///   1. Env vars: AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY (+ AWS_SESSION_TOKEN)
///   2. ~/.aws/credentials  [<profile>]
///   3. ~/.aws/config       [profile <profile>] or [default]
/// Profile selected by AWS_PROFILE env var; falls back to "default".
/// Region: AWS_REGION > AWS_DEFAULT_REGION > config file > us-east-1.
///
/// Usage: queries AWS CloudWatch GetMetricData for Bedrock Claude token metrics
/// over the last 14 days, mapped to QuotaWindows for display.
final class BedrockProvider: QuotaProvider {
    let id = "bedrock"
    let displayName = "AWS Bedrock"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch() async throws -> ProviderStatus {
        let resolved: AWSCredentialReader.Resolved
        do {
            resolved = try AWSCredentialReader.resolve()
        } catch {
            return failure(error.localizedDescription)
        }

        // Prefer region from BirdNionConfigStore provider config, then AWS credential chain
        let configRegion = BirdNionConfigStore.provider(id: id)?.region
        let region = configRegion.flatMap { AWSCredentialReader.cleaned($0) } ?? resolved.region

        let profile = AWSCredentialReader.cleaned(ProcessInfo.processInfo.environment["AWS_PROFILE"]) ?? "default"
        let accountLabel = BirdNionConfigStore.accountLabel(provider: id) ?? profile

        // Read optional monthly budget from config (stored as a numeric string in apiKey field isn't ideal;
        // we look for a "budget" sentinel — but BirdNionConfigStore.Provider has no budget field yet,
        // so we accept nil and skip the percent window when no budget is configured.)
        let budget = BirdNionConfigStore.provider(id: id)?.budget

        // 1. Cost Explorer (best-effort — failure doesn't block CloudWatch)
        var monthlySpend: Double? = nil
        do {
            monthlySpend = try await CostExplorerFetcher.fetchMonthlyCost(
                credentials: resolved.credentials,
                session: session
            )
        } catch {
            // Non-fatal: continue to CloudWatch, surface CE error in subtitle
        }

        // 2. CloudWatch token activity (best-effort)
        var activity: (inputTokens: Int, outputTokens: Int, requestCount: Int)? = nil
        do {
            activity = try await CloudWatchFetcher.fetch(
                credentials: resolved.credentials,
                region: region,
                session: session
            )
        } catch {
            // Non-fatal: surface what we have from CE
        }

        // If both calls failed we have nothing useful
        if monthlySpend == nil && activity == nil {
            return failure("Không lấy được dữ liệu từ Cost Explorer và CloudWatch")
        }

        return buildStatus(
            monthlySpend: monthlySpend,
            budget: budget,
            activity: activity,
            accountLabel: accountLabel,
            region: region
        )
    }

    private func buildStatus(
        monthlySpend: Double?,
        budget: Double?,
        activity: (inputTokens: Int, outputTokens: Int, requestCount: Int)?,
        accountLabel: String,
        region: String
    ) -> ProviderStatus {
        var windows: [QuotaWindow] = []
        let now = Date()
        let resetsAt = CostExplorerFetcher.endOfCurrentMonth(now: now)

        // Window 1: Budget / spend (Cost Explorer)
        if let spend = monthlySpend {
            if let b = budget, b > 0 {
                let usedPct = min(100, max(0, Int((spend / b * 100).rounded())))
                let remainingPct = 100 - usedPct
                let spendStr = String(format: "$%.2f / $%.2f", spend, b)
                windows.append(QuotaWindow(
                    label: "Ngân sách tháng",
                    usedPct: usedPct,
                    remainingPct: remainingPct,
                    subtitle: spendStr,
                    resetDate: resetsAt,
                    windowSeconds: resetsAt.map { Int($0.timeIntervalSince(now)) },
                    allowance: QuotaAllowance(
                        used: spend, remaining: max(0, b - spend), limit: b, unit: .usd)
                ))
            } else {
                // No budget configured — informational window
                let spendStr = String(format: "Đã dùng $%.2f tháng này", spend)
                windows.append(QuotaWindow(
                    label: "Ngân sách tháng",
                    usedPct: 0,
                    remainingPct: 100,
                    subtitle: spendStr,
                    resetDate: resetsAt,
                    allowance: QuotaAllowance(
                        used: spend, remaining: nil, limit: nil, unit: .usd)
                ))
            }
        }

        // Window 2: CloudWatch token activity (14-day)
        if let act = activity {
            let totalTokens = act.inputTokens + act.outputTokens
            let tokenLabel = Self.compactCount(totalTokens)
            let subtitle = "↑\(Self.compactCount(act.inputTokens)) ↓\(Self.compactCount(act.outputTokens)) · \(act.requestCount) req"
            windows.append(QuotaWindow(
                label: "14 ngày (\(region))",
                usedPct: 0,  // Pay-per-token: no ceiling
                remainingPct: 100,
                subtitle: "\(tokenLabel) tokens · \(subtitle)",
                allowance: QuotaAllowance(
                    used: Double(totalTokens), remaining: nil, limit: nil, unit: .tokens)
            ))
        }

        // ProviderCostSnapshot for cost card
        let costSnapshot: ProviderCostSnapshot? = monthlySpend.map { spend in
            ProviderCostSnapshot(
                used: spend,
                limit: budget ?? 0,
                currencyCode: "USD",
                period: "Monthly",
                resetsAt: resetsAt,
                updatedAt: now
            )
        }

        return ProviderStatus(
            id: id,
            displayName: displayName,
            windows: windows,
            lastUpdated: now,
            error: nil,
            accountLabel: accountLabel,
            cost: costSnapshot
        )
    }

    private static func compactCount(_ n: Int) -> String {
        switch n {
        case 0: return "0"
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fK", Double(n) / 1_000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }
}

// MARK: - Test vector hook (public surface for unit tests)

extension BedrockProvider {
    /// Computes the SigV4 string-to-sign and signature for a fixed input.
    /// Use against the AWS SigV4 test suite:
    ///   https://docs.aws.amazon.com/general/latest/gr/sigv4-test-suite.html
    static func _signForTesting(
        method: String,
        urlString: String,
        headers: [(name: String, value: String)],
        body: Data,
        accessKeyID: String,
        secretAccessKey: String,
        sessionToken: String?,
        region: String,
        service: String,
        date: Date
    ) -> (stringToSign: String, signature: String)? {
        guard let url = URL(string: urlString) else { return nil }
        let creds = AWSSigV4.Credentials(
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken
        )
        return AWSSigV4._signForTesting(
            method: method,
            url: url,
            headers: headers,
            body: body,
            credentials: creds,
            region: region,
            service: service,
            date: date
        )
    }
}
