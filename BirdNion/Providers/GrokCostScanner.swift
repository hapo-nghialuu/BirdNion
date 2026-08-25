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
    /// Data Confidence Pass metadata (included/live/scannedAt) for the
    /// All-tab compact badge. Defaulted so memberwise call sites predating
    /// this pass stay source-compatible.
    var scanConfidence: CostHistoryStore.UsageScanConfidence = .unavailable

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
/// and builds a 120-day daily cost report for the All tab.
///
/// Token attribution (rev 3, 2026-08-25)
/// -------------------------------------
/// Each session signal file only exposes a **lifetime** token snapshot
/// (`totalTokensBeforeCompaction + contextTokensUsed`); `chat_history.jsonl`
/// carries no per-turn usage, so there is no way to know exactly how many
/// tokens were spent on any given day.
///
/// Rev 2 attributed the full lifetime total `T = before + context` to the
/// session's last-active calendar day. That is wrong two ways: merely
/// opening a session bumps `last_active_at`, so a session with zero turns
/// today still reported its entire lifetime total for today; and as the
/// last-active day moved forward day by day, the never-shrink history kept a
/// stale copy on every earlier day, so one session was counted many times
/// (measured on real data: 6.8M tokens inflated to 34.3M, 5.04x).
///
/// Rev 3 spreads `T` across the session's OWN timeline instead:
/// `events.jsonl` carries one `"type":"first_token"` event (with an RFC3339
/// `ts`) per model response, so the response count per calendar day is real
/// evidence for how to divide `T`. A day with no responses gets exactly
/// zero. The split uses largest-remainder rounding so the parts always sum
/// to exactly `T`. When `events.jsonl` is missing or has no usable events,
/// this falls back to the rev 2 last-active-day behavior — there is no
/// better evidence then, and inventing a distribution would be worse.
///
/// This is an APPORTIONMENT backed by evidence, not a measurement of each
/// response's real tokens: the weight is response count, not real per-turn
/// token usage. `CostHistoryStore.preferHigher` then keeps the high-water
/// mark per day as sessions grow.
///
/// Local signals are a lower-bound proxy for billed usage (no server-side
/// request log).
enum GrokCostScanner {
    private static let cacheTTL: TimeInterval = 300
    static let chartWindowDays = 120
    /// Bump when Grok counting semantics change. Existing persisted days need
    /// one full rescan; `usageReport` then applies with `replacingSource: true`
    /// so under/over-counted high-water marks are replaced atomically by the
    /// fresh rescan (never an empty source on disk mid-flight).
    ///
    /// Rev 2: full lifetime T per session (CodexBar/Linux), not per-scan delta
    /// against `GrokSessionBaselineStore`. Delta + preferHigher never summed
    /// intra-day growth and left today stuck at the first partial observation.
    ///
    /// Rev 3 (2026-08-25): split `T` across the session's own event timeline
    /// (`events.jsonl`) instead of dumping it all on the last-active day —
    /// see the file doc comment above.
    static let countingRevision = 3
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
            guard availableSessionsRoot(
                env: ProcessInfo.processInfo.environment, fileManager: .default, homeURL: nil) != nil
            else {
                // Sessions root missing entirely (Grok never installed, or
                // `GROK_HOME` points elsewhere) — never claim a live scan
                // happened. Merge nothing new so existing history and its
                // `scannedAt` stamp stay exactly as they were; `confidence`
                // falls back to history-only, or unavailable when there's
                // no history for this source at all.
                let window = CostHistoryStore.apply(
                    source: .grok, liveDays: [], now: now, windowDays: chartWindowDays,
                    liveScanSucceeded: false)
                let confidence = CostHistoryStore.confidence(source: .grok, liveScanSucceeded: false)
                return CostHistoryStore.makeGrokReport(window: window, confidence: confidence)
            }

            // Only rescan days that can still change persisted history; the
            // store supplies the older days. On a counting-revision bump, scan
            // the full chart window once so `replacingSource` can rebuild
            // every day from clean full-T last-active attribution.
            let incrementalDays = CostHistoryStore.scanBackDays(source: .grok, now: now)
            let storedRevision = UserDefaults.standard.integer(forKey: countingRevisionKey)
            let replacing = storedRevision < countingRevision
            let needsProjectBootstrap = ProjectCostHistoryStore.read()
                .sources?[ProjectUsageSource.grok.rawValue]?.isEmpty != false
            let scanDays = (replacing || needsProjectBootstrap) ? chartWindowDays : incrementalDays
            // The root's existence was just confirmed, so the plain
            // (nonoptional) `scanFull` is safe to call directly here.
            let live = scanFullWithProjects(now: now, windowDays: scanDays)
            let liveDays = live.report.daily.map {
                ($0.date, $0.usd, $0.tokens,
                 $0.models.map { (name: $0.name, usd: $0.usd, tokens: $0.tokens) })
            }
            let receipt = CostHistoryStore.applyWithReceipt(
                source: .grok,
                liveDays: liveDays,
                now: now,
                windowDays: chartWindowDays,
                replacingSource: replacing,
                liveScanSucceeded: true)
            _ = ProjectCostHistoryStore.apply(
                source: .grok,
                liveProjects: live.projects,
                now: now,
                replacingSource: replacing)
            if receipt.persisted {
                UserDefaults.standard.set(countingRevision, forKey: countingRevisionKey)
            }
            let confidence = CostHistoryStore.confidence(
                source: .grok,
                liveScanSucceeded: receipt.persisted)
            return CostHistoryStore.makeGrokReport(window: receipt.window, confidence: confidence)
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
            let confidence = CostHistoryStore.confidence(
                source: .grok, liveScanSucceeded: false, url: url)
            return CostHistoryStore.makeGrokReport(window: window, confidence: confidence)
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
        scanFullWithProjects(
            env: env, fileManager: fileManager, homeURL: homeURL,
            now: now, windowDays: windowDays).report
    }

    struct ScanResult: Equatable {
        let report: GrokUsageReport
        let projects: [ProjectUsageRecord]
    }

    /// One filesystem walk yields both aggregate usage and privacy-safe
    /// project contributions. `scanFull` remains the aggregate-only wrapper.
    static func scanFullWithProjects(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeURL: URL? = nil,
        now: Date = Date(),
        windowDays: Int = chartWindowDays) -> ScanResult
    {
        let root = (homeURL ?? GrokCredentialsStore.grokHomeURL(env: env, fileManager: fileManager))
            .appendingPathComponent("sessions", isDirectory: true)
        let sessions = loadSessions(
            root: root, fileManager: fileManager, now: now, windowDays: windowDays)
        return ScanResult(
            report: buildReport(sessions: sessions.report, now: now, windowDays: windowDays),
            projects: buildProjects(sessions: sessions.projects, calendar: .current))
    }

    /// The sessions root, but only when it actually exists as a directory —
    /// `nil` when it's missing entirely or the path exists but isn't a
    /// directory. Shared by `scanFullIfAvailable` and `usageReport` so a
    /// missing root is decided once, consistently, before any
    /// counting-revision side effect runs.
    private static func availableSessionsRoot(
        env: [String: String],
        fileManager: FileManager,
        homeURL: URL?
    ) -> URL? {
        let root = (homeURL ?? GrokCredentialsStore.grokHomeURL(env: env, fileManager: fileManager))
            .appendingPathComponent("sessions", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        return root
    }

    /// Same as `scanFull`, but returns `nil` when the sessions root itself is
    /// missing or not a directory, instead of quietly treating that as "zero
    /// sessions". A root that exists but is genuinely empty still returns a
    /// (zero) report — that's a legitimate live scan, not an unavailable one.
    static func scanFullIfAvailable(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeURL: URL? = nil,
        now: Date = Date(),
        windowDays: Int = chartWindowDays) -> GrokUsageReport?
    {
        guard availableSessionsRoot(env: env, fileManager: fileManager, homeURL: homeURL) != nil
        else { return nil }
        return scanFull(
            env: env, fileManager: fileManager, homeURL: homeURL,
            now: now, windowDays: windowDays)
    }

    // MARK: - Session load

    struct SessionPoint: Equatable {
        let day: Date
        let tokens: Int
        let usd: Double
        let model: String
        var projectKey: String? = nil
        var projectName: String? = nil
    }

    /// Report points (one per apportioned day, no project attribution) plus
    /// project points (one per session that resolves to a project, unsplit,
    /// full lifetime total on the last-active day) — see `loadSessions`.
    struct SessionsBundle: Equatable {
        let report: [SessionPoint]
        let projects: [SessionPoint]
    }

    /// Unsplit, per-session facts shared by the report split (`parseSession`)
    /// and the project rollup, which stays unsplit — see the file doc
    /// comment. Parsed once per session so both consumers share one read of
    /// `summary.json` / `signals.json`.
    private struct RawSession {
        let model: String
        let activeAt: Date
        /// Full lifetime total `T = before + context`. Not monotonic:
        /// `contextTokensUsed` shrinks after compaction; we still report the
        /// current snapshot `T` (same as CodexBar).
        let lifetime: Int
        let project: ProjectIdentity?
    }

    /// Walk session directories and split each `signals.json` into report
    /// points (one per apportioned day, see `parseSession`) plus, when the
    /// session resolves to a project, a single unsplit project point on its
    /// last-active calendar day (from `summary.json` when present, else
    /// signals mtime) — project rollups aggregate by project, not by day, so
    /// splitting there adds nothing.
    static func loadSessions(
        root: URL,
        fileManager: FileManager = .default,
        now: Date = Date(),
        windowDays: Int = chartWindowDays,
        calendar: Calendar = .current) -> SessionsBundle
    {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return SessionsBundle(report: [], projects: []) }

        let startOfToday = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -(windowDays - 1), to: startOfToday)
            ?? startOfToday.addingTimeInterval(-Double(windowDays) * 86_400)
        let cutoffDay = calendar.startOfDay(for: cutoff)

        var report: [SessionPoint] = []
        var projects: [SessionPoint] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.lastPathComponent == "signals.json" else { continue }
            guard let raw = parseRawSession(
                signalsURL: url, sessionsRoot: root, fileManager: fileManager)
            else { continue }

            let day = calendar.startOfDay(for: raw.activeAt)
            guard day >= cutoffDay else { continue }

            let sessionDir = url.deletingLastPathComponent()
            report.append(contentsOf: reportPoints(
                raw: raw, sessionDir: sessionDir, day: day,
                cutoffDay: cutoffDay, today: startOfToday,
                fileManager: fileManager, calendar: calendar))

            if let project = raw.project {
                projects.append(SessionPoint(
                    day: day,
                    tokens: raw.lifetime,
                    usd: GrokModelPrice.estimateUSD(tokens: raw.lifetime, model: raw.model),
                    model: raw.model,
                    projectKey: project.key,
                    projectName: project.displayName))
            }
        }
        return SessionsBundle(report: report, projects: projects)
    }

    /// Parse one session into report points — one per apportioned day. A
    /// session's lifetime total `T = before + context` is split across the
    /// calendar days its `events.jsonl` shows a model response
    /// (`"type":"first_token"`) on, weighted by response count per day
    /// (largest-remainder rounded so the parts sum to exactly `T`); a day
    /// with no responses gets nothing, even if it is the session's
    /// last-active day. Falls back to a single point on the last-active day
    /// when `events.jsonl` is missing or has no usable events — see the file
    /// doc comment.
    static func parseSession(
        signalsURL: URL,
        sessionsRoot: URL,
        fileManager: FileManager = .default,
        calendar: Calendar = .current,
        now: Date = Date(),
        cutoff: Date) -> [SessionPoint]
    {
        guard let raw = parseRawSession(
            signalsURL: signalsURL, sessionsRoot: sessionsRoot, fileManager: fileManager)
        else { return [] }

        let cutoffDay = calendar.startOfDay(for: cutoff)
        let day = calendar.startOfDay(for: raw.activeAt)
        guard day >= cutoffDay else { return [] }

        let today = calendar.startOfDay(for: now)
        let sessionDir = signalsURL.deletingLastPathComponent()
        return reportPoints(
            raw: raw, sessionDir: sessionDir, day: day,
            cutoffDay: cutoffDay, today: today,
            fileManager: fileManager, calendar: calendar)
    }

    /// Read `summary.json` (model / last-active day / git root) and
    /// `signals.json` (model override, lifetime total) once. `nil` when
    /// signals are unreadable or the lifetime total is `<= 0`.
    private static func parseRawSession(
        signalsURL: URL,
        sessionsRoot: URL,
        fileManager: FileManager) -> RawSession?
    {
        let attrs = try? signalsURL.resourceValues(forKeys: [.contentModificationDateKey])
        let mtime = attrs?.contentModificationDate ?? Date.distantPast

        let sessionDir = signalsURL.deletingLastPathComponent()
        let summaryURL = sessionDir.appendingPathComponent("summary.json")
        var model = "grok-4.5"
        var activeAt = mtime
        var gitRootDir: String?

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
            gitRootDir = json["git_root_dir"] as? String
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
        let lifetime = max(0, before + context)
        guard lifetime > 0 else { return nil }

        let project = encodedDirectory(sessionsRoot: sessionsRoot, signalsURL: signalsURL)
            .flatMap { ProjectIdentity.grok(encodedDirectory: $0, gitRootDir: gitRootDir) }

        return RawSession(model: model, activeAt: activeAt, lifetime: lifetime, project: project)
    }

    /// Apportion `raw.lifetime` across the days `events.jsonl` shows
    /// responses on (see `inferenceDayCounts`), dropping any part outside
    /// `[cutoffDay, today]`. Falls back to a single point on `day` (the
    /// session's last-active day) when there are no usable events.
    private static func reportPoints(
        raw: RawSession,
        sessionDir: URL,
        day: Date,
        cutoffDay: Date,
        today: Date,
        fileManager: FileManager,
        calendar: Calendar) -> [SessionPoint]
    {
        let weights = inferenceDayCounts(
            sessionDir: sessionDir, fileManager: fileManager, calendar: calendar)
        let spread: [(day: Date, tokens: Int)] = weights.isEmpty
            ? [(day, raw.lifetime)]
            : apportion(total: raw.lifetime, weights: weights)

        return spread.compactMap { part in
            guard part.day >= cutoffDay, part.day <= today, part.tokens > 0 else { return nil }
            return SessionPoint(
                day: part.day,
                tokens: part.tokens,
                usd: GrokModelPrice.estimateUSD(tokens: part.tokens, model: raw.model),
                model: raw.model)
        }
    }

    /// Count of `"type":"first_token"` events per LOCAL calendar day, read
    /// from the session's `events.jsonl` (one JSON object per line, `ts` an
    /// RFC3339 UTC timestamp). `first_token` fires once per model response,
    /// so it tracks real inference effort more closely than `turn_started`
    /// (one turn can contain several tool-call round-trips). Empty when the
    /// file is missing or has no usable events — callers then fall back to
    /// the last-active-day attribution.
    private static func inferenceDayCounts(
        sessionDir: URL,
        fileManager: FileManager,
        calendar: Calendar) -> [Date: Int]
    {
        let eventsURL = sessionDir.appendingPathComponent("events.jsonl")
        guard let data = try? Data(contentsOf: eventsURL),
              let text = String(data: data, encoding: .utf8)
        else { return [:] }

        var counts: [Date: Int] = [:]
        text.enumerateLines { line, _ in
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "first_token",
                  let ts = json["ts"] as? String,
                  let parsed = parseISO8601(ts)
            else { return }
            let day = calendar.startOfDay(for: parsed)
            counts[day, default: 0] += 1
        }
        return counts
    }

    /// Split `total` across days weighted by `weights`, preserving the exact
    /// sum via largest-remainder rounding: integer-divide per day, then hand
    /// the leftover units to the days with the largest remainders (ties
    /// broken by date, for scan-to-scan stability). `total <= 0` or an
    /// all-zero `weights` yields no parts.
    private static func apportion(
        total: Int, weights: [Date: Int]) -> [(day: Date, tokens: Int)]
    {
        let weightSum = weights.values.reduce(0, +)
        guard total > 0, weightSum > 0 else { return [] }

        var parts: [(day: Date, share: Int, remainder: Int)] = weights.map { day, weight in
            let exact = total * weight
            return (day, exact / weightSum, exact % weightSum)
        }

        var leftover = total - parts.reduce(0) { $0 + $1.share }
        parts.sort { lhs, rhs in
            lhs.remainder != rhs.remainder ? lhs.remainder > rhs.remainder : lhs.day < rhs.day
        }
        for index in parts.indices where leftover > 0 {
            parts[index].share += 1
            leftover -= 1
        }

        return parts.filter { $0.share > 0 }.map { (day: $0.day, tokens: $0.share) }
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

    static func buildProjects(
        sessions: [SessionPoint],
        calendar: Calendar = .current
    ) -> [ProjectUsageRecord] {
        struct ModelTotal {
            var usd: Double = 0
            var tokens: Int = 0
        }
        struct ProjectTotal {
            var name: String
            var days: [Date: [String: ModelTotal]] = [:]
        }

        var projects: [String: ProjectTotal] = [:]
        for session in sessions {
            guard let key = session.projectKey, let rawName = session.projectName else { continue }
            let safeKey = ProjectIdentity.safeKey(key)
            guard safeKey == key else { continue }
            let name = ProjectIdentity.safeDisplayName(rawName, key: key)
            var project = projects[key] ?? ProjectTotal(name: name)
            if name < project.name { project.name = name }
            let day = calendar.startOfDay(for: session.day)
            var models = project.days[day] ?? [:]
            var model = models[session.model] ?? ModelTotal()
            model.usd += session.usd
            model.tokens += session.tokens
            models[session.model] = model
            project.days[day] = models
            projects[key] = project
        }

        return projects.keys.sorted().compactMap { key -> ProjectUsageRecord? in
            guard let project = projects[key] else { return nil }
            let daily = project.days.keys.sorted().map { day in
                let models = (project.days[day] ?? [:]).map {
                    ProjectModelUsage(
                        name: ProjectIdentity.safeModelName($0.key),
                        usd: $0.value.usd,
                        tokens: $0.value.tokens)
                }.sorted {
                    if $0.usd != $1.usd { return $0.usd > $1.usd }
                    if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
                    return $0.name < $1.name
                }
                return ProjectDailyUsage(
                    date: day,
                    usd: models.reduce(0) { $0 + $1.usd },
                    tokens: models.reduce(0) { $0 + $1.tokens },
                    models: models)
            }
            guard !daily.isEmpty else { return nil }
            return ProjectUsageRecord(
                source: .grok,
                projectKey: key,
                displayName: project.name,
                attribution: .derived,
                daily: daily)
        }
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

    private static func encodedDirectory(sessionsRoot: URL, signalsURL: URL) -> String? {
        let root = sessionsRoot.standardizedFileURL.pathComponents
        let path = signalsURL.standardizedFileURL.pathComponents
        guard path.count == root.count + 3,
              Array(path.prefix(root.count)) == root,
              path.last == "signals.json"
        else { return nil }
        return path[root.count]
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: raw)
    }
}
