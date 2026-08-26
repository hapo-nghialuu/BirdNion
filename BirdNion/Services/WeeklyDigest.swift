import Foundation

/// Rolling 7-day cost/token digest notification. Same shape as
/// `QuotaWarnConfig`/`CodexQuotaPrimer` (see `QuotaService.swift` and
/// `CodexAccountStore.swift`): UserDefaults-backed settings + a pure
/// decision/model layer + a thin async wiring `tick` called once per
/// refresh pass (`QuotaService.runWeeklyDigestIfDue`). No new
/// Timer/daemon/polling loop — reuses the existing refresh cadence and the
/// existing Claude/Codex/Grok cost scanners, which already cache their own
/// scans for a few minutes.
///
/// "Rolling 7 days" here is NOT an ISO week or a fixed weekday: it is today
/// plus the 6 prior calendar days, compared against the 7 days immediately
/// before that. This matches the Linux implementation and the user-facing
/// wording "7 days ago" while still using day-granularity scanner data.
enum WeeklyDigest {

    // MARK: - Settings (UserDefaults; mirrors CodexQuotaPrimer's key style)

    /// Off by default — a digest notification can surface cost/token
    /// numbers outside the popover, which not every user wants visible on
    /// their lock screen / Notification Center.
    static let enabledKey = "weeklyDigestEnabled"
    private static let lastEvaluatedAtKey = "weeklyDigestLastEvaluatedAt"
    private static let lastSentAtKey = "weeklyDigestLastSentAt"
    /// Stable id so a future re-send replaces rather than stacks in
    /// Notification Center.
    static let notificationID = "weeklyDigest.summary"
    private static let cadence: TimeInterval = 7 * 24 * 3600

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// When the digest was last evaluated (sent OR suppressed). `nil` means
    /// never evaluated — always due, so enabling the toggle sends on the
    /// very next refresh pass instead of waiting a further 7 days.
    static var lastEvaluatedAt: Date? {
        get {
            let v = UserDefaults.standard.double(forKey: lastEvaluatedAtKey)
            return v > 0 ? Date(timeIntervalSince1970: v) : nil
        }
        set {
            UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: lastEvaluatedAtKey)
        }
    }

    /// When the OS notification was last actually queued successfully.
    /// Distinct from `lastEvaluatedAt`: a denied/errored post still advances
    /// the evaluation cadence but never this timestamp.
    static var lastSentAt: Date? {
        get {
            let v = UserDefaults.standard.double(forKey: lastSentAtKey)
            return v > 0 ? Date(timeIntervalSince1970: v) : nil
        }
        set {
            UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: lastSentAtKey)
        }
    }

    /// Shared with the All-tab forecast card (`SettingsStore.monthlyBudgetUSD`).
    /// 0 means "not configured" — `MonthlyForecast.build` normalizes that to
    /// a hidden budget on its own.
    static var budgetUSD: Double {
        UserDefaults.standard.double(forKey: "monthlyBudgetUSD")
    }

    static var budgetPeriod: BudgetPeriod {
        let raw = UserDefaults.standard.string(forKey: "birdnion.budgetPeriod")
        return raw.flatMap(BudgetPeriod.init(rawValue:)) ?? .week
    }

    /// Per-source budgets — same keys `SettingsStore`'s `@AppStorage` writes,
    /// same "0 =
    /// not configured" convention as `budgetUSD` above. Used as `evaluate`'s
    /// default arguments (mirrors the existing `now: Date = Date()` pattern)
    /// so the real `QuotaService` call site — which only ever passes the
    /// combined `budgetUSD` — still picks up per-provider budgets for free,
    /// while tests stay deterministic by passing explicit values.
    static var claudeBudgetUSD: Double {
        UserDefaults.standard.double(forKey: "claudeBudgetUSD")
    }
    static var codexBudgetUSD: Double {
        UserDefaults.standard.double(forKey: "codexBudgetUSD")
    }
    static var grokBudgetUSD: Double {
        UserDefaults.standard.double(forKey: "grokBudgetUSD")
    }
    static var kiroBudgetUSD: Double {
        UserDefaults.standard.double(forKey: "kiroBudgetUSD")
    }
    static var ompBudgetUSD: Double {
        UserDefaults.standard.double(forKey: "ompBudgetUSD")
    }
    static var piBudgetUSD: Double {
        UserDefaults.standard.double(forKey: "piBudgetUSD")
    }

    /// Pure cadence gate — no ambient `Date()`, so it is directly testable.
    static func isDue(now: Date, lastEvaluatedAt: Date?) -> Bool {
        guard let lastEvaluatedAt else { return true }
        return now.timeIntervalSince(lastEvaluatedAt) >= cadence
    }

    // MARK: - Pure model

    enum SourceID: String, CaseIterable, Equatable, Sendable {
        case claude, codex, grok, kiro, omp, pi

        var displayName: String {
            switch self {
            case .claude: return "Claude"
            case .codex: return "Codex"
            case .grok: return "Grok"
            case .kiro: return "Kiro"
            case .omp: return "Oh My Pi"
            case .pi: return "Pi"
            }
        }
    }

    /// One provider whose own budget is configured and forecast-over or
    /// already-over this cycle. Never built for an unavailable source (see
    /// `evaluate`'s trust-rule gate) and never for `.onTrack` — the digest
    /// only calls out risk, keeping the notification concise.
    struct ProviderBudgetRisk: Equatable {
        let source: SourceID
        let status: MonthlyForecastStatus
        let monthToDateUSD: Double
        let projectedTotalUSD: Double
        let budgetUSD: Double
    }

    /// Deterministic outcome of one evaluation pass. `shouldSend == false`
    /// still means the evaluation ran — the caller stamps `lastEvaluatedAt`
    /// either way so a suppressed week doesn't rescan on every refresh.
    struct Evaluation: Equatable {
        let shouldSend: Bool
        let currentUSD: Double
        let currentTokens: Int
        let priorUSD: Double
        let priorTokens: Int
        /// `nil` when `priorUSD <= 0` — a percent change against zero isn't
        /// meaningful and would read as a misleading spike.
        let changePercent: Double?
        let topSource: SourceID?
        let topModel: CombinedModelCost?
        let forecast: MonthlyForecast
        /// Enabled sources whose confidence is history-only or unavailable
        /// this cycle (i.e. not a live scan) — surfaced as a short caveat.
        let nonLiveSources: [SourceID]
        /// Configured providers forecast-over or already-over their own
        /// budget this cycle — never includes an unavailable source.
        let providerBudgetRisks: [ProviderBudgetRisk]
        let title: String
        let body: String
    }

    /// Shared rolling-window projection for the digest and Usage Insights.
    /// Keeping this pure prevents the two surfaces from drifting on week math.
    struct Pulse: Equatable, Sendable {
        let currentUSD: Double
        let currentTokens: Int
        let priorUSD: Double
        let priorTokens: Int
        let changePercent: Double?
        let topSource: SourceID?
        let topModel: CombinedModelCost?
    }

    /// Splits `daily` into today + 6 prior calendar days and the 7 days
    /// immediately before that. Date boundaries are explicit so sparse or
    /// unexpectedly ordered input cannot turn "7 days" into "7 records".
    static func rollingWindows(
        daily: [CombinedDailyUsage], now: Date, calendar: Calendar = .current
    ) -> (current: [CombinedDailyUsage], prior: [CombinedDailyUsage]) {
        let startOfToday = calendar.startOfDay(for: now)
        guard let currentStart = calendar.date(byAdding: .day, value: -6, to: startOfToday),
              let priorStart = calendar.date(byAdding: .day, value: -13, to: startOfToday)
        else { return ([], []) }
        let current = daily.filter { $0.date >= currentStart && $0.date <= startOfToday }
        let prior = daily.filter { $0.date >= priorStart && $0.date < currentStart }
        return (current, prior)
    }

    private static func totals(_ window: [CombinedDailyUsage]) -> (usd: Double, tokens: Int) {
        (window.reduce(0) { $0 + $1.usd }, window.reduce(0) { $0 + $1.tokens })
    }

    static func changePercent(currentUSD: Double, priorUSD: Double) -> Double? {
        guard priorUSD > 0 else { return nil }
        return (currentUSD - priorUSD) / priorUSD * 100
    }

    static func pulse(
        daily: [CombinedDailyUsage], now: Date, calendar: Calendar = .current
    ) -> Pulse {
        let windows = rollingWindows(daily: daily, now: now, calendar: calendar)
        let current = totals(windows.current)
        let prior = totals(windows.prior)
        return Pulse(
            currentUSD: current.usd, currentTokens: current.tokens,
            priorUSD: prior.usd, priorTokens: prior.tokens,
            changePercent: changePercent(currentUSD: current.usd, priorUSD: prior.usd),
            topSource: topSource(in: windows.current),
            topModel: topModel(in: windows.current))
    }

    /// Highest-usage source in `window`, tie-broken by tokens → USD → id
    /// name (ascending) for full determinism. `nil` when every source is at
    /// zero (disabled sources are already zeroed by `CombinedUsageReport`).
    static func topSource(in window: [CombinedDailyUsage]) -> SourceID? {
        let sums: [(SourceID, Double, Int)] = [
            (.claude, window.reduce(0) { $0 + $1.claudeUSD }, window.reduce(0) { $0 + $1.claudeTokens }),
            (.codex, window.reduce(0) { $0 + $1.codexUSD }, window.reduce(0) { $0 + $1.codexTokens }),
            (.grok, window.reduce(0) { $0 + $1.grokUSD }, window.reduce(0) { $0 + $1.grokTokens }),
            (.kiro, window.reduce(0) { $0 + $1.kiroUSD }, window.reduce(0) { $0 + $1.kiroTokens }),
            (.omp, window.reduce(0) { $0 + $1.ompUSD }, window.reduce(0) { $0 + $1.ompTokens }),
            (.pi, window.reduce(0) { $0 + $1.piUSD }, window.reduce(0) { $0 + $1.piTokens }),
        ]
        let active = sums.filter { $0.1 > 0 || $0.2 > 0 }
        guard !active.isEmpty else { return nil }
        return active.sorted {
            if $0.2 != $1.2 { return $0.2 > $1.2 }
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.rawValue < $1.0.rawValue
        }.first?.0
    }

    private struct ModelKey: Hashable {
        let source: String
        let name: String
    }

    /// Highest-usage model across `window`, folded by name+source, tie-broken
    /// by tokens → USD → name (ascending).
    static func topModel(in window: [CombinedDailyUsage]) -> CombinedModelCost? {
        var folded: [ModelKey: (usd: Double, tokens: Int)] = [:]
        for day in window {
            for m in day.models {
                if m.source == SourceID.kiro.rawValue,
                   m.name == KiroCostScanner.aggregateModelName { continue }
                let key = ModelKey(source: m.source, name: m.name)
                var v = folded[key] ?? (0, 0)
                v.usd += m.usd
                v.tokens += m.tokens
                folded[key] = v
            }
        }
        let candidates: [CombinedModelCost] = folded.compactMap { key, v in
            guard v.usd > 0 || v.tokens > 0 else { return nil }
            return CombinedModelCost(name: key.name, usd: v.usd, tokens: v.tokens, source: key.source)
        }
        return candidates.sorted {
            if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
            if $0.usd != $1.usd { return $0.usd > $1.usd }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.source < $1.source
        }.first
    }

    /// Strips control characters/newlines and clamps length so free-text
    /// pulled from raw session logs (model ids) can never inject unbounded
    /// or unprintable content into a notification body.
    static func sanitizeLabel(_ raw: String, maxLength: Int = 40) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars
        where !CharacterSet.controlCharacters.contains(scalar) && !CharacterSet.newlines.contains(scalar) {
            scalars.append(scalar)
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespaces)
        guard cleaned.count > maxLength else { return cleaned }
        return String(cleaned.prefix(maxLength)) + "…"
    }

    // MARK: - Evaluate (pure — no I/O, no ambient Date())

    /// Builds the full decision + localized copy from already-fetched
    /// reports. Reuses `CombinedUsageReport` (day merge/source gating) and
    /// `MonthlyForecast` (budget/forecast) rather than re-deriving them.
    static func evaluate(
        claude: ClaudeUsageReport?,
        codex: CodexUsageReport?,
        grok: GrokUsageReport?,
        kiro: KiroUsageReport? = nil,
        omp: OMPUsageReport? = nil,
        pi: PiUsageReport? = nil,
        includeClaude: Bool,
        includeCodex: Bool,
        includeGrok: Bool,
        includeKiro: Bool = false,
        includeOMP: Bool = false,
        includePi: Bool = false,
        budgetUSD: Double?,
        budgetPeriod: BudgetPeriod = .week,
        claudeBudgetUSD: Double? = WeeklyDigest.claudeBudgetUSD,
        codexBudgetUSD: Double? = WeeklyDigest.codexBudgetUSD,
        grokBudgetUSD: Double? = WeeklyDigest.grokBudgetUSD,
        kiroBudgetUSD: Double? = WeeklyDigest.kiroBudgetUSD,
        ompBudgetUSD: Double? = WeeklyDigest.ompBudgetUSD,
        piBudgetUSD: Double? = WeeklyDigest.piBudgetUSD,
        now: Date = Date(),
        calendar: Calendar = .current,
        language: String? = nil
    ) -> Evaluation {
        let combined = CombinedUsageReport.build(
            claude: claude, codex: codex, grok: grok,
            kiro: kiro, omp: omp, pi: pi,
            includeClaude: includeClaude, includeCodex: includeCodex, includeGrok: includeGrok,
            includeKiro: includeKiro, includeOMP: includeOMP, includePi: includePi,
            calendar: calendar, now: now)
        let pulse = pulse(daily: combined.daily, now: now, calendar: calendar)

        let confidences: [(SourceID, Bool, CostHistoryStore.UsageScanConfidence?)] = [
            (.claude, includeClaude, combined.claudeConfidence),
            (.codex, includeCodex, combined.codexConfidence),
            (.grok, includeGrok, combined.grokConfidence),
            (.kiro, includeKiro, combined.kiroConfidence),
            (.omp, includeOMP, combined.ompConfidence),
            (.pi, includePi, combined.piConfidence),
        ]
        let hasLiveSource = confidences.contains { $0.1 && $0.2?.live == true }
        let hasActivity = pulse.currentUSD > 0 || pulse.currentTokens > 0
        let shouldSend = hasLiveSource && hasActivity
        let nonLiveSources = confidences
            .filter { $0.1 && $0.2?.live != true }
            .map(\.0)

        let forecast = MonthlyForecast.build(
            daily: combined.daily,
            budgetUSD: budgetUSD,
            period: budgetPeriod,
            now: now,
            calendar: calendar)

        // Trust rule: a provider whose confidence is `nil` or `included ==
        // false` (disabled, or never landed a scan) never contributes a risk
        // line from an implicit-zero forecast — only `.claude`/`.codex`/
        // source confidence with `included == true` (live OR history-only)
        // may calculate. `.onTrack` is intentionally excluded too — the
        // digest only calls out risk.
        let providerBudgetInputs: [(SourceID, CostHistoryStore.UsageScanConfidence?, Double?, CombinedUsageSource)] = [
            (.claude, combined.claudeConfidence, claudeBudgetUSD, .claude),
            (.codex, combined.codexConfidence, codexBudgetUSD, .codex),
            (.grok, combined.grokConfidence, grokBudgetUSD, .grok),
            (.kiro, combined.kiroConfidence, kiroBudgetUSD, .kiro),
            (.omp, combined.ompConfidence, ompBudgetUSD, .omp),
            (.pi, combined.piConfidence, piBudgetUSD, .pi),
        ]
        let providerBudgetRisks: [ProviderBudgetRisk] = providerBudgetInputs.compactMap { source, confidence, budget, usageSource in
            guard let confidence, confidence.included else { return nil }
            guard let budget, budget.isFinite, budget > 0 else { return nil }
            let providerForecast = MonthlyForecast.build(
                daily: combined.daily,
                budgetUSD: budget,
                period: budgetPeriod,
                source: usageSource,
                now: now,
                calendar: calendar)
            guard let status = providerForecast.status, status != .onTrack else { return nil }
            return ProviderBudgetRisk(
                source: source, status: status,
                monthToDateUSD: providerForecast.monthToDateUSD,
                projectedTotalUSD: providerForecast.projectedTotalUSD, budgetUSD: budget)
        }

        let title = L10n.t("weeklyDigest.title", language)
        let body = shouldSend
            ? Self.body(currentUSD: pulse.currentUSD, currentTokens: pulse.currentTokens,
                       changePercent: pulse.changePercent, topSource: pulse.topSource,
                       topModel: pulse.topModel,
                       forecast: forecast, nonLiveSources: nonLiveSources,
                       providerBudgetRisks: providerBudgetRisks, language: language)
            : ""

        return Evaluation(
            shouldSend: shouldSend,
            currentUSD: pulse.currentUSD, currentTokens: pulse.currentTokens,
            priorUSD: pulse.priorUSD, priorTokens: pulse.priorTokens,
            changePercent: pulse.changePercent,
            topSource: pulse.topSource, topModel: pulse.topModel,
            forecast: forecast, nonLiveSources: nonLiveSources,
            providerBudgetRisks: providerBudgetRisks,
            title: title, body: body)
    }

    /// Assembles the localized body from short independent fragments (vs.
    /// one giant format string) so change%, top model, forecast/budget, and
    /// the non-live caveat can each be present or absent without breaking
    /// the sentence in either language.
    private static func body(
        currentUSD: Double, currentTokens: Int,
        changePercent: Double?, topSource: SourceID?, topModel: CombinedModelCost?,
        forecast: MonthlyForecast, nonLiveSources: [SourceID],
        providerBudgetRisks: [ProviderBudgetRisk], language: String?
    ) -> String {
        var parts: [String] = []
        parts.append(L10n.f("weeklyDigest.body.totals", language,
                            AllUsageFormat.usd(currentUSD), AllUsageFormat.tokens(currentTokens)))
        if let changePercent {
            let key = changePercent >= 0 ? "weeklyDigest.body.change.up" : "weeklyDigest.body.change.down"
            parts.append(L10n.f(key, language, abs(changePercent)))
        }
        if let topSource {
            parts.append(L10n.f("weeklyDigest.body.topSource", language, topSource.displayName))
        }
        if let topModel {
            let name = sanitizeLabel(AllUsageFormat.shortName(topModel.name))
            parts.append(L10n.f("weeklyDigest.body.topModel", language, name))
        }
        if let budgetUSD = forecast.budgetUSD, budgetUSD > 0, let status = forecast.status {
            parts.append(L10n.f(
                "weeklyDigest.body.forecast", language,
                AllUsageFormat.usd(forecast.projectedTotalUSD)))
            let key: String
            switch status {
            case .onTrack: key = "weeklyDigest.body.budget.onTrack"
            case .forecastOver: key = "weeklyDigest.body.budget.forecastOver"
            case .alreadyOver: key = "weeklyDigest.body.budget.alreadyOver"
            }
            parts.append(L10n.f(key, language, AllUsageFormat.usd(forecast.monthToDateUSD), AllUsageFormat.usd(budgetUSD)))
        }
        if !nonLiveSources.isEmpty {
            let names = nonLiveSources.map(\.displayName).joined(separator: ", ")
            parts.append(L10n.f("weeklyDigest.body.caveat", language, names))
        }
        for risk in providerBudgetRisks {
            // `.onTrack` never reaches this loop (filtered out when the risk
            // list is built), so `.alreadyOver` reports actual month-to-date
            // spend while `.forecastOver` reports the projected total.
            let key = risk.status == .alreadyOver
                ? "weeklyDigest.body.providerBudget.alreadyOver"
                : "weeklyDigest.body.providerBudget.forecastOver"
            let amountUSD = risk.status == .alreadyOver ? risk.monthToDateUSD : risk.projectedTotalUSD
            parts.append(L10n.f(key, language, risk.source.displayName,
                                AllUsageFormat.usd(amountUSD), AllUsageFormat.usd(risk.budgetUSD)))
        }
        return parts.joined(separator: " ")
    }
}
