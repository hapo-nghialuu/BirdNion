import Foundation

/// Persisted per-day cost history for the All-tab chart/heatmap.
///
/// Problem: Claude / Codex / Grok scanners only see *current* session logs.
/// When the user deletes `~/.claude/projects`, `~/.codex/sessions`, or
/// `~/.grok/sessions`, a fresh scan would zero out past bars.
///
/// Solution: after every live scan, merge each calendar day into
/// `~/.config/birdnion/cost-history.json` with a **never-shrink** rule:
/// keep the day whose `tokens` (then `usd`) is higher. Live growth updates
/// the store; deleted sessions leave the previous high-water mark intact.
///
/// File sits next to `settings.json` (same path resolution). Atomic write + 0600.
enum CostHistoryStore {
    static let version = 1
    /// Drop days older than this so the file cannot grow forever.
    static let retainDays = 400
    private static let ioLock = NSLock()

    enum Source: String, CaseIterable {
        case claude, codex, grok
    }

    // MARK: - Schema

    struct Model: Codable, Equatable {
        var name: String
        var usd: Double
        var tokens: Int
    }

    struct Day: Codable, Equatable {
        var usd: Double
        var tokens: Int
        var models: [Model]
    }

    struct Document: Codable, Equatable {
        var version: Int?
        /// source id → "yyyy-MM-dd" (local) → day totals
        var sources: [String: [String: Day]]?
    }

    // MARK: - Path

    /// Sibling of settings.json under the BirdNion config directory.
    static func historyURL(configURL: URL = BirdNionConfigStore.configURL()) -> URL {
        configURL.deletingLastPathComponent().appendingPathComponent("cost-history.json")
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let d = calendar.startOfDay(for: date)
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func parseDayKey(_ key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comp = DateComponents()
        comp.year = parts[0]
        comp.month = parts[1]
        comp.day = parts[2]
        return calendar.date(from: comp).map { calendar.startOfDay(for: $0) }
    }

    // MARK: - Read / write

    static func read(url: URL = historyURL()) -> Document {
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(Document.self, from: data)
        else {
            return Document(version: version, sources: [:])
        }
        return doc
    }

    static func write(_ doc: Document, url: URL = historyURL()) throws {
        var out = doc
        out.version = version
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(out)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Merge (pure)

    /// Prefer the higher-water-mark day so a partial live scan (after the user
    /// deleted session logs) never erases previously observed totals.
    static func preferHigher(_ a: Day, _ b: Day) -> Day {
        if b.tokens > a.tokens { return b }
        if b.tokens < a.tokens { return a }
        if b.usd > a.usd { return b }
        if b.usd < a.usd { return a }
        // Equal totals — keep the side with more model detail if any.
        return b.models.count >= a.models.count ? b : a
    }

    /// Merge live day buckets into the document for one source. Returns the
    /// updated document and the contiguous daily series for the UI window.
    static func merge(
        document: Document,
        source: Source,
        liveDays: [(date: Date, usd: Double, tokens: Int, models: [(name: String, usd: Double, tokens: Int)])],
        now: Date = Date(),
        calendar: Calendar = .current,
        windowDays: Int = 90,
        retainDays: Int = retainDays) -> (document: Document, window: [DayBucket])
    {
        var sources = document.sources ?? [:]
        var byDay = sources[source.rawValue] ?? [:]

        for live in liveDays {
            let key = dayKey(live.date, calendar: calendar)
            let incoming = Day(
                usd: live.usd,
                tokens: live.tokens,
                models: live.models.map { Model(name: $0.name, usd: $0.usd, tokens: $0.tokens) })
            if let existing = byDay[key] {
                byDay[key] = preferHigher(existing, incoming)
            } else if incoming.tokens > 0 || incoming.usd > 0 {
                byDay[key] = incoming
            }
        }

        // Prune ancient days.
        let startOfToday = calendar.startOfDay(for: now)
        let pruneBefore = calendar.date(byAdding: .day, value: -(retainDays - 1), to: startOfToday)
            ?? startOfToday
        byDay = byDay.filter { key, _ in
            guard let d = parseDayKey(key, calendar: calendar) else { return false }
            return d >= pruneBefore
        }

        sources[source.rawValue] = byDay
        let updated = Document(version: version, sources: sources)

        // Contiguous window for the chart (oldest → newest).
        var window: [DayBucket] = []
        window.reserveCapacity(windowDays)
        for offset in stride(from: windowDays - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: startOfToday)
            else { continue }
            let key = dayKey(day, calendar: calendar)
            let stored = byDay[key]
            window.append(DayBucket(
                date: day,
                usd: stored?.usd ?? 0,
                tokens: stored?.tokens ?? 0,
                models: stored?.models ?? []))
        }
        return (updated, window)
    }

    struct DayBucket: Equatable {
        let date: Date
        let usd: Double
        let tokens: Int
        let models: [Model]
    }

    /// Apply live days for a source: merge into disk and return the window.
    @discardableResult
    static func apply(
        source: Source,
        liveDays: [(date: Date, usd: Double, tokens: Int, models: [(name: String, usd: Double, tokens: Int)])],
        now: Date = Date(),
        calendar: Calendar = .current,
        windowDays: Int = 90,
        url: URL = historyURL()) -> [DayBucket]
    {
        ioLock.lock()
        defer { ioLock.unlock() }

        let doc = read(url: url)
        let (updated, window) = merge(
            document: doc,
            source: source,
            liveDays: liveDays,
            now: now,
            calendar: calendar,
            windowDays: windowDays)
        try? write(updated, url: url)
        return window
    }

    // MARK: - Report rebuilders

    static func makeClaudeReport(
        window: [DayBucket],
        hourly: [ClaudeHourlyUsage] = [],
        now: Date = Date(),
        calendar: Calendar = .current) -> ClaudeUsageReport
    {
        let last30 = window.suffix(30)
        let today = window.last
        var modelVotes: [String: Int] = [:]
        for d in last30 {
            for m in d.models { modelVotes[m.name, default: 0] += m.tokens }
        }
        let top = modelVotes.max { $0.value < $1.value }?.key
        return ClaudeUsageReport(
            todayUSD: today?.usd ?? 0,
            todayTokens: today?.tokens ?? 0,
            last30USD: last30.map(\.usd).reduce(0, +),
            last30Tokens: last30.map(\.tokens).reduce(0, +),
            daily: window.map {
                ClaudeDailyUsage(
                    date: $0.date, usd: $0.usd, tokens: $0.tokens,
                    models: $0.models.map {
                        ClaudeDailyModel(name: $0.name, usd: $0.usd, tokens: $0.tokens)
                    })
            },
            hourly: hourly,
            topModel: top)
    }

    static func makeCodexReport(
        window: [DayBucket],
        now: Date = Date()) -> CodexUsageReport
    {
        let last30 = window.suffix(30)
        let today = window.last
        var modelTotals: [String: (usd: Double, tokens: Int)] = [:]
        for d in last30 {
            for m in d.models {
                var t = modelTotals[m.name] ?? (0, 0)
                t.usd += m.usd
                t.tokens += m.tokens
                modelTotals[m.name] = t
            }
        }
        let top = modelTotals.max {
            $0.value.usd == $1.value.usd
                ? $0.value.tokens < $1.value.tokens
                : $0.value.usd < $1.value.usd
        }?.key
        return CodexUsageReport(
            todayUSD: today?.usd ?? 0,
            todayTokens: today?.tokens ?? 0,
            last30USD: last30.map(\.usd).reduce(0, +),
            last30Tokens: last30.map(\.tokens).reduce(0, +),
            daily: window.map {
                CodexDailyUsage(
                    date: $0.date, usd: $0.usd, tokens: $0.tokens,
                    models: $0.models.map {
                        CodexDailyModel(name: $0.name, usd: $0.usd, tokens: $0.tokens)
                    })
            },
            topModel: top)
    }

    static func makeGrokReport(window: [DayBucket]) -> GrokUsageReport {
        let last30 = window.suffix(30)
        let today = window.last
        var modelTotals: [String: (usd: Double, tokens: Int)] = [:]
        for d in last30 {
            for m in d.models {
                var t = modelTotals[m.name] ?? (0, 0)
                t.usd += m.usd
                t.tokens += m.tokens
                modelTotals[m.name] = t
            }
        }
        let top = modelTotals.max {
            $0.value.usd == $1.value.usd
                ? $0.value.tokens < $1.value.tokens
                : $0.value.usd < $1.value.usd
        }?.key
        return GrokUsageReport(
            todayUSD: today?.usd ?? 0,
            todayTokens: today?.tokens ?? 0,
            last30USD: last30.map(\.usd).reduce(0, +),
            last30Tokens: last30.map(\.tokens).reduce(0, +),
            daily: window.map {
                GrokDailyUsage(
                    date: $0.date, usd: $0.usd, tokens: $0.tokens,
                    models: $0.models.map {
                        GrokDailyModel(name: $0.name, usd: $0.usd, tokens: $0.tokens)
                    })
            },
            topModel: top)
    }
}
