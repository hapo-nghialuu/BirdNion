import Foundation
import Security

/// Claude (Anthropic) subscription usage provider — fully native, no CodexBarCore.
///
/// Data sources (OAuth API, Web cookie scrape, CLI PTY, Admin API) are resolved
/// and fetched by `ClaudeUsageOrchestrator`, which returns a unified
/// `ClaudeUsageSnapshot`. This type maps that into `ProviderStatus`, adds the
/// detected `claude` CLI version, the user's account-label override, and the
/// Anthropic service-status badge.
///
/// OAuth tokens are resolved env → `~/.claude/.credentials.json` → the macOS
/// Keychain item `Claude Code-credentials` (the first Keychain read triggers a
/// one-time access prompt), with an in-memory refresh-token grant when expired.
final class ClaudeProvider: QuotaProvider {
    let id = "claude"
    let displayName = "Claude"

    static let keychainService = "Claude Code-credentials"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func override() -> String? {
        BirdNionConfigStore.accountLabel(provider: id)
    }

    // No global fetch cap — mirrors CodexBar. Each source carries its own
    // budget (OAuth request 30s, CLI PTY 12/24s + 60s retry, web 15s, status
    // badge 6s), so the chain is bounded without an outer race that would
    // kill a legitimately slow CLI probe mid-flight. QuotaService publishes
    // provider results incrementally, so a slow Claude fetch never blocks
    // the other providers' UI.
    func fetch() async throws -> ProviderStatus {
        await runFetch()
    }

    /// Keychain prompting mirrors CodexBar: `.always` may prompt anywhere,
    /// `.onlyOnUserAction` only during a user-forced refresh (background polls
    /// stay silent), `.never` never prompts.
    static func allowKeychainPrompt(mode: ClaudeOAuthKeychainPromptMode,
                                    interaction: ProviderInteraction) -> Bool {
        switch mode {
        case .never: false
        case .always: true
        case .onlyOnUserAction: interaction == .userInitiated
        }
    }

    private func runFetch() async -> ProviderStatus {
        let allowPrompt = Self.allowKeychainPrompt(
            mode: ClaudeOAuthKeychainPromptPreference.current(),
            interaction: ProviderInteractionContext.current)
        async let statusAsync = Self.fetchServiceStatus()
        do {
            let result = try await ClaudeUsageOrchestrator.loadLatestUsage(
                session: session, allowKeychainPrompt: allowPrompt)
            let status = await statusAsync
            return Self.materialize(from: result.snapshot, override: override(),
                                    sourceLabel: result.sourceLabel, status: status,
                                    allowKeychainRead: allowPrompt)
        } catch {
            let status = await statusAsync
            return failure("Claude: \(error.localizedDescription)", status: status)
        }
    }

    // MARK: - Materialize

    /// Converts a native `ClaudeUsageSnapshot` into the app-facing `ProviderStatus`.
    /// `allowKeychainRead` follows the same prompt gating as the OAuth path —
    /// background refreshes with mode `.never`/`.onlyOnUserAction` must not
    /// touch the Keychain (it can pop an auth dialog); they reuse the last
    /// successfully read blob instead.
    static func materialize(from snapshot: ClaudeUsageSnapshot,
                            override: String?,
                            sourceLabel: String,
                            status: ClaudeServiceStatus?,
                            allowKeychainRead: Bool = true) -> ProviderStatus {
        var windows: [QuotaWindow] = []
        if let primary = snapshot.primary {
            let label = snapshot.primaryWindowKind == .spendLimit ? "Spend" : "5 giờ"
            windows.append(window(label: label, utilization: primary.usedPercent,
                                  resetsAt: primary.resetsAt, seconds: (primary.windowMinutes ?? 300) * 60))
        }
        if let sec = snapshot.secondary {
            windows.append(window(label: "Tuần", utilization: sec.usedPercent,
                                  resetsAt: sec.resetsAt, seconds: 7 * 24 * 3600))
        }
        if let opus = snapshot.opus {
            windows.append(window(label: "Opus", utilization: opus.usedPercent,
                                  resetsAt: opus.resetsAt, seconds: 7 * 24 * 3600))
        }
        // Extra product windows ("Daily Routines") render as bars like
        // CodexBar's menu card. Model-scoped weekly limits ("X only") stay out
        // of the popover by user preference — they remain visible in the
        // Settings cost section via webExtras. Supplementary: they never take
        // over the lowest-quota headline.
        for extra in snapshot.extraRateWindows
        where !extra.id.hasPrefix("claude-weekly-scoped-") {
            let used = max(0, min(100, Int(extra.window.usedPercent.rounded())))
            windows.append(QuotaWindow(
                label: extra.title, usedPct: used, remainingPct: 100 - used,
                resetDate: extra.window.resetsAt,
                windowSeconds: (extra.window.windowMinutes ?? 7 * 24 * 60) * 60,
                isSupplementary: true))
        }

        // Plan + account email come from the same Keychain blob the token lives
        // in. Only read when prompting is allowed; otherwise reuse the cache.
        if allowKeychainRead, let fresh = readKeychainData() {
            cachedKeychainBlob = fresh
        }
        let keychain = KeychainRoot.decode(keychainData: cachedKeychainBlob)
        let planName = ClaudePlanLabeler.label(subscriptionType: keychain?.subscriptionType,
                                               rateLimitTier: keychain?.rateLimitTier)
            ?? ClaudePlanLabeler.label(fromLoginMethod: snapshot.loginMethod)
        let label = override ?? keychain?.email ?? snapshot.accountEmail

        let extras = ClaudeWebExtras(
            accountEmail: snapshot.accountEmail,
            accountOrganization: snapshot.accountOrganization,
            loginMethod: snapshot.loginMethod,
            sessionPercentUsed: snapshot.primary?.usedPercent,
            weeklyPercentUsed: snapshot.secondary?.usedPercent,
            opusPercentUsed: snapshot.opus?.usedPercent,
            extraRateWindows: snapshot.extraRateWindows.map { named in
                ClaudeExtraRateWindow(
                    id: named.id, title: named.title,
                    usedPercent: Int(named.window.usedPercent.rounded()),
                    resetsAt: named.window.resetsAt,
                    resetDescription: named.window.resetDescription,
                    windowMinutes: named.window.windowMinutes)
            },
            sourceLabel: sourceLabel)

        // Empty windows + no cost = genuinely no data (surface as error so the UI
        // shows the empty state). Empty windows WITH cost (Admin mode) is valid.
        let error: String? = (windows.isEmpty && snapshot.providerCost == nil)
            ? "Claude chưa có dữ liệu quota" : nil

        return ProviderStatus(
            id: "claude", displayName: "Claude",
            windows: windows, lastUpdated: Date(), error: error,
            accountLabel: label,
            creditsRemaining: spendRemainingFromCost(snapshot.providerCost),
            version: detectedClaudeVersion(),
            serviceStatus: status?.description,
            serviceStatusLevel: status?.indicator,
            planName: planName,
            cost: snapshot.providerCost,
            webExtras: extras,
            claudeAdminUsage: snapshot.adminUsage)
    }

    /// Remaining spend balance for the credits cell, when the cost snapshot is
    /// credit-style (used < limit).
    private static func spendRemainingFromCost(_ cost: ProviderCostSnapshot?) -> Double? {
        guard let cost, cost.limit > 0 else { return nil }
        return max(0, cost.limit - cost.used)
    }

    /// `utilization` is a percent already used (0..100).
    static func window(label: String, utilization: Double, resetsAt: Date?, seconds: Int) -> QuotaWindow {
        let used = max(0, min(100, Int(utilization.rounded())))
        return QuotaWindow(label: label, usedPct: used, remainingPct: 100 - used,
                           resetDate: resetsAt, windowSeconds: seconds)
    }

    private func failure(_ message: String, status: ClaudeServiceStatus? = nil) -> ProviderStatus {
        ProviderStatus(
            id: id, displayName: displayName, windows: [], lastUpdated: Date(),
            error: message, version: Self.detectedClaudeVersion(),
            serviceStatus: status?.description, serviceStatusLevel: status?.indicator)
    }

    // MARK: - Keychain (plan + email)

    /// Last successfully read Keychain blob — lets background refreshes keep
    /// showing plan + email without re-touching the Keychain (same memoization
    /// pattern as `cachedClaudeVersion`).
    private static var cachedKeychainBlob: Data?

    /// Reads the raw `Claude Code-credentials` keychain blob so the plan + email
    /// can be surfaced. Returns nil if absent or access is denied.
    static func readKeychainData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }

    // MARK: - CLI version

    private static var cachedClaudeVersion: String?

    /// Detects the installed `claude` CLI version (memoized). nil when absent.
    static func detectedClaudeVersion() -> String? {
        if let cached = cachedClaudeVersion { return cached.isEmpty ? nil : cached }
        let raw = ClaudeCLIVersionDetector.claudeVersion()
        cachedClaudeVersion = raw ?? ""
        return raw
    }

    // MARK: - Service status (status.anthropic.com)

    /// Best-effort Anthropic status badge. Short timeout, never throws.
    static func fetchServiceStatus() async -> ClaudeServiceStatus? {
        guard let url = URL(string: "https://status.anthropic.com/api/v2/summary.json") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        struct Payload: Decodable {
            struct S: Decodable { let indicator: String?; let description: String? }
            let status: S?
        }
        guard let p = try? JSONDecoder().decode(Payload.self, from: data), let s = p.status else { return nil }
        return ClaudeServiceStatus(indicator: s.indicator ?? "unknown", description: s.description ?? "Unknown")
    }

    // MARK: - Models

    /// Decoded shape of the Claude Code Keychain JSON (plan + email only).
    struct KeychainRoot: Decodable {
        let claudeAiOauth: OAuth?
        struct OAuth: Decodable {
            let accessToken: String?
            let rateLimitTier: String?
            let subscriptionType: String?
            let email: String?
        }

        static func decode(keychainData: Data?) -> OAuth? {
            guard let data = keychainData, !data.isEmpty,
                  let root = try? JSONDecoder().decode(KeychainRoot.self, from: data) else { return nil }
            return root.claudeAiOauth
        }
    }
}
