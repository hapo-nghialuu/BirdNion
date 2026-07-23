import Foundation
import CodexBarCore

// MARK: - Models

/// Token cost rolled up from local Grok Build CLI session signals
/// (`~/.grok/sessions/**/signals.json`). Token counts come from the session
/// signal file; USD is a blended estimate (tokens × model price table with a
/// 75% input / 25% output mix — local logs do not split in/out).
struct GrokCostSummary: Equatable {
    let todayUSD: Double
    let todayTokens: Int
    let last30USD: Double
    let last30Tokens: Int

    var isEmpty: Bool { todayTokens == 0 && last30Tokens == 0 }
}

struct GrokDailyModel: Equatable, Identifiable {
    let name: String
    let usd: Double
    let tokens: Int
    var id: String { name }
}

struct GrokDailyUsage: Equatable, Identifiable {
    let date: Date
    let usd: Double
    let tokens: Int
    let models: [GrokDailyModel]
    var id: Date { date }
}

/// Full report for the All-tab heatmap/chart. Shape mirrors
/// `CodexUsageReport` / `ClaudeUsageReport`.
struct GrokUsageReport: Equatable {
    let todayUSD: Double
    let todayTokens: Int
    let last30USD: Double
    let last30Tokens: Int
    /// Contiguous `chartWindowDays` daily buckets, oldest → newest.
    let daily: [GrokDailyUsage]
    let topModel: String?

    /// Empty only when there is neither spend nor tokens in the 30-day window
    /// (usd alone still warrants a chart card).
    var isEmpty: Bool { last30Tokens == 0 && last30USD <= 0 && todayTokens == 0 && todayUSD <= 0 }

    var asSummary: GrokCostSummary {
        GrokCostSummary(todayUSD: todayUSD, todayTokens: todayTokens,
                        last30USD: last30USD, last30Tokens: last30Tokens)
    }
}

// MARK: - Pricing

/// Per-million-token prices (USD) for xAI Grok models.
/// Sources: docs.x.ai pricing (2026-07). Local logs lack in/out split, so the
/// scanner blends 75% input / 25% output for agent-style sessions.
struct GrokModelPrice {
    let inputPerM: Double
    let outputPerM: Double

    /// Blended $/M for sessions that only expose a single token total.
    var blendedPerM: Double { 0.75 * inputPerM + 0.25 * outputPerM }

    static func price(for model: String) -> GrokModelPrice {
        let m = model.lowercased()
        // Flagship Grok 4.5 — $2 / $6
        if m.contains("grok-4.5") || m.contains("grok-4-5") {
            return GrokModelPrice(inputPerM: 2.0, outputPerM: 6.0)
        }
        // Fast tiers — $0.20 / $0.50
        if m.contains("fast") {
            if m.contains("code") {
                return GrokModelPrice(inputPerM: 0.20, outputPerM: 1.50)
            }
            return GrokModelPrice(inputPerM: 0.20, outputPerM: 0.50)
        }
        // Grok 4.3 / 4.20 family — $1.25 / $2.50
        if m.contains("grok-4.3") || m.contains("grok-4-3")
            || m.contains("grok-4.20") || m.contains("grok-4-20")
        {
            return GrokModelPrice(inputPerM: 1.25, outputPerM: 2.50)
        }
        // Legacy grok-4 (non-fast) — $3 / $15
        if m.contains("grok-4") {
            return GrokModelPrice(inputPerM: 3.0, outputPerM: 15.0)
        }
        // grok-build / coding default — treat as code-fast-ish mid tier
        if m.contains("build") || m.contains("code") {
            return GrokModelPrice(inputPerM: 1.0, outputPerM: 2.0)
        }
        // Unknown — use Grok 4.5 rates so estimates stay conservative-visible.
        return GrokModelPrice(inputPerM: 2.0, outputPerM: 6.0)
    }

    static func estimateUSD(tokens: Int, model: String) -> Double {
        guard tokens > 0 else { return 0 }
        return Double(tokens) / 1_000_000.0 * price(for: model).blendedPerM
    }
}

// MARK: - Per-session max-seen baseline

/// Persists the highest lifetime token total (`before + context`) seen per
/// Grok session so each scan only attributes the **delta** to the session's
/// current last-active day. Without this, multi-day sessions re-count their
/// full lifetime total every day they stay active (CostHistoryStore high-water
/// then keeps the inflated older days forever).
///
/// Baseline is max-seen (never decreases): `T = before + context` can dip after
/// compaction, so a non-monotonic T must not produce negative deltas or
/// re-count recovery tokens.
///
/// File: Application Support `BirdNion/grok-session-baselines.json`, atomic
/// write + 0600. Tests inject a temp `url:`.
enum GrokSessionBaselineStore {
    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("BirdNion", isDirectory: true)
            .appendingPathComponent("grok-session-baselines.json")
    }

    /// Load session-key → max-seen lifetime total. Empty when missing/corrupt.
    static func load(url: URL = defaultURL()) -> [String: Int] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = json["sessions"] as? [String: Any]
        else { return [:] }
        var out: [String: Int] = [:]
        out.reserveCapacity(sessions.count)
        for (key, raw) in sessions {
            switch raw {
            case let i as Int: out[key] = i
            case let n as NSNumber: out[key] = n.intValue
            case let d as Double: out[key] = Int(d)
            default: break
            }
        }
        return out
    }

    /// Persist baselines, keeping only keys in `keepKeys` so deleted sessions
    /// do not inflate the file forever. Empty `keepKeys` writes an empty map.
    static func save(_ sessions: [String: Int],
                     keepKeys: Set<String>,
                     url: URL = defaultURL()) {
        var pruned: [String: Int] = [:]
        pruned.reserveCapacity(keepKeys.count)
        for key in keepKeys {
            if let v = sessions[key] { pruned[key] = v }
        }
        let payload: [String: Any] = ["sessions": pruned]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - Scanner

/// Walks `~/.grok/sessions/**/signals.json` (path overridable via `GROK_HOME`)
/// and builds a 120-day daily cost report for the All tab.
///
/// Each session signal file only exposes a **lifetime** token snapshot
/// (`totalTokensBeforeCompaction + contextTokensUsed`), overwritten in place
/// with no time series. Attribution is therefore **per-session delta** against
/// `GrokSessionBaselineStore` (max-seen T); only growth since the last scan is
/// charged to the session's current last-active calendar day. Past days already
/// live in `CostHistoryStore`.
enum GrokCostScanner {
    private static let cacheTTL: TimeInterval = 300
    static let chartWindowDays = 120
    /// Bump when Grok counting semantics change. Existing persisted days need
    /// one full rescan; `usageReport` then applies with `replacingSource: true`
    /// so inflated high-water marks are replaced atomically by the fresh
    /// delta-based scan (never an empty source on disk mid-flight).
    static let countingRevision = 1
    private static let countingRevisionKey = "grokCostCountingRevision"

    private actor Cache {
        static let shared = Cache()
        private var reportEntry: (at: Date, value: GrokUsageReport)?
        func validReport(now: Date, ttl: TimeInterval) -> GrokUsageReport? {
            guard let reportEntry, now.timeIntervalSince(reportEntry.at) < ttl else { return nil }
            return reportEntry.value
        }
        func storeReport(_ value: GrokUsageReport, at: Date) { reportEntry = (at, value) }
    }

    /// Cached full report (120 daily buckets + strict 30-day totals).
    /// Merges with `CostHistoryStore` so deleted `~/.grok/sessions` do not
    /// wipe past All-tab bars.
    static func usageReport(now: Date = Date()) async -> GrokUsageReport? {
        if let cached = await Cache.shared.validReport(now: now, ttl: cacheTTL) { return cached }
        let value = await Task.detached(priority: .utility) {
            // Only rescan days that can still change persisted history; the
            // store supplies the older days. On a counting-revision bump, scan
            // the full chart window once so `replacingSource` can rebuild
            // every day from clean deltas (baselines still empty → full
            // lifetime once per session at last-active).
            let incrementalDays = CostHistoryStore.scanBackDays(source: .grok, now: now)
            let storedRevision = UserDefaults.standard.integer(forKey: countingRevisionKey)
            let replacing = storedRevision < countingRevision
            // A revision bump must also restart the per-session baselines:
            // max-seen totals left over from the previous counting scheme
            // would shrink every delta to ~0, and `replacingSource` below
            // would then rebuild the whole history from near-empty days.
            // Clearing first makes the full-window rescan re-charge each
            // session's lifetime exactly once at its last-active day.
            if replacing {
                GrokSessionBaselineStore.save([:], keepKeys: [])
            }
            let scanDays = replacing ? chartWindowDays : incrementalDays
            let live = scanFull(now: now, windowDays: scanDays)
            let liveDays = live.daily.map {
                ($0.date, $0.usd, $0.tokens,
                 $0.models.map { (name: $0.name, usd: $0.usd, tokens: $0.tokens) })
            }
            // Live scan always succeeds for Grok (`scanFull` never returns nil).
            let window = CostHistoryStore.apply(
                source: .grok,
                liveDays: liveDays,
                now: now,
                windowDays: chartWindowDays,
                replacingSource: replacing)
            UserDefaults.standard.set(countingRevision, forKey: countingRevisionKey)
            return CostHistoryStore.makeGrokReport(window: window)
        }.value
        await Cache.shared.storeReport(value, at: now)
        return value
    }

    /// Instant chart seed from persisted history — no session scan. Nil when
    /// the store has nothing for Grok so callers keep their loading skeleton.
    /// Deliberately not stored in `Cache`: a cached seed would mask the live
    /// scan for the whole TTL.
    static func seededReport(now: Date = Date(),
                             url: URL = CostHistoryStore.historyURL()) async -> GrokUsageReport? {
        await Task.detached(priority: .userInitiated) {
            let window = CostHistoryStore.window(
                source: .grok, now: now, windowDays: chartWindowDays, url: url)
            guard window.contains(where: { $0.tokens > 0 || $0.usd > 0 }) else { return nil }
            return CostHistoryStore.makeGrokReport(window: window)
        }.value
    }

    /// Pure filesystem scan — unit-testable via `homeURL` / `baselineURL` overrides.
    static func scanFull(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeURL: URL? = nil,
        now: Date = Date(),
        windowDays: Int = chartWindowDays,
        baselineURL: URL = GrokSessionBaselineStore.defaultURL()) -> GrokUsageReport
    {
        let root = (homeURL ?? GrokCredentialsStore.grokHomeURL(env: env, fileManager: fileManager))
            .appendingPathComponent("sessions", isDirectory: true)
        let sessions = loadSessions(
            root: root, fileManager: fileManager, now: now, windowDays: windowDays,
            baselineURL: baselineURL)
        return buildReport(sessions: sessions, now: now, windowDays: windowDays)
    }

    // MARK: - Session load

    struct SessionPoint: Equatable {
        let day: Date
        let tokens: Int
        let usd: Double
        let model: String
    }

    /// Result of parsing one session: optional day contribution (delta > 0 and
    /// within window) plus baseline bookkeeping for every readable session.
    struct ParseResult: Equatable {
        let point: SessionPoint?
        let sessionKey: String
        /// Max-seen lifetime total after this parse (`max(priorBaseline, T)`).
        let newMaxSeen: Int
    }

    /// Walk session directories; one point per `signals.json` attributed to the
    /// session's last-active calendar day (from `summary.json` when present,
    /// else signals mtime). Token contribution is the **delta** against the
    /// persisted max-seen baseline (not the full lifetime total).
    static func loadSessions(
        root: URL,
        fileManager: FileManager = .default,
        now: Date = Date(),
        windowDays: Int = chartWindowDays,
        calendar: Calendar = .current,
        baselineURL: URL = GrokSessionBaselineStore.defaultURL()) -> [SessionPoint]
    {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])
        else {
            // No sessions on disk — prune all stored baselines.
            GrokSessionBaselineStore.save([:], keepKeys: [], url: baselineURL)
            return []
        }

        let startOfToday = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -(windowDays - 1), to: startOfToday)
            ?? startOfToday.addingTimeInterval(-Double(windowDays) * 86_400)

        var baselines = GrokSessionBaselineStore.load(url: baselineURL)
        var keepKeys = Set<String>()
        var points: [SessionPoint] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.lastPathComponent == "signals.json" else { continue }
            guard let result = parseSession(
                signalsURL: url,
                baselines: baselines,
                fileManager: fileManager,
                calendar: calendar,
                cutoff: cutoff)
            else { continue }
            keepKeys.insert(result.sessionKey)
            baselines[result.sessionKey] = result.newMaxSeen
            if let point = result.point {
                points.append(point)
            }
        }
        GrokSessionBaselineStore.save(baselines, keepKeys: keepKeys, url: baselineURL)
        return points
    }

    /// Parse one session. Always updates max-seen when signals are readable and
    /// T > 0 (even outside the chart window) so re-opening an old session later
    /// only charges growth. Emits a `SessionPoint` only when the last-active day
    /// is inside the window and delta > 0.
    static func parseSession(
        signalsURL: URL,
        baselines: [String: Int] = [:],
        fileManager: FileManager = .default,
        calendar: Calendar = .current,
        cutoff: Date) -> ParseResult?
    {
        let attrs = try? signalsURL.resourceValues(forKeys: [.contentModificationDateKey])
        let mtime = attrs?.contentModificationDate ?? Date.distantPast

        let sessionDir = signalsURL.deletingLastPathComponent()
        let sessionKey = sessionDir.lastPathComponent
        let summaryURL = sessionDir.appendingPathComponent("summary.json")
        var model = "grok-4.5"
        var activeAt = mtime

        if let data = try? Data(contentsOf: summaryURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if let mid = (json["current_model_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !mid.isEmpty
            {
                model = mid
            }
            if let raw = json["last_active_at"] as? String ?? json["updated_at"] as? String,
               let parsed = parseISO8601(raw)
            {
                activeAt = parsed
            }
        }

        guard let data = try? Data(contentsOf: signalsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Prefer explicit model from signals when present.
        if let primary = (json["primaryModelId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !primary.isEmpty
        {
            model = primary
        } else if let models = json["modelsUsed"] as? [String],
                  let first = models.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        {
            model = first.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let before = intValue(json["totalTokensBeforeCompaction"])
        let context = intValue(json["contextTokensUsed"])
        // Match CodexBar GrokLocalSessionScanner token aggregation.
        // T is not monotonic: contextTokensUsed shrinks after compaction.
        let lifetime = max(0, before + context)
        guard lifetime > 0 else { return nil }

        let prior = baselines[sessionKey] ?? 0
        let delta = max(0, lifetime - prior)
        let newMaxSeen = max(prior, lifetime)

        let day = calendar.startOfDay(for: activeAt)
        let inWindow = day >= calendar.startOfDay(for: cutoff)
        let point: SessionPoint?
        if inWindow, delta > 0 {
            let usd = GrokModelPrice.estimateUSD(tokens: delta, model: model)
            point = SessionPoint(day: day, tokens: delta, usd: usd, model: model)
        } else {
            point = nil
        }
        return ParseResult(point: point, sessionKey: sessionKey, newMaxSeen: newMaxSeen)
    }

    // MARK: - Report build

    /// Pure fold of session points into a contiguous daily report.
    static func buildReport(
        sessions: [SessionPoint],
        now: Date = Date(),
        windowDays: Int = chartWindowDays,
        calendar: Calendar = .current) -> GrokUsageReport
    {
        let startOfToday = calendar.startOfDay(for: now)
        final class Acc {
            var usd: Double = 0
            var tokens: Int = 0
            var models: [String: (usd: Double, tokens: Int)] = [:]
        }
        var buckets: [Date: Acc] = [:]
        for s in sessions {
            let day = calendar.startOfDay(for: s.day)
            let acc = buckets[day] ?? Acc()
            acc.usd += s.usd
            acc.tokens += s.tokens
            var m = acc.models[s.model] ?? (0, 0)
            m.usd += s.usd
            m.tokens += s.tokens
            acc.models[s.model] = m
            buckets[day] = acc
        }

        var daily: [GrokDailyUsage] = []
        daily.reserveCapacity(windowDays)
        for offset in stride(from: windowDays - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: startOfToday) else { continue }
            let acc = buckets[day]
            var dayModels: [GrokDailyModel] = []
            if let models = acc?.models {
                for (name, stats) in models where stats.tokens > 0 || stats.usd > 0 {
                    dayModels.append(GrokDailyModel(name: name, usd: stats.usd, tokens: stats.tokens))
                }
                dayModels.sort { lhs, rhs in
                    if lhs.usd == rhs.usd { return lhs.tokens > rhs.tokens }
                    return lhs.usd > rhs.usd
                }
                if dayModels.count > 5 { dayModels = Array(dayModels.prefix(5)) }
            }
            daily.append(GrokDailyUsage(
                date: day,
                usd: acc?.usd ?? 0,
                tokens: acc?.tokens ?? 0,
                models: dayModels))
        }

        let last30 = daily.suffix(30)
        // Calendar-today bucket (last of contiguous window) — All tab merges
        // on startOfDay, not "last active day".
        let todayBucket = daily.last

        var modelTotals: [String: (usd: Double, tokens: Int)] = [:]
        for d in last30 {
            for m in d.models {
                var t = modelTotals[m.name] ?? (0, 0)
                t.usd += m.usd
                t.tokens += m.tokens
                modelTotals[m.name] = t
            }
        }
        let topModel = modelTotals.max {
            $0.value.usd == $1.value.usd
                ? $0.value.tokens < $1.value.tokens
                : $0.value.usd < $1.value.usd
        }?.key

        return GrokUsageReport(
            todayUSD: todayBucket?.usd ?? 0,
            todayTokens: todayBucket?.tokens ?? 0,
            last30USD: last30.map(\.usd).reduce(0, +),
            last30Tokens: last30.map(\.tokens).reduce(0, +),
            daily: daily,
            topModel: topModel)
    }

    // MARK: - Helpers

    private static func intValue(_ raw: Any?) -> Int {
        switch raw {
        case let i as Int: return i
        case let n as NSNumber: return n.intValue
        case let d as Double: return Int(d)
        case let s as String: return Int(s) ?? 0
        default: return 0
        }
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: raw)
    }
}
