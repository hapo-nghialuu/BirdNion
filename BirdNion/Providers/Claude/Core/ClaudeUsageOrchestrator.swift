import Foundation

// Native replacement for CodexBarCore's ClaudeUsageFetcher. Resolves the user's
// selected source (or the auto plan), runs the matching native fetcher, and
// maps the result into a unified ClaudeUsageSnapshot. For `.auto` it walks the
// planner's ordered steps and returns the first that succeeds. When web extras
// are enabled (cookie source != off) and the primary source lacks cost/extra
// windows, it best-effort merges the claude.ai cookie scrape — this restores
// the OAuth-mode cost overlay that was removed in the 2026-06-25 refactor.
enum ClaudeUsageOrchestrator {
    struct Result {
        let snapshot: ClaudeUsageSnapshot
        let sourceLabel: String
    }

    /// Injectable seam for the per-source fetchers + environment probes, so
    /// the staged race is unit-testable without network/Keychain/PTY. The
    /// live defaults call exactly the same code paths as before.
    struct Fetchers: Sendable {
        var oauth: @Sendable (URLSession, Bool) async throws -> ClaudeUsageSnapshot
        var web: @Sendable (ClaudeCookieSource, String?, URLSession) async throws -> ClaudeWebUsageData
        /// PTY/direct CLI chain. `allowRetry` gates the 60s retry budget
        /// (manual interaction only); `budget` clamps the probe timeout to the
        /// remaining core budget.
        var cli: @Sendable (Bool, Bool, TimeInterval?) async throws -> ClaudeStatusSnapshot
        var admin: @Sendable (URLSession) async throws -> ClaudeUsageSnapshot
        var hasCLI: @Sendable () -> Bool
        var autoWebSessionSuppressed: @Sendable () -> Bool
        var readDataSource: @Sendable () -> ClaudeUsageDataSource
        var readCookieSource: @Sendable () -> ClaudeCookieSource
        var readManualCookie: @Sendable () -> String?
        var now: @Sendable () -> Date

        static let live = Fetchers(
            oauth: { session, allowPrompt in
                try await ClaudeOAuthUsageAPI.loadSnapshot(
                    session: session, allowKeychainPrompt: allowPrompt)
            },
            web: { cookieSource, manualCookie, session in
                if cookieSource == .manual, let header = manualCookie {
                    return try await ClaudeWebAPIFetcher.fetchUsage(
                        cookieHeader: header, session: session)
                }
                return try await ClaudeWebAPIFetcher.fetchUsage(session: session)
            },
            cli: { isAutoPlan, allowRetry, budget in
                try await cliFetch(
                    isAutoPlan: isAutoPlan, allowRetry: allowRetry, budget: budget)
            },
            admin: { session in try await fetchAdmin(session: session) },
            hasCLI: { ClaudeCLIResolver.isAvailable() },
            autoWebSessionSuppressed: { ClaudeWebCookieReader.isAutoSuppressed },
            readDataSource: { ClaudeUsageOrchestrator.readDataSource() },
            readCookieSource: { ClaudeUsageOrchestrator.readCookieSource() },
            readManualCookie: { readManualCookieHeader() },
            now: { Date() })
    }

    static func loadLatestUsage(session: URLSession = .shared,
                                allowKeychainPrompt: Bool,
                                interaction: ProviderInteraction = .background,
                                fetchers: Fetchers = .live) async throws -> Result {
        let selected = fetchers.readDataSource()
        let cookieSource = fetchers.readCookieSource()
        let manualCookie = fetchers.readManualCookie()
        let webEnabled = cookieSource != .off
        let coreDeadline = fetchers.now()
            .addingTimeInterval(ProviderFetchPhaseBudgets.coreSeconds(for: interaction))

        let input = ClaudeSourcePlanningInput(
            selectedDataSource: selected,
            webExtrasEnabled: webEnabled,
            hasWebSession: cookieSource == .manual
                ? (manualCookie != nil)
                : (cookieSource == .auto && !fetchers.autoWebSessionSuppressed()),
            hasCLI: fetchers.hasCLI(),
            hasOAuthCredentials: true)   // OAuth is the default; the fetch reports real availability
        let plan = ClaudeSourcePlanner.resolve(input: input)

        var lastError: Error?
        /// The HTTP race's Web outcome — reused by a later stage's extras merge
        /// so a failed/untrusted race scrape is never retried a second time.
        var raceWebOutcome: Swift.Result<ClaudeWebUsageData, Error>?
        for stage in plan.executionStages {
            switch stage {
            case .race(let steps):
                if let winner = await raceHTTPSources(
                    steps: steps, session: session, cookieSource: cookieSource,
                    manualCookie: manualCookie, allowKeychainPrompt: allowKeychainPrompt,
                    webEnabled: webEnabled, coreDeadline: coreDeadline,
                    fetchers: fetchers, lastError: &lastError,
                    webOutcome: &raceWebOutcome)
                {
                    return winner
                }
            case .single(let step):
                let remaining = coreDeadline.timeIntervalSince(fetchers.now())
                // CLI starvation guard (F-09): in background polls a nearly
                // exhausted core budget can't fit even the cheapest PTY probe —
                // skip the stage instead of spawning a doomed process.
                if step.dataSource == .cli, interaction == .background, remaining < 10 {
                    lastError = lastError ?? ClaudeUsageError.parseFailed(
                        "CLI: ngân sách fetch còn lại quá ngắn cho PTY probe")
                    continue
                }
                do {
                    var snapshot = try await fetch(
                        step.dataSource, session: session, cookieSource: cookieSource,
                        manualCookie: manualCookie, allowKeychainPrompt: allowKeychainPrompt,
                        isAutoPlan: selected == .auto, interaction: interaction,
                        remainingBudget: remaining, fetchers: fetchers)
                    guard hasTrustedData(snapshot) else {
                        throw ClaudeUsageError.parseFailed(
                            "\(step.dataSource.sourceLabel): phản hồi không có quota/cost hợp lệ")
                    }
                    if webEnabled, step.dataSource != .web {
                        snapshot = await applyWebExtras(
                            to: snapshot, cookieSource: cookieSource,
                            manualCookie: manualCookie, session: session,
                            prefetched: raceWebOutcome, fetchers: fetchers)
                    }
                    return Result(snapshot: snapshot, sourceLabel: step.dataSource.sourceLabel)
                } catch {
                    lastError = error
                }
            }
        }
        throw lastError ?? ClaudeUsageError.oauthFailed("Không có nguồn Claude khả dụng")
    }

    // MARK: - Stage 1: HTTP source race (auto plan)

    /// Races the available HTTP sources (OAuth‖Web). The first TRUSTED result
    /// wins the core; if Web resolves first while OAuth is still in flight a
    /// short grace lets OAuth steal the win (OAuth outranks Web when both
    /// resolve). The losing Web result — when it lands within the extras
    /// window — is reused for the `applyWebExtras` merge instead of a second
    /// scrape. Returns nil when no source produced trusted data (errors are
    /// accumulated into `lastError` for the CLI stage/failure path).
    private static func raceHTTPSources(
        steps: [ClaudeFetchPlanStep],
        session: URLSession,
        cookieSource: ClaudeCookieSource,
        manualCookie: String?,
        allowKeychainPrompt: Bool,
        webEnabled: Bool,
        coreDeadline: Date,
        fetchers: Fetchers,
        lastError: inout Error?,
        webOutcome raceWebOutcome: inout Swift.Result<ClaudeWebUsageData, Error>?
    ) async -> Result? {
        enum Outcome {
            case oauth(Swift.Result<ClaudeUsageSnapshot, Error>)
            case web(Swift.Result<ClaudeWebUsageData, Error>)
            case stageDeadline
            case oauthGraceExpired
            case extrasExpired
        }
        /// How long a provisional Web winner waits for a still-running OAuth
        /// before locking in (OAuth outranks Web when both resolve).
        let oauthTieBreakGrace: TimeInterval = 0.75
        /// Loser-Web harvest window — the same 5s bound `applyWebExtras`
        /// always used for its rescue scrape.
        let extrasWindow: TimeInterval = 5

        let hasOAuthStep = steps.contains { $0.dataSource == .oauth }
        let hasWebStep = steps.contains { $0.dataSource == .web }
        var winner: (snapshot: ClaudeUsageSnapshot, source: ClaudeUsageDataSource)?
        var webCandidate: ClaudeUsageSnapshot?
        var webOutcome: Swift.Result<ClaudeWebUsageData, Error>?
        var oauthSettled = !hasOAuthStep
        var graceArmed = false
        var extrasArmed = false

        await withTaskGroup(of: Outcome.self) { group in
            for step in steps {
                switch step.dataSource {
                case .oauth:
                    group.addTask {
                        do {
                            return .oauth(.success(try await fetchers.oauth(
                                session, allowKeychainPrompt)))
                        } catch { return .oauth(.failure(error)) }
                    }
                case .web:
                    group.addTask {
                        do {
                            return .web(.success(try await fetchers.web(
                                cookieSource, manualCookie, session)))
                        } catch { return .web(.failure(error)) }
                    }
                default: break
                }
            }
            group.addTask {
                let delay = max(0, coreDeadline.timeIntervalSince(fetchers.now()))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return .stageDeadline
            }

            var done = false
            for await outcome in group {
                if done { break }
                switch outcome {
                case .stageDeadline, .extrasExpired:
                    group.cancelAll()
                    done = true
                case .oauthGraceExpired:
                    // Grace elapsed with OAuth still unsettled → the
                    // provisional Web candidate locks in as the winner.
                    if winner == nil, let webCandidate {
                        winner = (webCandidate, .web)
                    }
                case .oauth(let result):
                    oauthSettled = true
                    switch result {
                    case .success(let snapshot) where hasTrustedData(snapshot):
                        // OAuth wins while undecided — including over a
                        // provisional Web candidate still inside its grace
                        // window. A locked-in Web winner (grace expired or
                        // OAuth already settled) is not stolen retroactively.
                        if winner == nil { winner = (snapshot, .oauth) }
                    case .success:
                        lastError = ClaudeUsageError.parseFailed(
                            "OAuth API: phản hồi không có quota/cost hợp lệ")
                    case .failure(let error):
                        lastError = error
                    }
                    if winner == nil, let webCandidate {
                        winner = (webCandidate, .web)
                    }
                case .web(let result):
                    webOutcome = result
                    switch result {
                    case .success(let data):
                        let snapshot = mapWeb(data)
                        if hasTrustedData(snapshot) {
                            if winner == nil {
                                if oauthSettled {
                                    winner = (snapshot, .web)
                                } else {
                                    // Provisional: OAuth may still steal the
                                    // core inside the tie-break grace.
                                    webCandidate = snapshot
                                    if !graceArmed {
                                        graceArmed = true
                                        group.addTask {
                                            try? await Task.sleep(nanoseconds:
                                                UInt64(oauthTieBreakGrace * 1_000_000_000))
                                            return .oauthGraceExpired
                                        }
                                    }
                                }
                            }
                        } else {
                            lastError = ClaudeUsageError.parseFailed(
                                "Web API (cookies): phản hồi không có quota/cost hợp lệ")
                        }
                    case .failure(let error):
                        lastError = error
                    }
                }
                // Settlement check after each outcome.
                if let winner {
                    // Keep draining only while the loser-Web harvest is still
                    // worth waiting for (bounded by the armed extras expiry).
                    let harvesting = winner.source == .oauth && webEnabled
                        && hasWebStep && webOutcome == nil
                    if harvesting {
                        if !extrasArmed {
                            extrasArmed = true
                            group.addTask {
                                try? await Task.sleep(nanoseconds:
                                    UInt64(extrasWindow * 1_000_000_000))
                                return .extrasExpired
                            }
                        }
                    } else {
                        group.cancelAll()
                        done = true
                    }
                } else if oauthSettled, webOutcome != nil {
                    group.cancelAll()
                    done = true
                }
            }
        }
        raceWebOutcome = webOutcome
        guard let winner else { return nil }

        var snapshot = winner.snapshot
        if webEnabled, winner.source != .web {
            // Loser-Web reuse: the raced web fetch doubles as the extras merge
            // source — no second scrape. `.failure` means "tried, failed —
            // don't rescrape"; nil means "not attempted — scrape as before".
            snapshot = await applyWebExtras(
                to: snapshot, cookieSource: cookieSource,
                manualCookie: manualCookie, session: session,
                prefetched: webOutcome, fetchers: fetchers)
        }
        return Result(snapshot: snapshot, sourceLabel: winner.source.sourceLabel)
    }

    private static func hasTrustedData(_ snapshot: ClaudeUsageSnapshot) -> Bool {
        snapshot.primary != nil
            || snapshot.secondary != nil
            || snapshot.opus != nil
            || snapshot.extraRateWindows.contains(where: \.usageKnown)
            || snapshot.providerCost != nil
            || snapshot.adminUsage != nil
    }

    // MARK: - Per-source fetch

    /// CLI PTY probe budgets — retry structure mirrors CodexBar's
    /// ClaudeUsageFetcher. One deviation: CodexBar's auto probe is 12s, but a
    /// cold `claude` TUI (spawn + /usage render) reliably needs longer than
    /// that here, so the 12s attempt only ever wasted its budget plus a second
    /// cold start on the retry. 24s lets the first attempt succeed in one
    /// session; a probe that still timed out (or was mid-load) is retried once
    /// with the generous budget.
    private static let cliAutoProbeTimeout: TimeInterval = 24
    private static let cliProbeTimeout: TimeInterval = 24
    private static let cliRetryProbeTimeout: TimeInterval = 60

    private static func fetch(_ source: ClaudeUsageDataSource,
                             session: URLSession,
                             cookieSource: ClaudeCookieSource,
                             manualCookie: String?,
                             allowKeychainPrompt: Bool,
                             isAutoPlan: Bool,
                             interaction: ProviderInteraction,
                             remainingBudget: TimeInterval?,
                             fetchers: Fetchers) async throws -> ClaudeUsageSnapshot {
        switch source {
        case .oauth:
            return try await fetchers.oauth(session, allowKeychainPrompt)
        case .web:
            return mapWeb(try await fetchers.web(cookieSource, manualCookie, session))
        case .cli:
            return mapCLI(try await fetchers.cli(
                isAutoPlan,
                interaction == .userInitiated,
                remainingBudget))
        case .api:
            return try await fetchers.admin(session)
        case .auto:
            throw ClaudeUsageError.parseFailed("auto không phải nguồn cụ thể")
        }
    }

    /// The live CLI fetcher behind `Fetchers.cli`: quota-unsupported gate →
    /// PTY probe → direct fallback → retry. `allowRetry` gates the generous
    /// 60s second attempt (manual refreshes only — a background poll can't
    /// afford it inside the 60s core budget); `budget` clamps the first probe
    /// to the remaining core budget.
    private static func cliFetch(isAutoPlan: Bool,
                                 allowRetry: Bool,
                                 budget: TimeInterval?) async throws -> ClaudeStatusSnapshot {
        // Skip the whole probe chain (~90s of doomed PTY attempts) when a
        // previous probe proved /usage has no quota panel on this machine.
        // Only for the auto plan — explicitly selecting the CLI source
        // always probes for real (and clears the gate on success).
        if isAutoPlan, ClaudeCLIQuotaUnsupportedGate.blockedUntil() != nil {
            throw ClaudeStatusProbeError.parseFailed(ClaudeCLIQuotaUnsupportedGate.message)
        }
        let base = isAutoPlan ? cliAutoProbeTimeout : cliProbeTimeout
        let first = budget.map { max(1, min(base, $0)) } ?? base
        do {
            return try await loadViaCLI(timeout: first)
        } catch {
            if error is CancellationError { throw error }
            guard allowRetry, shouldRetryCLIProbe(after: error) else { throw error }
            let retry = budget.map { max(1, min(cliRetryProbeTimeout, $0)) } ?? cliRetryProbeTimeout
            return try await loadViaCLI(timeout: retry)
        }
    }

    // MARK: - CLI chain (gate + PTY + direct fallback + retry, mirrors CodexBar)

    /// Rate-limit gate → PTY probe → direct (non-PTY) `claude /usage` fallback
    /// when the PTY path timed out or couldn't render usage.
    private static func loadViaCLI(timeout: TimeInterval) async throws -> ClaudeStatusSnapshot {
        if ClaudeCLIRateLimitGate.blockedUntil() != nil {
            throw ClaudeStatusProbeError.parseFailed(ClaudeCLIRateLimitGate.message)
        }
        let snapshot: ClaudeStatusSnapshot
        do {
            snapshot = try await ClaudeCLISession.loadSnapshot(timeout: timeout)
        } catch {
            if error is CancellationError { throw error }
            if ClaudeCLIQuotaUnsupportedGate.isQuotaUnsupportedError(error) {
                ClaudeCLIQuotaUnsupportedGate.recordUnsupported()
                throw error
            }
            if ClaudeCLIRateLimitGate.isRateLimitError(error) {
                ClaudeCLIRateLimitGate.recordRateLimit()
                throw error
            }
            guard shouldTryDirectCLIUsage(after: error) else { throw error }
            do {
                snapshot = try await ClaudeCLISession.loadSnapshotDirect(
                    timeout: directCLIUsageTimeout(for: timeout))
            } catch let directError {
                if directError is CancellationError { throw directError }
                if ClaudeCLIQuotaUnsupportedGate.isQuotaUnsupportedError(directError) {
                    ClaudeCLIQuotaUnsupportedGate.recordUnsupported()
                    throw directError
                }
                if ClaudeCLIRateLimitGate.isRateLimitError(directError) {
                    ClaudeCLIRateLimitGate.recordRateLimit()
                    throw directError
                }
                // Keep the (richer) PTY error unless the direct run surfaced a
                // subscription-level notice worth showing instead.
                guard directCLIErrorShouldReplacePTYError(directError) else { throw error }
                throw directError
            }
        }
        ClaudeCLIRateLimitGate.recordSuccess()
        ClaudeCLIQuotaUnsupportedGate.recordSuccess()
        return snapshot
    }

    /// Same clamp as CodexBar: the direct fallback gets 1/3 of the PTY budget,
    /// bounded to 6–8s.
    static func directCLIUsageTimeout(for ptyTimeout: TimeInterval) -> TimeInterval {
        min(max(ptyTimeout / 3, 6), 8)
    }

    static func shouldRetryCLIProbe(after error: Error) -> Bool {
        if case ClaudeStatusProbeError.timedOut = error { return true }
        if case let ClaudeStatusProbeError.parseFailed(message) = error {
            return message.lowercased().contains("still loading usage")
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("timed out") || message.contains("timeout")
    }

    static func shouldTryDirectCLIUsage(after error: Error) -> Bool {
        if case ClaudeStatusProbeError.timedOut = error { return true }
        if case let ClaudeStatusProbeError.parseFailed(message) = error {
            let lower = message.lowercased()
            return lower.contains("still loading usage") || lower.contains("could not load usage data")
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("timed out") || message.contains("timeout")
    }

    private static func directCLIErrorShouldReplacePTYError(_ error: Error) -> Bool {
        if case let ClaudeStatusProbeError.parseFailed(message) = error {
            return message.lowercased().contains("subscription")
        }
        return false
    }

    private static func fetchAdmin(session: URLSession) async throws -> ClaudeUsageSnapshot {
        guard let key = adminAPIKey() else { throw ClaudeAdminAPIUsageError.missingCredentials }
        let snap = try await ClaudeAdminAPIUsageFetcher.fetchUsage(apiKey: key, session: session)
        return ClaudeUsageSnapshot(
            primary: nil,
            secondary: nil,
            opus: nil,
            providerCost: snap.last30ProviderCost,
            updatedAt: snap.updatedAt,
            loginMethod: "Admin API",
            adminUsage: snap)
    }

    // MARK: - Web-extras merge (restores cookie cost scrape)

    /// Best-effort: fill any missing cost / extra windows on `snapshot` from
    /// claude.ai cookie data. Never throws. `prefetched` reuses the race's
    /// losing Web result instead of a second scrape: `.success` merges it,
    /// `.failure` means "already tried — don't rescrape", nil falls back to a
    /// 5s-bounded fetch so a hanging Keychain cookie prompt can't stall the
    /// refresh. Returns the original snapshot unchanged on any failure.
    private static func applyWebExtras(
        to snapshot: ClaudeUsageSnapshot,
        cookieSource: ClaudeCookieSource,
        manualCookie: String?,
        session: URLSession,
        prefetched: Swift.Result<ClaudeWebUsageData, Error>?,
        fetchers: Fetchers
    ) async -> ClaudeUsageSnapshot {
        let hasKnownExtra = snapshot.extraRateWindows.contains(where: \.usageKnown)
        if snapshot.providerCost != nil, hasKnownExtra { return snapshot }
        let web: ClaudeWebUsageData?
        switch prefetched {
        case .success(let data): web = data
        case .failure: return snapshot
        case nil:
            web = await withTaskGroup(of: ClaudeWebUsageData?.self) { group in
                group.addTask {
                    do {
                        return try await fetchers.web(cookieSource, manualCookie, session)
                    } catch { return nil }
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    return nil
                }
                let result = await group.next() ?? nil
                group.cancelAll()
                return result
            }
        }
        guard let web else { return snapshot }
        let mergedExtra = hasKnownExtra ? snapshot.extraRateWindows : web.extraRateWindows
        return ClaudeUsageSnapshot(
            primary: snapshot.primary,
            primaryWindowKind: snapshot.primaryWindowKind,
            secondary: snapshot.secondary,
            opus: snapshot.opus,
            extraRateWindows: mergedExtra,
            providerCost: snapshot.providerCost ?? web.extraUsageCost,
            updatedAt: snapshot.updatedAt,
            accountEmail: snapshot.accountEmail ?? web.accountEmail,
            accountOrganization: snapshot.accountOrganization ?? web.accountOrganization,
            loginMethod: snapshot.loginMethod ?? web.loginMethod,
            rawText: snapshot.rawText,
            adminUsage: snapshot.adminUsage)
    }

    // MARK: - Mappers

    private static func mapWeb(_ d: ClaudeWebUsageData) -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            primary: d.sessionPercentUsed.map {
                RateWindow(usedPercent: $0, windowMinutes: 5 * 60,
                           resetsAt: d.sessionResetsAt, resetDescription: nil)
            },
            secondary: d.weeklyPercentUsed.map {
                RateWindow(usedPercent: $0, windowMinutes: 7 * 24 * 60,
                           resetsAt: d.weeklyResetsAt, resetDescription: nil)
            },
            opus: d.opusPercentUsed.map {
                RateWindow(usedPercent: $0, windowMinutes: 7 * 24 * 60, resetsAt: nil, resetDescription: nil)
            },
            extraRateWindows: d.extraRateWindows,
            providerCost: d.extraUsageCost,
            accountEmail: d.accountEmail,
            accountOrganization: d.accountOrganization,
            loginMethod: d.loginMethod)
    }

    private static func mapCLI(_ s: ClaudeStatusSnapshot) -> ClaudeUsageSnapshot {
        func window(left: Int?, minutes: Int, reset: String?) -> RateWindow? {
            guard let left else { return nil }
            let used = Double(max(0, min(100, 100 - left)))
            return RateWindow(usedPercent: used, windowMinutes: minutes,
                              resetsAt: ClaudeStatusProbe.parseResetDate(from: reset), resetDescription: reset)
        }
        let primary = window(left: s.sessionPercentLeft, minutes: 5 * 60, reset: s.primaryResetDescription)
        return ClaudeUsageSnapshot(
            primary: primary,
            secondary: window(left: s.weeklyPercentLeft, minutes: 7 * 24 * 60, reset: s.secondaryResetDescription),
            opus: window(left: s.opusPercentLeft, minutes: 7 * 24 * 60, reset: s.opusResetDescription),
            accountEmail: s.accountEmail,
            accountOrganization: s.accountOrganization,
            loginMethod: s.loginMethod,
            rawText: s.rawText)
    }

    // MARK: - Settings + credentials

    /// Selected Claude source, defaulting to `.auto` (OAuth → CLI → Web).
    /// Must stay in sync with `SettingsStore.claudeUsageDataSource`, which
    /// backs the Settings picker off the same key — a mismatch would show one
    /// source in the UI while fetching with another.
    ///
    /// `.auto` is the only mode with a fallback chain (`ClaudeFetchPlan
    /// .executionSteps`); every pinned mode runs a single step. That matters
    /// on macOS, where a background poll cannot read the Claude Code Keychain
    /// item under the default `.onlyOnUserAction` prompt policy: pinned
    /// `.oauth` turned that into a hard "not configured" failure, while
    /// `.auto` falls through to the CLI step, which reads the same login via
    /// the `claude` binary's own Keychain ACL.
    static func readDataSource(userDefaults: UserDefaults = .standard) -> ClaudeUsageDataSource {
        let raw = userDefaults.string(forKey: "claudeUsageDataSource") ?? ClaudeUsageDataSource.auto.rawValue
        return ClaudeUsageDataSource(rawValue: raw) ?? .auto
    }

    private static func readCookieSource() -> ClaudeCookieSource {
        let raw = UserDefaults.standard.string(forKey: "claudeCookieSource") ?? ClaudeCookieSource.auto.rawValue
        return ClaudeCookieSource(rawValue: raw) ?? .auto
    }

    private static func readManualCookieHeader() -> String? {
        let raw = UserDefaults.standard.string(forKey: "claudeManualCookieHeader")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty ?? true) ? nil : raw
    }

    /// Admin key from the active admin account, else the environment.
    private static func adminAPIKey() -> String? {
        if let active = ClaudeTokenAccountStore.active(), active.kind == .admin {
            let token = active.token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { return token }
        }
        return ClaudeAdminAPISettingsReader.apiKey()
    }
}
