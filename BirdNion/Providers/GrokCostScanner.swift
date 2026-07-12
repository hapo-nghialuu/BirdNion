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

// MARK: - Scanner

/// Walks `~/.grok/sessions/**/signals.json` (path overridable via `GROK_HOME`)
/// and builds a 90-day daily cost report for the All tab.
enum GrokCostScanner {
    private static let cacheTTL: TimeInterval = 300
    static let chartWindowDays = 90

    private actor Cache {
        static let shared = Cache()
        private var reportEntry: (at: Date, value: GrokUsageReport)?
        func validReport(now: Date, ttl: TimeInterval) -> GrokUsageReport? {
            guard let reportEntry, now.timeIntervalSince(reportEntry.at) < ttl else { return nil }
            return reportEntry.value
        }
        func storeReport(_ value: GrokUsageReport, at: Date) { reportEntry = (at, value) }
    }

    /// Cached full report (90 daily buckets + strict 30-day totals).
    /// Merges with `CostHistoryStore` so deleted `~/.grok/sessions` do not
    /// wipe past All-tab bars.
    static func usageReport(now: Date = Date()) async -> GrokUsageReport? {
        if let cached = await Cache.shared.validReport(now: now, ttl: cacheTTL) { return cached }
        let value = await Task.detached(priority: .utility) {
            // Only rescan days that can still change persisted history; the
            // store supplies the older days.
            let scanDays = CostHistoryStore.scanBackDays(source: .grok, now: now)
            let live = scanFull(now: now, windowDays: scanDays)
            let liveDays = live.daily.map {
                ($0.date, $0.usd, $0.tokens,
                 $0.models.map { (name: $0.name, usd: $0.usd, tokens: $0.tokens) })
            }
            let window = CostHistoryStore.apply(
                source: .grok,
                liveDays: liveDays,
                now: now,
                windowDays: chartWindowDays)
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

    /// Pure filesystem scan — unit-testable via `homeURL` override.
    static func scanFull(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeURL: URL? = nil,
        now: Date = Date(),
        windowDays: Int = chartWindowDays) -> GrokUsageReport
    {
        let root = (homeURL ?? GrokCredentialsStore.grokHomeURL(env: env, fileManager: fileManager))
            .appendingPathComponent("sessions", isDirectory: true)
        let sessions = loadSessions(root: root, fileManager: fileManager, now: now, windowDays: windowDays)
        return buildReport(sessions: sessions, now: now, windowDays: windowDays)
    }

    // MARK: - Session load

    struct SessionPoint: Equatable {
        let day: Date
        let tokens: Int
        let usd: Double
        let model: String
    }

    /// Walk session directories; one point per `signals.json` attributed to the
    /// session's last-active calendar day (from `summary.json` when present,
    /// else signals mtime).
    static func loadSessions(
        root: URL,
        fileManager: FileManager = .default,
        now: Date = Date(),
        windowDays: Int = chartWindowDays,
        calendar: Calendar = .current) -> [SessionPoint]
    {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        let startOfToday = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -(windowDays - 1), to: startOfToday)
            ?? startOfToday.addingTimeInterval(-Double(windowDays) * 86_400)

        var points: [SessionPoint] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.lastPathComponent == "signals.json" else { continue }
            guard let point = parseSession(
                signalsURL: url,
                fileManager: fileManager,
                calendar: calendar,
                cutoff: cutoff)
            else { continue }
            points.append(point)
        }
        return points
    }

    static func parseSession(
        signalsURL: URL,
        fileManager: FileManager = .default,
        calendar: Calendar = .current,
        cutoff: Date) -> SessionPoint?
    {
        let attrs = try? signalsURL.resourceValues(forKeys: [.contentModificationDateKey])
        let mtime = attrs?.contentModificationDate ?? Date.distantPast

        let sessionDir = signalsURL.deletingLastPathComponent()
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

        let day = calendar.startOfDay(for: activeAt)
        guard day >= calendar.startOfDay(for: cutoff) else { return nil }

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
        let tokens = max(0, before + context)
        guard tokens > 0 else { return nil }

        let usd = GrokModelPrice.estimateUSD(tokens: tokens, model: model)
        return SessionPoint(day: day, tokens: tokens, usd: usd, model: model)
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
