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
    private let fetchers: ClaudeUsageOrchestrator.Fetchers

    init(session: URLSession = .shared,
         fetchers: ClaudeUsageOrchestrator.Fetchers = .live) {
        self.session = session
        self.fetchers = fetchers
    }

    private func override() -> String? {
        BirdNionConfigStore.accountLabel(provider: id)
    }

    /// Legacy single-shot entry point (Settings self-test): drains the status
    /// stream and returns the last emission — the fully enriched status, or
    /// the sole error status when the fetch fails.
    func fetch() async throws -> ProviderStatus {
        var last: ProviderStatus?
        for await status in statuses(interaction: ProviderInteractionContext.current) {
            last = status
        }
        return last ?? failure("Claude không trả dữ liệu")
    }

    /// Two-phase fetch: emission 0 is the core quota status (windows, account
    /// label, plan, web-extras-merged cost) derived purely from the usage
    /// result — the statuspage probe and CLI version detection are not awaited
    /// before it. Emission 1 carries enrichment only (`version`,
    /// `serviceStatus`) so a failed side probe can never touch the published
    /// core. Failure stays a single `failure(_:)` emission, unchanged.
    func statuses(interaction: ProviderInteraction) -> AsyncStream<ProviderStatus> {
        AsyncStream { continuation in
            let task = Task {
                await ProviderInteractionContext.$current.withValue(interaction) {
                    await self.produceStatuses(interaction: interaction, into: continuation)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func produceStatuses(
        interaction: ProviderInteraction,
        into continuation: AsyncStream<ProviderStatus>.Continuation
    ) async {
        let allowPrompt = Self.allowKeychainPrompt(
            mode: ClaudeOAuthKeychainPromptPreference.current(),
            interaction: interaction)
        // Same preference gate as Codex (`statusChecksEnabled`) so Settings →
        // "Check provider status" also stops the Anthropic statuspage probe.
        // Runs concurrently but only rides the enrichment emission.
        async let statusAsync: ClaudeServiceStatus? = Self.statusChecksEnabled
            ? Self.fetchServiceStatus()
            : nil
        do {
            let result = try await ClaudeUsageOrchestrator.loadLatestUsage(
                session: session, allowKeychainPrompt: allowPrompt,
                interaction: interaction, fetchers: fetchers)
            // Phase 1 — core quota data, published before side probes settle.
            continuation.yield(Self.materialize(
                from: result.snapshot, override: override(),
                sourceLabel: result.sourceLabel, status: nil,
                allowKeychainRead: allowPrompt, includeVersion: false))
            // Phase 2 — enrichment: statuspage badge + detected CLI version.
            // Never carries `error` (emission policy drops it otherwise).
            let status = await statusAsync
            continuation.yield(ProviderStatus(
                id: id, displayName: displayName, windows: [],
                lastUpdated: Date(),
                version: Self.detectedClaudeVersion(),
                serviceStatus: status?.description,
                serviceStatusLevel: status?.indicator))
        } catch {
            let status = await statusAsync
            continuation.yield(failure("Claude: \(error.localizedDescription)", status: status))
        }
    }

    /// True when an extra rate window is the Claude Fable model-scoped limit.
    static func isFableExtra(_ extra: NamedRateWindow) -> Bool {
        extra.id.lowercased().contains("fable") || isFableWindowLabel(extra.title)
    }

    /// True when a mapped `QuotaWindow` label is Claude Fable (popover filter).
    static func isFableWindowLabel(_ label: String) -> Bool {
        label.lowercased().contains("fable")
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
                            allowKeychainRead: Bool = true,
                            includeVersion: Bool = true) -> ProviderStatus {
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
        // CodexBar's menu card. Other model-scoped weekly limits ("Sonnet only")
        // stay out of `windows` (Settings cost keeps them via webExtras).
        // Fable is an exception: included here so Settings → Claude can toggle
        // popover visibility (default on); the popover filters when off.
        for extra in snapshot.extraRateWindows where extra.usageKnown {
            let isScoped = extra.id.hasPrefix("claude-weekly-scoped-")
            let isFable = Self.isFableExtra(extra)
            if isScoped && !isFable { continue }
            let used = max(0, min(100, Int(extra.window.usedPercent.rounded())))
            windows.append(QuotaWindow(
                label: isFable ? "Fable" : extra.title,
                usedPct: used, remainingPct: 100 - used,
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
            extraRateWindows: snapshot.extraRateWindows.filter(\.usageKnown).map { named in
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
            version: includeVersion ? detectedClaudeVersion() : nil,
            serviceStatus: status?.description,
            serviceStatusLevel: status?.indicator,
            planName: planName,
            cost: snapshot.providerCost,
            webExtras: extras,
            sourceLabel: sourceLabel,
            claudeAdminUsage: snapshot.adminUsage)
    }

    /// Remaining spend balance for the credits cell, when the cost snapshot is
    /// credit-style (used < limit).
    private static func spendRemainingFromCost(_ cost: ProviderCostSnapshot?) -> Double? {
        if let prepaid = cost?.balance { return prepaid }
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

    /// Reads the same `statusChecksEnabled` preference Settings binds (default on).
    private static var statusChecksEnabled: Bool {
        (UserDefaults.standard.object(forKey: "statusChecksEnabled") as? Bool) ?? true
    }

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
