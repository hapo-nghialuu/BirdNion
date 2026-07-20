import CodexBarCore
import Foundation

/// Token cost rolled up from the local Codex logs.
///
/// Token counts are exact; the dollar amount is an estimate (tokens × a model
/// price table), so it is surfaced as "≈" in the UI.
struct CodexCostSummary: Equatable {
    let todayUSD: Double
    let todayTokens: Int
    /// Totals over the configured history window (default 30 days). The field
    /// name is kept for compatibility; the window length is `historyDays`.
    let last30USD: Double
    let last30Tokens: Int

    var isEmpty: Bool { todayTokens == 0 && last30Tokens == 0 }
}

/// One model's slice of a single Codex day — powers the hover breakdown list.
struct CodexDailyModel: Equatable, Identifiable {
    let name: String
    let usd: Double
    let tokens: Int
    var id: String { name }
}

/// One calendar day (local tz) of Codex usage: exact token sum + estimated USD,
/// plus the per-model split (top 5 by cost) shown in the hover detail row.
struct CodexDailyUsage: Equatable, Identifiable {
    let date: Date
    let usd: Double
    let tokens: Int
    let models: [CodexDailyModel]
    var id: Date { date }
}

/// Full report for the Codex usage chart. Mirrors `ClaudeUsageReport` but the
/// values are mapped to match CodexBar's own inline dashboard exactly:
/// "today" is the most recent **active** day's cost (not the live session), the
/// bars are daily cost, and the top model is the highest-cost one. The daily
/// window spans `CodexCostScanner.chartWindowDays` (120) for the combined
/// heatmap; the `last30*` totals stay strictly 30-day.
struct CodexUsageReport: Equatable {
    /// Most recent active day's estimated cost + exact tokens (CodexBar "Today").
    let todayUSD: Double
    let todayTokens: Int
    /// Strict 30-day totals (summed from the trailing 30 daily buckets).
    let last30USD: Double
    let last30Tokens: Int
    /// `chartWindowDays` daily buckets, oldest → newest; idle days render as a
    /// zero-height bar.
    let daily: [CodexDailyUsage]
    /// Highest-cost model across the window (shortened). nil when none logged.
    let topModel: String?

    var isEmpty: Bool { last30Tokens == 0 }
}

/// Rolls up Codex token cost for "today" and the configured history window.
///
/// Delegates to CodexBarCore's `CostUsageFetcher`, which scans the full set of
/// local Codex log sources (native `~/.codex/sessions` + `archived_sessions`,
/// plus supported pi sessions), uses `turn_context` model markers as the
/// authoritative model bucket, and prices each model. Always scans the system
/// `~/.codex` home — the only place the CLI writes session logs, whichever
/// login is installed. Results are cached briefly so toggling the Settings
/// pane doesn't rescan on every open.
enum CodexCostScanner {
    private static let cacheTTL: TimeInterval = 300
    static let historyDaysKey = "codexCostHistoryDays"
    /// Daily-bucket window for `usageReport` (feeds the 120-day heatmap on the
    /// All tab). Independent of the user-configurable `historyDays`, which
    /// only drives `summary()`.
    static let chartWindowDays = 120

    /// Rolling history window in days (1...365). Defaults to 30 when unset.
    /// `SettingsStore` writes the same key.
    static var historyDays: Int {
        let raw = UserDefaults.standard.integer(forKey: historyDaysKey)
        return raw == 0 ? 30 : max(1, min(365, raw))
    }

    /// Actor-isolated cache so the brief memoization is safe across tasks.
    private actor Cache {
        static let shared = Cache()
        private var entry: (at: Date, value: CodexCostSummary)?
        private var reportEntry: (at: Date, value: CodexUsageReport)?
        func valid(now: Date, ttl: TimeInterval) -> CodexCostSummary? {
            guard let entry, now.timeIntervalSince(entry.at) < ttl else { return nil }
            return entry.value
        }
        func store(_ value: CodexCostSummary, at: Date) { entry = (at, value) }
        func validReport(now: Date, ttl: TimeInterval) -> CodexUsageReport? {
            guard let reportEntry, now.timeIntervalSince(reportEntry.at) < ttl else { return nil }
            return reportEntry.value
        }
        func storeReport(_ value: CodexUsageReport, at: Date) { reportEntry = (at, value) }
    }

    /// Cached, off-main scan. Returns nil only when the scan throws (e.g. no
    /// readable log sources).
    static func summary(now: Date = Date()) async -> CodexCostSummary? {
        if let cached = await Cache.shared.valid(now: now, ttl: cacheTTL) { return cached }
        // Always scan the real CLI home (~/.codex): every terminal `codex`
        // session logs there regardless of which login is installed, and
        // managed homes only ever hold auth.json (no session history). Scoping
        // to the viewed account made freshly-added accounts show an empty
        // chart and zero out the All-tab Codex column.
        let codexHome = CodexAccountStore.systemAuthURL().deletingLastPathComponent().path
        guard let snapshot = try? await CostUsageFetcher().loadTokenSnapshot(
            provider: .codex,
            now: now,
            codexHomePath: codexHome,
            historyDays: historyDays)
        else { return nil }
        let value = map(snapshot)
        await Cache.shared.store(value, at: now)
        return value
    }

    /// Pure mapping (snapshot → BirdNion model), unit-testable. "session" totals
    /// are today's; "last30Days" totals span the configured window.
    static func map(_ snapshot: CostUsageTokenSnapshot) -> CodexCostSummary {
        CodexCostSummary(
            todayUSD: snapshot.sessionCostUSD ?? 0,
            todayTokens: snapshot.sessionTokens ?? 0,
            last30USD: snapshot.last30DaysCostUSD ?? 0,
            last30Tokens: snapshot.last30DaysTokens ?? 0)
    }

    // MARK: - Full report (chart)

    /// Cached, off-main full report: 30-day totals + 120-day per-day series for
    /// the usage chart/heatmap. Returns nil only when the scan throws.
    static func usageReport(now: Date = Date()) async -> CodexUsageReport? {
        if let cached = await Cache.shared.validReport(now: now, ttl: cacheTTL) { return cached }
        // Same as `summary()`: the machine-wide ~/.codex is the only place
        // session logs actually accumulate.
        let codexHome = CodexAccountStore.systemAuthURL().deletingLastPathComponent().path
        // Only rescan days that can still change persisted history; the
        // store supplies the older days.
        let scanDays = CostHistoryStore.scanBackDays(source: .codex, now: now)
        let snapshot = try? await CostUsageFetcher().loadTokenSnapshot(
            provider: .codex,
            now: now,
            codexHomePath: codexHome,
            historyDays: scanDays)
        let live = snapshot.map { mapReport($0, now: now) }
        let liveDays = (live?.daily ?? []).map {
            ($0.date, $0.usd, $0.tokens,
             $0.models.map { (name: $0.name, usd: $0.usd, tokens: $0.tokens) })
        }
        let window = CostHistoryStore.apply(
            source: .codex,
            liveDays: liveDays,
            now: now,
            windowDays: chartWindowDays)
        let value = CostHistoryStore.makeCodexReport(window: window, now: now)
        // Persist high-water days even when the live snapshot fails / is empty
        // (e.g. user deleted ~/.codex/sessions after a prior successful scan).
        if value.isEmpty && live == nil {
            return nil
        }
        await Cache.shared.storeReport(value, at: now)
        return value
    }

    /// Instant chart seed from persisted history — no log scan. Nil when the
    /// store has nothing for Codex so callers keep their loading skeleton.
    /// Deliberately not stored in `Cache`: a cached seed would mask the live
    /// scan for the whole TTL.
    static func seededReport(now: Date = Date(),
                             url: URL = CostHistoryStore.historyURL()) async -> CodexUsageReport? {
        await Task.detached(priority: .userInitiated) {
            let window = CostHistoryStore.window(
                source: .codex, now: now, windowDays: chartWindowDays, url: url)
            guard window.contains(where: { $0.tokens > 0 || $0.usd > 0 }) else { return nil }
            return CostHistoryStore.makeCodexReport(window: window, now: now)
        }.value
    }

    /// Pure mapping (snapshot → chart report), unit-testable. Mirrors CodexBar's
    /// inline dashboard: bars + per-model breakdown are rolled up from
    /// `snapshot.daily` (cost per day), "today" is the most recent active day,
    /// the 30-day token total falls back to the daily sum, and the top model is
    /// the highest-cost one.
    static func mapReport(_ snapshot: CostUsageTokenSnapshot, now: Date = Date()) -> CodexUsageReport {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        // First day of the strict-30 window (today counts as day 30).
        let last30Start = calendar.date(byAdding: .day, value: -29, to: startOfToday)
            ?? startOfToday.addingTimeInterval(-29 * 86_400)

        var buckets: [Date: DailyAccumulator] = [:]
        // Summed cost+tokens per model over the trailing 30 days → top model.
        // Gated to 30d (not the full 120d bucket window) so the Codex tab's
        // top-model line keeps its pre-heatmap value.
        var modelTotals: [String: (cost: Double, tokens: Int)] = [:]

        for entry in snapshot.daily {
            guard let parsed = parseDay(entry.date) else { continue }
            let day = calendar.startOfDay(for: parsed)
            let acc = buckets[day] ?? DailyAccumulator()
            acc.usd += entry.costUSD ?? 0
            acc.tokens += entry.totalTokens ?? 0
            for mb in entry.modelBreakdowns ?? [] {
                var m = acc.models[mb.modelName] ?? (usd: 0, tokens: 0)
                m.usd += mb.costUSD ?? 0
                m.tokens += mb.totalTokens ?? 0
                acc.models[mb.modelName] = m
                guard day >= last30Start else { continue }
                var total = modelTotals[mb.modelName] ?? (cost: 0, tokens: 0)
                total.cost += mb.costUSD ?? 0
                total.tokens += mb.totalTokens ?? 0
                modelTotals[mb.modelName] = total
            }
            buckets[day] = acc
        }

        let daily = makeDailyBuckets(buckets: buckets, endDay: startOfToday, count: chartWindowDays)
        // Strict 30-day slice for the totals + "today" — the wider window only
        // exists for the heatmap, the Codex tab numbers must not move with it.
        let last30 = daily.suffix(30)
        let latest = last30.last(where: { $0.tokens > 0 })
        let topModel = modelTotals.max {
            $0.value.cost == $1.value.cost
                ? $0.value.tokens < $1.value.tokens
                : $0.value.cost < $1.value.cost
        }?.key

        return CodexUsageReport(
            todayUSD: latest?.usd ?? 0,
            todayTokens: latest?.tokens ?? 0,
            last30USD: last30.map(\.usd).reduce(0, +),
            last30Tokens: last30.map(\.tokens).reduce(0, +),
            daily: daily,
            topModel: topModel.map(shortModelName))
    }

    /// In-place per-day accumulator (reference type so dictionary updates don't
    /// re-box on every entry).
    private final class DailyAccumulator {
        var usd: Double = 0
        var tokens: Int = 0
        var models: [String: (usd: Double, tokens: Int)] = [:]
    }

    /// Contiguous N-day bucket array (oldest → newest) so the chart has a slot
    /// for every day even when no activity was logged. Per-model rows are sorted
    /// by cost (top 5), matching CodexBar's day detail.
    private static func makeDailyBuckets(
        buckets: [Date: DailyAccumulator], endDay: Date, count: Int
    ) -> [CodexDailyUsage] {
        let calendar = Calendar.current
        var result: [CodexDailyUsage] = []
        var cursor = endDay
        for _ in 0..<count {
            let acc = buckets[cursor]
            let models: [CodexDailyModel] = (acc?.models ?? [:])
                .filter { $0.value.tokens > 0 || $0.value.usd > 0 }
                .map { CodexDailyModel(name: $0.key, usd: $0.value.usd, tokens: $0.value.tokens) }
                .sorted { $0.usd > $1.usd }
                .prefix(5)
                .map { $0 }
            result.append(CodexDailyUsage(
                date: cursor, usd: acc?.usd ?? 0, tokens: acc?.tokens ?? 0, models: models))
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)
                ?? cursor.addingTimeInterval(-86_400)
        }
        return result.reversed()
    }

    /// CodexBar's daily `date` is a "yyyy-MM-dd" day string; fall back to ISO8601
    /// for any source that carries a time component. nil when neither parses.
    private static func parseDay(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = dayFormatter.date(from: trimmed) { return d }
        return ISO8601DateFormatter().date(from: trimmed)
    }

    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    /// Trim very long model names for the top-model line (CodexBar parity).
    private static func shortModelName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 26 else { return trimmed }
        return String(trimmed.prefix(25)) + "…"
    }
}
