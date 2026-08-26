import Foundation
import Darwin

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
    private static let maxModelNameScalars = 128
    /// Shared macOS/Linux schema cap. Kiro currently emits at most seven,
    /// while Claude/Codex histories may legitimately contain more models.
    private static let maxModelsPerDay = 32
    private static let maxHistoryBytes = 8 * 1024 * 1024
    private static let maxScannedAtFutureSkew: TimeInterval = 5 * 60

    private enum ValidationError: Error {
        case invalidDocument
    }

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
        var scannedAt: [String: Int64]?
        /// source id → revision of the counting semantics used to build its
        /// persisted days. Shared with Linux `counting_revision`.
        var countingRevision: [String: Int]? = nil
        /// Canonical trailing-window top model per source. This preserves the
        /// real winner when daily chart payloads contain an aggregate bucket.
        var topModels: [String: String]? = nil
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
        let scannedAt = doc.scannedAt?[source.rawValue].map {
            Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
        }
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

    /// Persisted day keys are always proleptic Gregorian, matching Rust's
    /// `NaiveDate`, while retaining the caller's local timezone boundary.
    /// User-selected Buddhist/Islamic calendars must never change the shared
    /// on-disk schema.
    private static func storageCalendar(for calendar: Calendar) -> Calendar {
        var storage = Calendar(identifier: .gregorian)
        storage.locale = Locale(identifier: "en_US_POSIX")
        storage.timeZone = calendar.timeZone
        return storage
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let storage = storageCalendar(for: calendar)
        let d = storage.startOfDay(for: date)
        let c = storage.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func parseDayKey(_ key: String, calendar: Calendar = .current) -> Date? {
        let storage = storageCalendar(for: calendar)
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comp = DateComponents()
        comp.year = parts[0]
        comp.month = parts[1]
        comp.day = parts[2]
        return storage.date(from: comp).map { storage.startOfDay(for: $0) }
    }

    // MARK: - Read / write

    static func read(url: URL = historyURL()) -> Document {
        guard let data = try? readBoundedData(url: url),
              let doc = try? JSONDecoder().decode(Document.self, from: data),
              validateDocument(doc)
        else {
            return Document(version: version, sources: [:])
        }
        return doc
    }

    /// Mutation reads are strict: only a genuinely missing file starts a new
    /// document. An unreadable or malformed existing file must never be
    /// replaced with an empty document because that would erase other sources.
    private static func readForMutation(url: URL) throws -> Document {
        guard let data = try readBoundedData(url: url) else {
            return Document(version: version, sources: [:])
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard validateDocument(document) else { throw ValidationError.invalidDocument }
        return document
    }

    static func write(_ doc: Document, url: URL = historyURL()) throws {
        guard validateDocument(doc) else { throw ValidationError.invalidDocument }
        _ = try mutationPathExistsAsRegularFile(url)
        var out = doc
        out.version = version
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(out)
        guard data.count <= maxHistoryBytes else { throw ValidationError.invalidDocument }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// `fileExists` follows symlinks, so a dangling link looks absent and an
    /// atomic rename can replace it. `lstat` distinguishes genuinely missing
    /// history from every non-regular path and keeps mutation fail-closed.
    private static func mutationPathExistsAsRegularFile(_ url: URL) throws -> Bool {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        if result == 0 {
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
                throw ValidationError.invalidDocument
            }
            return true
        }
        guard errno == ENOENT else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return false
    }

    /// Bounded descriptor read keeps malformed/sparse history from forcing a
    /// multi-gigabyte allocation. `O_NOFOLLOW` also keeps dangling and live
    /// symlinks fail-closed instead of treating them as a new store.
    private static func readBoundedData(url: URL) throws -> Data? {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size >= 0,
              info.st_size <= maxHistoryBytes
        else { throw ValidationError.invalidDocument }
        guard let data = try handle.read(upToCount: maxHistoryBytes + 1),
              data.count <= maxHistoryBytes
        else { throw ValidationError.invalidDocument }
        return data
    }

    static func validateDocument(
        _ document: Document,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard document.version == nil || document.version == 0 || document.version == version
        else { return false }
        let knownSources = Set(Source.allCases.map(\.rawValue))
        let sources = document.sources ?? [:]
        guard sources.count <= knownSources.count,
              sources.keys.allSatisfy(knownSources.contains),
              document.scannedAt?.count ?? 0 <= knownSources.count,
              document.scannedAt?.keys.allSatisfy(knownSources.contains) ?? true,
              document.countingRevision?.count ?? 0 <= knownSources.count,
              document.countingRevision?.keys.allSatisfy(knownSources.contains) ?? true,
              document.topModels?.count ?? 0 <= knownSources.count,
              document.topModels?.keys.allSatisfy(knownSources.contains) ?? true
        else { return false }
        let latestSafeScan = Int64(
            ((now.timeIntervalSince1970 + maxScannedAtFutureSkew) * 1_000)
                .rounded(.towardZero))
        let today = storageCalendar(for: calendar).startOfDay(for: now)
        if document.scannedAt?.values.contains(where: { $0 < 0 || $0 > latestSafeScan }) == true {
            return false
        }
        if document.topModels?.values.contains(where: { !validModelName($0) }) == true {
            return false
        }
        if document.countingRevision?.values.contains(where: { $0 < 0 }) == true {
            return false
        }

        var totalDayUSD = 0.0
        var totalDayTokens = 0
        var totalModelUSD = 0.0
        var totalModelTokens = 0
        for days in sources.values {
            guard days.count <= retainDays else { return false }
            for (key, day) in days {
                guard let parsed = parseDayKey(key, calendar: calendar),
                      dayKey(parsed, calendar: calendar) == key,
                      parsed <= today,
                      day.models.count <= maxModelsPerDay,
                      accumulateUSD(day.usd, into: &totalDayUSD),
                      accumulateTokens(day.tokens, into: &totalDayTokens)
                else { return false }
                for model in day.models {
                    guard validModelName(model.name),
                          accumulateUSD(model.usd, into: &totalModelUSD),
                          accumulateTokens(model.tokens, into: &totalModelTokens)
                    else { return false }
                }
            }
        }
        return true
    }

    private static func validModelName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && name.unicodeScalars.count <= maxModelNameScalars
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func accumulateUSD(_ value: Double, into total: inout Double) -> Bool {
        guard value.isFinite, value >= 0 else { return false }
        let next = total + value
        guard next.isFinite else { return false }
        total = next
        return true
    }

    private static func accumulateTokens(_ value: Int, into total: inout Int) -> Bool {
        guard value >= 0 else { return false }
        let (next, overflow) = total.addingReportingOverflow(value)
        guard !overflow else { return false }
        total = next
        return true
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
        let updated = Document(
            version: version,
            sources: sources,
            scannedAt: document.scannedAt,
            countingRevision: document.countingRevision,
            topModels: document.topModels)
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
        liveScanSucceeded: Bool = false,
        updateTopModel: Bool = false,
        topModel: String? = nil,
        countingRevision: Int? = nil) -> ApplyReceipt
    {
        ioLock.lock()
        defer { ioLock.unlock() }

        let doc: Document
        do {
            doc = try readForMutation(url: url)
        } catch {
            return ApplyReceipt(window: [], persisted: false)
        }
        if let countingRevision,
           let storedRevision = doc.countingRevision?[source.rawValue],
           storedRevision > countingRevision
        {
            // Fail closed on downgrade: days written with newer counting
            // semantics cannot be merged, restamped, or otherwise rewritten
            // by an older build. Return the durable history projection only.
            let previous = doc.sources?[source.rawValue] ?? [:]
            return ApplyReceipt(
                window: buildWindow(
                    byDay: previous,
                    now: now,
                    calendar: calendar,
                    windowDays: windowDays),
                persisted: false)
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
            scannedAt[source.rawValue] = Int64(
                (now.timeIntervalSince1970 * 1_000).rounded(.towardZero))
            updated.scannedAt = scannedAt
            if let countingRevision, countingRevision >= 0 {
                var revisions = updated.countingRevision ?? [:]
                revisions[source.rawValue] = countingRevision
                updated.countingRevision = revisions
            }
        }
        if updateTopModel {
            var topModels = updated.topModels ?? [:]
            if let mergedTopModel = trailingTopModel(
                sourceDays: updated.sources?[source.rawValue] ?? [:],
                now: now,
                calendar: calendar) ?? topModel
            {
                topModels[source.rawValue] = mergedTopModel
            } else if replacingSource || !(updated.sources?[source.rawValue] ?? [:]).values.contains(
                where: { $0.tokens > 0 || $0.usd > 0 })
            {
                topModels.removeValue(forKey: source.rawValue)
            }
            updated.topModels = topModels
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

    static func storedCountingRevision(
        source: Source,
        url: URL = historyURL()) -> Int
    {
        ioLock.lock()
        defer { ioLock.unlock() }
        return read(url: url).countingRevision?[source.rawValue] ?? 0
    }

    static func storedTopModel(
        source: Source,
        url: URL = historyURL()
    ) -> String? {
        ioLock.lock()
        defer { ioLock.unlock() }
        let stored = read(url: url).topModels?[source.rawValue]
        if source == .kiro, stored == KiroCostScanner.aggregateModelName { return nil }
        return stored
    }

    /// Canonical Kiro winner comes from the merged trailing window, not just
    /// the newest incremental scan. `Other` is a chart aggregation bucket and
    /// must never win against a real model.
    private static func trailingTopModel(
        sourceDays: [String: Day],
        now: Date,
        calendar: Calendar
    ) -> String? {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        var totals: [String: (usd: Double, tokens: Int)] = [:]
        for (key, day) in sourceDays {
            guard let date = parseDayKey(key, calendar: calendar),
                  date >= start, date <= today
            else { continue }
            for model in day.models where model.name != KiroCostScanner.aggregateModelName {
                var total = totals[model.name] ?? (0, 0)
                let (tokens, overflow) = total.tokens.addingReportingOverflow(model.tokens)
                let usd = total.usd + model.usd
                guard !overflow, usd.isFinite else { continue }
                total.tokens = tokens
                total.usd = usd
                totals[model.name] = total
            }
        }
        return totals.max { lhs, rhs in
            if lhs.value.tokens != rhs.value.tokens {
                return lhs.value.tokens < rhs.value.tokens
            }
            if lhs.value.usd != rhs.value.usd {
                return lhs.value.usd < rhs.value.usd
            }
            return lhs.key > rhs.key
        }?.key
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
        persistedTopModel: String? = nil,
        confidence: UsageScanConfidence = .unavailable
    ) -> KiroUsageReport {
        let last30 = window.suffix(30)
        let today = window.last
        var modelTotals: [String: (usd: Double, tokens: Int)] = [:]
        for d in last30 {
            for m in d.models where m.name != KiroCostScanner.aggregateModelName {
                var t = modelTotals[m.name] ?? (0, 0)
                t.usd += m.usd
                t.tokens += m.tokens
                modelTotals[m.name] = t
            }
        }
        let reconstructedTop = modelTotals.max {
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
            topModel: persistedTopModel == KiroCostScanner.aggregateModelName
                ? reconstructedTop
                : persistedTopModel ?? reconstructedTop,
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

extension CostHistoryStore.Document {
    private enum CodingKeys: String, CodingKey {
        case version, sources
        case scannedAt = "scanned_at"
        case countingRevision = "counting_revision"
        case topModels = "top_models"
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case scannedAt, countingRevision, topModels
    }

    /// macOS builds before the shared schema fix encoded epoch milliseconds as
    /// JSON doubles (for example `1787651040100.229`). Normalize those values
    /// toward zero once, then always encode canonical integer milliseconds so
    /// the same document is readable by Rust's `i64` representation.
    private static func decodeMilliseconds<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> [String: Int64]? {
        guard container.contains(key), try !container.decodeNil(forKey: key) else { return nil }
        if let exact = try? container.decode([String: Int64].self, forKey: key) {
            return exact
        }
        let legacy = try container.decode([String: Double].self, forKey: key)
        var normalized: [String: Int64] = [:]
        normalized.reserveCapacity(legacy.count)
        for (source, value) in legacy {
            guard value.isFinite,
                  value >= 0,
                  value < Double(Int64.max)
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "Invalid epoch-millisecond value")
            }
            normalized[source] = Int64(value.rounded(.towardZero))
        }
        return normalized
    }

    init(from decoder: Decoder) throws {
        let canonical = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        version = try canonical.decodeIfPresent(Int.self, forKey: .version)
        sources = try canonical.decodeIfPresent(
            [String: [String: CostHistoryStore.Day]].self,
            forKey: .sources)

        let canonicalScannedAt = try Self.decodeMilliseconds(
            from: canonical, forKey: .scannedAt)
        let legacyScannedAt = try Self.decodeMilliseconds(
            from: legacy, forKey: .scannedAt)
        guard canonicalScannedAt == nil || legacyScannedAt == nil
                || canonicalScannedAt == legacyScannedAt
        else { throw DecodingError.dataCorruptedError(
            forKey: .scannedAt, in: canonical,
            debugDescription: "Conflicting scanned_at and scannedAt values") }
        scannedAt = canonicalScannedAt ?? legacyScannedAt

        let canonicalRevision = try canonical.decodeIfPresent(
            [String: Int].self, forKey: .countingRevision)
        let legacyRevision = try legacy.decodeIfPresent(
            [String: Int].self, forKey: .countingRevision)
        guard canonicalRevision == nil || legacyRevision == nil
                || canonicalRevision == legacyRevision
        else { throw DecodingError.dataCorruptedError(
            forKey: .countingRevision, in: canonical,
            debugDescription: "Conflicting counting_revision and countingRevision values") }
        countingRevision = canonicalRevision ?? legacyRevision

        let canonicalTopModels = try canonical.decodeIfPresent(
            [String: String].self, forKey: .topModels)
        let legacyTopModels = try legacy.decodeIfPresent(
            [String: String].self, forKey: .topModels)
        guard canonicalTopModels == nil || legacyTopModels == nil
                || canonicalTopModels == legacyTopModels
        else { throw DecodingError.dataCorruptedError(
            forKey: .topModels, in: canonical,
            debugDescription: "Conflicting top_models and topModels values") }
        topModels = canonicalTopModels ?? legacyTopModels
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encodeIfPresent(sources, forKey: .sources)
        try container.encodeIfPresent(scannedAt, forKey: .scannedAt)
        try container.encodeIfPresent(countingRevision, forKey: .countingRevision)
        try container.encodeIfPresent(topModels, forKey: .topModels)
    }
}
