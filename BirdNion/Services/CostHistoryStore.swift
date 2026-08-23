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
        case claude, codex, grok, kiro, omp, pi
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
        /// source id → epoch millis of the most recent successful live scan
        /// (Data Confidence Pass, mirrors the Linux Tauri port's
        /// `cost-history.json` schema). Optional so older documents without
        /// this key decode unchanged — missing entries read back as `nil`.
        var scannedAt: [String: Double]?
    }

    // MARK: - Data Confidence Pass

    /// Per-source scan-confidence metadata for the All-tab compact badge —
    /// mirrors the Linux port's `included`/`live`/`scannedAt` `UsageReport`
    /// fields. Pure value type; produced by `confidence(source:liveScanSucceeded:)`.
    struct UsageScanConfidence: Equatable, Sendable {
        /// `true` once this source has ever produced evidence — this cycle's
        /// live scan succeeded, or history already holds a real (non-zero)
        /// day for it. `false` means the source has no data on this machine
        /// at all.
        let included: Bool
        /// `true` when THIS refresh cycle's scanner actually ran and
        /// returned a report (merged into history); `false` means the
        /// numbers are a history-only carry-forward.
        let live: Bool
        /// Most recent successful live-scan time, persisted so a
        /// history-only cycle can still report freshness. `nil` when no
        /// live scan has ever succeeded for this source.
        let scannedAt: Date?

        /// Neutral placeholder for reports built without going through
        /// `CostHistoryStore` (memberwise inits, previews, tests).
        static let unavailable = UsageScanConfidence(included: false, live: false, scannedAt: nil)
    }

    /// Read-only confidence lookup for one source. Call after `apply` so a
    /// live scan's just-written `scannedAt` stamp is already on disk. No
    /// merge, no write — mirrors the `window(source:...)` read-only helper.
    static func confidence(
        source: Source,
        liveScanSucceeded: Bool,
        url: URL = historyURL()) -> UsageScanConfidence
    {
        ioLock.lock()
        defer { ioLock.unlock() }
        let doc = read(url: url)
        let byDay = doc.sources?[source.rawValue] ?? [:]
        let historyHasData = byDay.values.contains { $0.tokens > 0 || $0.usd > 0 }
        let scannedAt = doc.scannedAt?[source.rawValue].map { Date(timeIntervalSince1970: $0 / 1000) }
        return UsageScanConfidence(
            included: liveScanSucceeded || historyHasData,
            live: liveScanSucceeded,
            scannedAt: scannedAt)
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

    /// Mutation reads are strict: only a genuinely missing file starts a new
    /// document. An unreadable or malformed existing file must never be
    /// replaced with an empty document because that would erase other sources.
    private static func readForMutation(url: URL) throws -> Document {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Document(version: version, sources: [:])
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Document.self, from: data)
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
    ///
    /// When `replacingSource` is true, ignore previously stored days for that
    /// source and write only the live set (atomic wipe+replace in one write
    /// via `apply`). Used after a counting/pricing revision so high-water
    /// cannot keep inflated pre-fix totals.
    static func merge(
        document: Document,
        source: Source,
        liveDays: [(date: Date, usd: Double, tokens: Int, models: [(name: String, usd: Double, tokens: Int)])],
        now: Date = Date(),
        calendar: Calendar = .current,
        windowDays: Int = 90,
        retainDays: Int = retainDays,
        replacingSource: Bool = false) -> (document: Document, window: [DayBucket])
    {
        var sources = document.sources ?? [:]
        var byDay: [String: Day] = replacingSource ? [:] : (sources[source.rawValue] ?? [:])

        for live in liveDays {
            let key = dayKey(live.date, calendar: calendar)
            let incoming = Day(
                usd: live.usd,
                tokens: live.tokens,
                models: live.models.map { Model(name: $0.name, usd: $0.usd, tokens: $0.tokens) })
            if !replacingSource, let existing = byDay[key] {
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
        // Preserve the confidence-pass timestamp map untouched — `apply`
        // stamps it separately, based on `liveScanSucceeded`, not on
        // whether `liveDays` merged anything.
        let updated = Document(version: version, sources: sources, scannedAt: document.scannedAt)
        let window = buildWindow(
            byDay: byDay, now: now, calendar: calendar, windowDays: windowDays)
        return (updated, window)
    }

    /// Contiguous chart window (oldest → newest) from one source's stored
    /// days; days without a stored entry render as zeros.
    static func buildWindow(
        byDay: [String: Day],
        now: Date,
        calendar: Calendar,
        windowDays: Int) -> [DayBucket]
    {
        let startOfToday = calendar.startOfDay(for: now)
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
        return window
    }

    struct DayBucket: Equatable {
        let date: Date
        let usd: Double
        let tokens: Int
        let models: [Model]
    }

    struct ApplyReceipt: Equatable {
        let window: [DayBucket]
        let persisted: Bool
    }

    /// Apply live days for a source: merge into disk and return the window.
    /// Pass `replacingSource: true` to atomically replace that source's days
    /// with the live set (no high-water against prior disk state).
    /// `liveScanSucceeded` stamps `Document.scannedAt[source]` with `now`
    /// (Data Confidence Pass) — pass `true` only when the scanner actually
    /// ran and returned a report this cycle. `false` (the default, kept for
    /// call sites predating this pass) leaves any prior stamp untouched, so
    /// a history-only fallback never manufactures a fresh timestamp.
    @discardableResult
    static func apply(
        source: Source,
        liveDays: [(date: Date, usd: Double, tokens: Int, models: [(name: String, usd: Double, tokens: Int)])],
        now: Date = Date(),
        calendar: Calendar = .current,
        windowDays: Int = 90,
        url: URL = historyURL(),
        replacingSource: Bool = false,
        liveScanSucceeded: Bool = false) -> [DayBucket]
    {
        applyWithReceipt(
            source: source,
            liveDays: liveDays,
            now: now,
            calendar: calendar,
            windowDays: windowDays,
            url: url,
            replacingSource: replacingSource,
            liveScanSucceeded: liveScanSucceeded).window
    }

    /// Same merge as `apply`, with a durable-write receipt. On write failure,
    /// return the previously persisted window so callers never publish values
    /// or freshness that exist only in memory.
    static func applyWithReceipt(
        source: Source,
        liveDays: [(date: Date, usd: Double, tokens: Int, models: [(name: String, usd: Double, tokens: Int)])],
        now: Date = Date(),
        calendar: Calendar = .current,
        windowDays: Int = 90,
        url: URL = historyURL(),
        replacingSource: Bool = false,
        liveScanSucceeded: Bool = false) -> ApplyReceipt
    {
        ioLock.lock()
        defer { ioLock.unlock() }

        let doc: Document
        do {
            doc = try readForMutation(url: url)
        } catch {
            return ApplyReceipt(window: [], persisted: false)
        }
        var (updated, window) = merge(
            document: doc,
            source: source,
            liveDays: liveDays,
            now: now,
            calendar: calendar,
            windowDays: windowDays,
            replacingSource: replacingSource)
        if liveScanSucceeded {
            var scannedAt = updated.scannedAt ?? [:]
            scannedAt[source.rawValue] = now.timeIntervalSince1970 * 1000
            updated.scannedAt = scannedAt
        }
        do {
            try write(updated, url: url)
            return ApplyReceipt(window: window, persisted: true)
        } catch {
            let previous = doc.sources?[source.rawValue] ?? [:]
            return ApplyReceipt(
                window: buildWindow(
                    byDay: previous,
                    now: now,
                    calendar: calendar,
                    windowDays: windowDays),
                persisted: false)
        }
    }

    // MARK: - Read-only views

    /// Read-only window straight from the persisted store — seeds the popover
    /// chart before the live scan lands. No merge, no write.
    static func window(
        source: Source,
        now: Date = Date(),
        calendar: Calendar = .current,
        windowDays: Int = 90,
        url: URL = historyURL()) -> [DayBucket]
    {
        ioLock.lock()
        defer { ioLock.unlock() }
        let byDay = read(url: url).sources?[source.rawValue] ?? [:]
        return buildWindow(byDay: byDay, now: now, calendar: calendar, windowDays: windowDays)
    }

    /// Days the live scan must cover so no day slips between persisted
    /// history and the fresh scan: distance from the source's newest stored
    /// day to today (that day is rescanned too — it may still grow), clamped
    /// to [minDays, maxDays]. Sources without history scan the full maxDays.
    static func scanBackDays(
        source: Source,
        now: Date = Date(),
        calendar: Calendar = .current,
        minDays: Int = 7,
        maxDays: Int = 90,
        url: URL = historyURL()) -> Int
    {
        ioLock.lock()
        defer { ioLock.unlock() }
        let byDay = read(url: url).sources?[source.rawValue] ?? [:]
        guard let latest = byDay.keys.compactMap({ parseDayKey($0, calendar: calendar) }).max()
        else { return maxDays }
        let days = calendar.dateComponents(
            [.day], from: latest, to: calendar.startOfDay(for: now)).day ?? maxDays
        return min(max(days + 1, minDays), maxDays)
    }

    // MARK: - Report rebuilders

    static func makeClaudeReport(
        window: [DayBucket],
        hourly: [ClaudeHourlyUsage] = [],
        now: Date = Date(),
        calendar: Calendar = .current,
        confidence: UsageScanConfidence = .unavailable) -> ClaudeUsageReport
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
            topModel: top,
            scanConfidence: confidence)
    }

    static func makeCodexReport(
        window: [DayBucket],
        now: Date = Date(),
        confidence: UsageScanConfidence = .unavailable) -> CodexUsageReport
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
            topModel: top,
            scanConfidence: confidence)
    }

    static func makeGrokReport(
        window: [DayBucket],
        confidence: UsageScanConfidence = .unavailable) -> GrokUsageReport
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
            topModel: top,
            scanConfidence: confidence)
    }

    static func makeKiroReport(
        window: [DayBucket],
        confidence: UsageScanConfidence = .unavailable
    ) -> KiroUsageReport {
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
            $0.value.tokens == $1.value.tokens
                ? $0.value.usd < $1.value.usd
                : $0.value.tokens < $1.value.tokens
        }?.key
        return KiroUsageReport(
            todayUSD: today?.usd ?? 0,
            todayTokens: today?.tokens ?? 0,
            last30USD: last30.map(\.usd).reduce(0, +),
            last30Tokens: last30.map(\.tokens).reduce(0, +),
            daily: window.map {
                KiroDailyUsage(
                    date: $0.date, usd: $0.usd, tokens: $0.tokens,
                    models: $0.models.map {
                        KiroDailyModel(name: $0.name, usd: $0.usd, tokens: $0.tokens)
                    })
            },
            topModel: top,
            scanConfidence: confidence)
    }

    static func makeOMPReport(
        window: [DayBucket],
        confidence: UsageScanConfidence = .unavailable) -> OMPUsageReport
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
        return OMPUsageReport(
            todayUSD: today?.usd ?? 0,
            todayTokens: today?.tokens ?? 0,
            last30USD: last30.map(\.usd).reduce(0, +),
            last30Tokens: last30.map(\.tokens).reduce(0, +),
            daily: window.map {
                OMPDailyUsage(
                    date: $0.date, usd: $0.usd, tokens: $0.tokens,
                    models: $0.models.map {
                        OMPDailyModel(name: $0.name, usd: $0.usd, tokens: $0.tokens)
                    })
            },
            topModel: top,
            scanConfidence: confidence)
    }

    static func makePiReport(
        window: [DayBucket],
        confidence: UsageScanConfidence = .unavailable) -> PiUsageReport
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
        return PiUsageReport(
            todayUSD: today?.usd ?? 0,
            todayTokens: today?.tokens ?? 0,
            last30USD: last30.map(\.usd).reduce(0, +),
            last30Tokens: last30.map(\.tokens).reduce(0, +),
            daily: window.map {
                PiDailyUsage(
                    date: $0.date, usd: $0.usd, tokens: $0.tokens,
                    models: $0.models.map {
                        PiDailyModel(name: $0.name, usd: $0.usd, tokens: $0.tokens)
                    })
            },
            topModel: top,
            scanConfidence: confidence)
    }
}
