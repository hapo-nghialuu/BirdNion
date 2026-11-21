import Foundation
import CodexBarCore

/// Devin CLI fallback source.
///
/// `devin auth login` stores a `windsurf_api_key` (prefix `devin-`) in
/// `$XDG_DATA_HOME/devin/credentials.toml` (default `~/.local/share/devin`).
/// That key is rejected by the web `billing/quota/usage` endpoint, but the CLI
/// itself reads its quota from the Connect RPC
/// `exa.seat_management_pb.SeatManagementService/GetUserStatus` on
/// `api_server_url`, whose `planStatus` carries daily/weekly remaining percent
/// and reset times. No usage history or ACU amounts are available here.
enum DevinCLIStatusFetcher {
    struct Credentials: Equatable {
        let apiKey: String
        let apiServerURL: URL
    }

    static let defaultAPIServerURL = URL(string: "https://server.codeium.com")!
    private static let rpcPath = "exa.seat_management_pb.SeatManagementService/GetUserStatus"
    /// Devin CLI release verified against GetUserStatus on 2026-11-21.
    private static let clientVersion = "3000.11.3"

    // MARK: - Credentials

    static func credentialsURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        env: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let xdg = env["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("devin/credentials.toml")
        }
        return home.appendingPathComponent(".local/share/devin/credentials.toml")
    }

    static func loadCredentials(from url: URL = credentialsURL()) -> Credentials? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseCredentials(text)
    }

    /// Minimal parser for the flat `key = "value"` lines the CLI writes;
    /// sections, arrays and multi-line strings are not used by this file.
    static func parseCredentials(_ text: String) -> Credentials? {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        guard let apiKey = values["windsurf_api_key"], !apiKey.isEmpty else { return nil }
        let server = values["api_server_url"].flatMap { URL(string: $0) }
            .flatMap { $0.scheme == "https" ? $0 : nil }
        return Credentials(apiKey: apiKey, apiServerURL: server ?? defaultAPIServerURL)
    }

    // MARK: - Fetch

    static func fetch(
        credentials: Credentials,
        transport: any ProviderHTTPTransport = URLSession.shared,
        now: Date = Date()) async throws -> DevinUsageSnapshot
    {
        var request = URLRequest(url: credentials.apiServerURL.appending(path: rpcPath))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        // The server answers HTTP 400 when the version fields are missing.
        let body: [String: Any] = [
            "metadata": [
                "apiKey": credentials.apiKey,
                "ideName": "devin-cli",
                "ideVersion": clientVersion,
                "extensionName": "devin-cli",
                "extensionVersion": clientVersion,
                "locale": "en",
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            // Connect maps an unauthenticated/denied key to 401/403.
            if response.statusCode == 401 || response.statusCode == 403 {
                throw DevinUsageError.invalidCredentials
            }
            throw DevinUsageError.apiError("HTTP \(response.statusCode)")
        }
        return try parseUserStatus(response.data, now: now)
    }

    // MARK: - Parsing

    static func parseUserStatus(_ data: Data, now: Date = Date()) throws -> DevinUsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userStatus = root["userStatus"] as? [String: Any],
              let planStatus = userStatus["planStatus"] as? [String: Any]
        else {
            throw DevinUsageError.parseFailed("GetUserStatus has no planStatus")
        }
        let planInfo = planStatus["planInfo"] as? [String: Any]
        let devinInfo = planInfo?["devinInfo"] as? [String: Any]

        let daily = window(planStatus, remainingKey: "dailyQuotaRemainingPercent",
                           resetKey: "dailyQuotaResetAtUnix")
        let weekly = window(planStatus, remainingKey: "weeklyQuotaRemainingPercent",
                            resetKey: "weeklyQuotaResetAtUnix")
        guard daily != nil || weekly != nil else {
            throw DevinUsageError.parseFailed("GetUserStatus has no quota windows")
        }
        let planName = (planInfo?["planName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let organization = (devinInfo?["accountDisplayName"] as? String)
            ?? (devinInfo?["orgId"] as? String)
        return DevinUsageSnapshot(
            daily: daily,
            weekly: weekly,
            planName: planName,
            organization: organization,
            updatedAt: now)
    }

    /// proto3 JSON omits zero-valued fields, so a window whose reset time is
    /// present but whose remaining percent is absent means 0% remaining.
    /// A window with neither field is not offered by the plan.
    private static func window(
        _ planStatus: [String: Any], remainingKey: String, resetKey: String) -> DevinQuotaWindow?
    {
        let remaining = number(planStatus[remainingKey])
        let resetUnix = number(planStatus[resetKey])
        guard remaining != nil || resetUnix != nil else { return nil }
        let resetsAt = resetUnix.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        return DevinQuotaWindow(usedPercent: 100 - (remaining ?? 0), resetsAt: resetsAt)
    }

    /// int64 fields arrive as JSON strings under proto3 JSON mapping.
    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }
}
