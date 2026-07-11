import Foundation
import CodexBarCore

/// Grok (xAI) quota provider.
///
/// Data sources match CodexBar's Grok pipeline (auto = CLI → web):
/// 1. `~/.grok/auth.json` identity (`GrokCredentialsStore`)
/// 2. `grok agent stdio` JSON-RPC `x.ai/billing` (`GrokStatusProbe`)
/// 3. grok.com gRPC-web billing via browser cookies or auth bearer
///    (`GrokCookieImporter` + `GrokWebBillingFetcher`)
///
/// Zero-config: no BirdNion API key. User enables Grok after `grok login`
/// and/or signing into grok.com in Chrome.
final class GrokProvider: QuotaProvider {
    let id = "grok"
    let displayName = "Grok"

    private let env: [String: String]
    private let allowBrowserCookies: Bool

    init(
        env: [String: String] = ProcessInfo.processInfo.environment,
        allowBrowserCookies: Bool = true)
    {
        self.env = env
        self.allowBrowserCookies = allowBrowserCookies
    }

    func fetch() async throws -> ProviderStatus {
        let credentials = try? GrokCredentialsStore.load(env: env)
        let overrideLabel = BirdNionConfigStore.accountLabel(provider: id)
        var lastError: Error?

        // 1) CLI RPC (best-effort; often Method not found on current grok agent)
        do {
            let probe = GrokStatusProbe()
            let snap = try await probe.fetch(env: env)
            return Self.mapSnapshot(
                snap,
                accountLabelOverride: overrideLabel,
                sourceLabel: "grok-cli")
        } catch {
            lastError = error
        }

        // 2) Web billing fallback (cookies, then auth.json bearer)
        do {
            let (webBilling, sourceLabel, authenticatedByAuthFile) = try await fetchWebBilling(
                credentials: credentials)
            // Cookie-authenticated sessions intentionally drop auth.json identity
            // (matches CodexBar GrokWebFetchStrategy). Auth-file bearer keeps it.
            let identityCreds = authenticatedByAuthFile
                ? Self.credentialsForSuccessfulRemote(credentials)
                : nil
            let snap = GrokUsageSnapshot(
                billing: nil,
                webBilling: webBilling,
                credentials: identityCreds,
                localSummary: GrokLocalSessionScanner.summarize(env: env),
                cliVersion: GrokStatusProbe.detectVersion(env: env),
                updatedAt: Date())
            return Self.mapSnapshot(
                snap,
                accountLabelOverride: overrideLabel,
                sourceLabel: sourceLabel)
        } catch {
            lastError = error
        }

        return failure(Self.friendlyError(lastError, credentials: credentials))
    }

    // MARK: - Testing hooks

    /// Map a CLI/web snapshot into ProviderStatus without network I/O.
    static func mapSnapshot(
        _ snap: GrokUsageSnapshot,
        accountLabelOverride: String? = nil,
        sourceLabel: String? = nil,
        now: Date = Date()) -> ProviderStatus
    {
        let usage = snap.toUsageSnapshot()
        let accountLabel = accountLabelOverride
            ?? snap.credentials?.email
            ?? snap.credentials?.displayName
        let planName = snap.credentials?.loginMethod

        guard let primary = usage.primary else {
            return ProviderStatus(
                id: "grok",
                displayName: "Grok",
                windows: [],
                lastUpdated: now,
                error: "Grok: không có dữ liệu usage",
                accountLabel: accountLabel,
                planName: planName,
                sourceLabel: sourceLabel)
        }

        let usedPct = Int(primary.usedPercent.rounded())
        let remainingPct = max(0, min(100, 100 - usedPct))
        let englishLabel = GrokProviderDescriptor.primaryLabel(window: primary, now: now) ?? "Credits"
        let label = localizeWindowLabel(englishLabel)
        // Full window length only — never approximate from remaining-until-reset
        // (that would corrupt WindowPace reserve calculations).
        let windowSeconds: Int? = primary.windowMinutes.flatMap { $0 > 0 ? $0 * 60 : nil }

        var subtitle: String?
        if let billing = snap.billing,
           let limitCents = billing.monthlyLimit?.val, limitCents > 0,
           let usedCents = billing.usage?.totalUsed?.val
        {
            let usedUSD = Double(usedCents) / 100.0
            let limitUSD = Double(limitCents) / 100.0
            subtitle = String(format: "$%.2f / $%.2f", usedUSD, limitUSD)
        }

        let window = QuotaWindow(
            label: label,
            usedPct: max(0, min(100, usedPct)),
            remainingPct: remainingPct,
            subtitle: subtitle,
            resetDate: primary.resetsAt,
            windowSeconds: windowSeconds)

        return ProviderStatus(
            id: "grok",
            displayName: "Grok",
            windows: [window],
            lastUpdated: now,
            error: nil,
            accountLabel: accountLabel,
            planName: planName,
            sourceLabel: sourceLabel)
    }

    /// Map a raw CLI billing JSON result into ProviderStatus (unit tests).
    static func _parseBillingJSONForTesting(
        _ data: Data,
        email: String? = nil,
        loginMethod: String? = "SuperGrok",
        now: Date = Date()) throws -> ProviderStatus
    {
        let billing = try JSONDecoder().decode(GrokBillingResponse.self, from: data)
        let creds: GrokCredentials? = {
            guard email != nil || loginMethod != nil else { return nil }
            return GrokCredentials(
                accessToken: "test",
                refreshToken: nil,
                scope: "test",
                authMode: loginMethod == "SuperGrok" ? "oidc" : loginMethod,
                userId: nil,
                email: email,
                firstName: nil,
                lastName: nil,
                teamId: nil,
                oidcIssuer: nil,
                oidcClientId: nil,
                expiresAt: nil,
                createTime: nil)
        }()
        let snap = GrokUsageSnapshot(
            billing: billing,
            webBilling: nil,
            credentials: creds,
            localSummary: nil,
            cliVersion: nil,
            updatedAt: now)
        return mapSnapshot(snap, now: now)
    }

    /// Map a web billing snapshot into ProviderStatus (unit tests; no protobuf parse).
    static func _mapWebBillingForTesting(
        usedPercent: Double,
        resetsAt: Date?,
        email: String? = nil,
        now: Date = Date()) -> ProviderStatus
    {
        let web = GrokWebBillingSnapshot(usedPercent: usedPercent, resetsAt: resetsAt)
        let creds: GrokCredentials? = email.map {
            GrokCredentials(
                accessToken: "test",
                refreshToken: nil,
                scope: "test",
                authMode: "oidc",
                userId: nil,
                email: $0,
                firstName: nil,
                lastName: nil,
                teamId: nil,
                oidcIssuer: nil,
                oidcClientId: nil,
                expiresAt: nil,
                createTime: nil)
        }
        let snap = GrokUsageSnapshot(
            billing: nil,
            webBilling: web,
            credentials: creds,
            localSummary: nil,
            cliVersion: nil,
            updatedAt: now)
        return mapSnapshot(snap, now: now)
    }

    /// When remote usage succeeded, keep local identity even if expires_at is stale
    /// (mirrors CodexBar `GrokStatusProbe.credentialsForSnapshot` without calling internals).
    static func credentialsForSuccessfulRemote(_ credentials: GrokCredentials?) -> GrokCredentials? {
        credentials
    }

    static func isSignedIn(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        signedInEmail(env: env) != nil
            || (try? GrokCredentialsStore.load(env: env)) != nil
    }

    static func signedInEmail(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        (try? GrokCredentialsStore.load(env: env))?.email
    }

    // MARK: - Web billing

    private func fetchWebBilling(credentials: GrokCredentials?) async throws -> (
        snapshot: GrokWebBillingSnapshot,
        sourceLabel: String,
        authenticatedByAuthFile: Bool)
    {
        var lastCookieError: Error?

        #if os(macOS)
        if allowBrowserCookies {
            do {
                let sessions = try GrokCookieImporter.importSessions()
                let (snapshot, sourceLabel) = try await Self.fetchFirstValidCookieSession(
                    sessions,
                    credentials: credentials)
                return (snapshot, sourceLabel, false)
            } catch {
                lastCookieError = error
            }
            if credentials == nil {
                if FileManager.default.fileExists(
                    atPath: GrokCredentialsStore.authFileURL(env: env).path)
                {
                    // Force surface credential decode errors when the file exists
                    // but is unusable.
                    _ = try GrokCredentialsStore.load(env: env)
                }
                throw lastCookieError ?? GrokWebBillingError.missingCredentials
            }
        }
        #endif

        guard let authCredentials = credentials, !authCredentials.isExpired else {
            throw lastCookieError ?? GrokWebBillingError.missingCredentials
        }
        let snapshot = try await GrokWebBillingFetcher.fetch(credentials: authCredentials)
        return (snapshot, "grok-web", true)
    }

    #if os(macOS)
    static func fetchFirstValidCookieSession(
        _ sessions: [GrokCookieImporter.SessionInfo],
        credentials: GrokCredentials? = nil) async throws -> (GrokWebBillingSnapshot, String)
    {
        var lastError: Error?
        for session in sessions {
            do {
                let snapshot = try await GrokWebBillingFetcher.fetch(
                    cookieHeader: session.cookieHeader,
                    credentials: credentials)
                return (snapshot, session.sourceLabel)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? GrokWebBillingError.missingCredentials
    }
    #endif

    // MARK: - Helpers

    static func localizeWindowLabel(_ english: String) -> String {
        switch english {
        case "Weekly": return "Tuần"
        case "Monthly": return "Tháng"
        default: return english
        }
    }

    private static func friendlyError(_ error: Error?, credentials: GrokCredentials?) -> String {
        if let error {
            if let web = error as? GrokWebBillingError {
                return web.localizedDescription
            }
            if let rpc = error as? GrokRPCError {
                return rpc.localizedDescription
            }
            let text = error.localizedDescription
            if !text.isEmpty { return text }
        }
        if credentials == nil {
            return "Chưa đăng nhập Grok. Chạy `grok login` hoặc đăng nhập grok.com (Chrome)."
        }
        if credentials?.isExpired == true {
            return "Token Grok đã hết hạn. Chạy lại `grok login`."
        }
        return "Không lấy được usage Grok. Kiểm tra `grok login` / session grok.com."
    }

    private func failure(_ message: String) -> ProviderStatus {
        let email = (try? GrokCredentialsStore.load(env: env))?.email
        let label = BirdNionConfigStore.accountLabel(provider: id) ?? email
        return ProviderStatus(
            id: id,
            displayName: displayName,
            windows: [],
            lastUpdated: Date(),
            error: message,
            accountLabel: label)
    }
}
