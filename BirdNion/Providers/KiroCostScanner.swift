import Foundation
import SQLite3

// MARK: - Models

/// Token/cost rolled up from local Kiro CLI conversation history. Three
/// storage generations are scanned:
///   - `~/.kiro/sessions/cli/<id>.json` — current TUI kiro-cli; per-turn
///     REAL billed credits (`metering_usage`) + context percentages, while
///     the old SQLite tables stay empty.
///   - `~/Library/Application Support/kiro-cli/data.sqlite3` — older CLIs.
///   - `~/.kiro_sessions/*.json` archives (optional).
/// USD is real (credits × Kiro's $0.04 add-on price) for the sessions
/// source; SQLite-era numbers stay estimates (chars÷4 + price table).
struct KiroCostSummary: Equatable {
    let todayUSD: Double
    let todayTokens: Int
    let last30USD: Double
    let last30Tokens: Int

    var isEmpty: Bool { todayTokens == 0 && last30Tokens == 0 }
}

struct KiroDailyModel: Equatable, Identifiable {
    let name: String
    let usd: Double
    let tokens: Int
    var id: String { name }
}

struct KiroDailyUsage: Equatable, Identifiable {
    let date: Date
    let usd: Double
    let tokens: Int
    let models: [KiroDailyModel]
    var id: Date { date }
}

/// Full report for the Kiro tab chart. Shape mirrors `GrokUsageReport`.
struct KiroUsageReport: Equatable {
    let todayUSD: Double
    let todayTokens: Int
    let last30USD: Double
    let last30Tokens: Int
    /// Contiguous `chartWindowDays` daily buckets, oldest → newest.
    let daily: [KiroDailyUsage]
    let topModel: String?

    var isEmpty: Bool {
        last30Tokens == 0 && last30USD <= 0 && todayTokens == 0 && todayUSD <= 0
    }

    var asSummary: KiroCostSummary {
        KiroCostSummary(todayUSD: todayUSD, todayTokens: todayTokens,
                        last30USD: last30USD, last30Tokens: last30Tokens)
    }
}

// MARK: - Pricing

/// Cache-aware Anthropic-style rates ($/MTok) for models Kiro commonly hosts.
/// Write / read / output — 5-minute cache write pricing.
struct KiroModelPrice {
    let writePerM: Double
    let readPerM: Double
    let outputPerM: Double

    static func price(for model: String?) -> KiroModelPrice {
        let m = (model ?? "").lowercased()
        if m.contains("opus-4.6") || m.contains("opus-4-6")
            || m.contains("opus-4.5") || m.contains("opus-4-5")
        {
            return KiroModelPrice(writePerM: 6.25, readPerM: 0.50, outputPerM: 25)
        }
        if m.contains("opus") {
            return KiroModelPrice(writePerM: 18.75, readPerM: 1.50, outputPerM: 75)
        }
        if m.contains("sonnet") {
            return KiroModelPrice(writePerM: 3.75, readPerM: 0.30, outputPerM: 15)
        }
        if m.contains("haiku") {
            return KiroModelPrice(writePerM: 1.25, readPerM: 0.10, outputPerM: 5)
        }
        // Default: Opus 4.5 rates so free/unknown models stay visible.
        return KiroModelPrice(writePerM: 6.25, readPerM: 0.50, outputPerM: 25)
    }

    static func estimateUSD(cacheWrite: Int, cacheRead: Int, output: Int, model: String?) -> Double {
        let p = price(for: model)
        return (Double(cacheWrite) * p.writePerM
                + Double(cacheRead) * p.readPerM
                + Double(output) * p.outputPerM) / 1_000_000.0
    }

    /// Kiro bills in credits; add-on/overage credits are $0.04 each
    /// (kiro.dev/pricing) — converts real metered credits to USD.
    static let usdPerCredit = 0.04
}

// MARK: - Scanner

/// Walks Kiro CLI SQLite conversations (+ optional archive) and builds a
/// 90-day daily usage report for the Kiro tab chart.
enum KiroCostScanner {
    private static let cacheTTL: TimeInterval = 300
    static let chartWindowDays = 90
    static let charsPerToken = 4

    private actor Cache {
        static let shared = Cache()
        private var reportEntry: (at: Date, value: KiroUsageReport)?
        func validReport(now: Date, ttl: TimeInterval) -> KiroUsageReport? {
            guard let reportEntry, now.timeIntervalSince(reportEntry.at) < ttl else { return nil }
            return reportEntry.value
        }
        func storeReport(_ value: KiroUsageReport, at: Date) { reportEntry = (at, value) }
    }

    /// Cached full report. Merges with `CostHistoryStore` so cleared sessions
    /// do not wipe past bars.
    static func usageReport(now: Date = Date()) async -> KiroUsageReport? {
        if let cached = await Cache.shared.validReport(now: now, ttl: cacheTTL) { return cached }
        let value = await Task.detached(priority: .utility) {
            let scanDays = CostHistoryStore.scanBackDays(source: .kiro, now: now)
            let live = scanFull(now: now, windowDays: scanDays)
            let liveDays = live.daily.map {
                ($0.date, $0.usd, $0.tokens,
                 $0.models.map { (name: $0.name, usd: $0.usd, tokens: $0.tokens) })
            }
            let window = CostHistoryStore.apply(
                source: .kiro,
                liveDays: liveDays,
                now: now,
                windowDays: chartWindowDays)
            return CostHistoryStore.makeKiroReport(window: window)
        }.value
        await Cache.shared.storeReport(value, at: now)
        return value
    }

    /// Instant seed from persisted history — no SQLite scan.
    static func seededReport(now: Date = Date(),
                             url: URL = CostHistoryStore.historyURL()) async -> KiroUsageReport? {
        await Task.detached(priority: .userInitiated) {
            let window = CostHistoryStore.window(
                source: .kiro, now: now, windowDays: chartWindowDays, url: url)
            guard window.contains(where: { $0.tokens > 0 || $0.usd > 0 }) else { return nil }
            return CostHistoryStore.makeKiroReport(window: window)
        }.value
    }

    // MARK: - Paths

    /// Overrideable for tests. Defaults: CLI SQLite + archive dir.
    static func defaultCLIDatabaseURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        #if os(macOS)
        home.appendingPathComponent(
            "Library/Application Support/kiro-cli/data.sqlite3", isDirectory: false)
        #else
        home.appendingPathComponent(".local/share/kiro-cli/data.sqlite3", isDirectory: false)
        #endif
    }

    static func defaultArchiveURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".kiro_sessions", isDirectory: true)
    }

    /// Current TUI kiro-cli session store (`cli/<id>.json` sidecars).
    static func defaultSessionsURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".kiro/sessions", isDirectory: true)
    }

    // MARK: - Session points

    struct SessionPoint: Equatable {
        let day: Date
        let tokens: Int
        let usd: Double
        let model: String
    }

    /// Pure filesystem + SQLite scan — unit-testable via path overrides.
    static func scanFull(
        cliDBURL: URL? = nil,
        archiveURL: URL? = nil,
        sessionsURL: URL? = nil,
        fileManager: FileManager = .default,
        now: Date = Date(),
        windowDays: Int = chartWindowDays,
        calendar: Calendar = .current) -> KiroUsageReport
    {
        let home = fileManager.homeDirectoryForCurrentUser
        let db = cliDBURL ?? defaultCLIDatabaseURL(home: home)
        let archive = archiveURL ?? defaultArchiveURL(home: home)
        let sessions = sessionsURL ?? defaultSessionsURL(home: home)
        let points = loadPoints(
            cliDBURL: db,
            archiveURL: archive,
            sessionsURL: sessions,
            fileManager: fileManager,
            now: now,
            windowDays: windowDays,
            calendar: calendar)
        return buildReport(sessions: points, now: now, windowDays: windowDays, calendar: calendar)
    }

    static func loadPoints(
        cliDBURL: URL,
        archiveURL: URL,
        sessionsURL: URL,
        fileManager: FileManager = .default,
        now: Date = Date(),
        windowDays: Int = chartWindowDays,
        calendar: Calendar = .current) -> [SessionPoint]
    {
        let startOfToday = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -(windowDays - 1), to: startOfToday)
            ?? startOfToday.addingTimeInterval(-Double(windowDays) * 86_400)
        let cutoffMs = Int64(cutoff.timeIntervalSince1970 * 1000)

        // Deduplicate by conversation/session id (prefer newer updated_at).
        var byID: [String: (updated: Int64, points: [SessionPoint])] = [:]

        for snap in loadArchived(archiveURL: archiveURL, fileManager: fileManager) {
            guard let cid = snap.conversationID, !cid.isEmpty else { continue }
            guard snap.updatedAtMs >= cutoffMs else { continue }
            let points = parseConversation(
                data: snap.value,
                fallbackCreatedMs: snap.createdAtMs,
                cutoff: cutoff,
                calendar: calendar)
            guard !points.isEmpty else { continue }
            if let existing = byID[cid], existing.updated >= snap.updatedAtMs { continue }
            byID[cid] = (snap.updatedAtMs, points)
        }

        for snap in loadFromSQLite(dbURL: cliDBURL, cutoffMs: cutoffMs) {
            guard let cid = snap.conversationID, !cid.isEmpty else { continue }
            let points = parseConversation(
                data: snap.value,
                fallbackCreatedMs: snap.createdAtMs,
                cutoff: cutoff,
                calendar: calendar)
            guard !points.isEmpty else { continue }
            if let existing = byID[cid], existing.updated >= snap.updatedAtMs { continue }
            byID[cid] = (snap.updatedAtMs, points)
        }

        // Current TUI kiro-cli: ~/.kiro/sessions/cli/<id>.json sidecars.
        for snap in loadCLISessions(
            sessionsURL: sessionsURL, fileManager: fileManager,
            cutoff: cutoff, cutoffMs: cutoffMs, calendar: calendar)
        {
            if let existing = byID[snap.id], existing.updated >= snap.updatedMs { continue }
            byID[snap.id] = (snap.updatedMs, snap.points)
        }

        return byID.values.flatMap(\.points)
    }

    // MARK: - Sources

    private struct ConversationSnapshot {
        let conversationID: String?
        let createdAtMs: Int64
        let updatedAtMs: Int64
        let value: [String: Any]
    }

    private static func loadArchived(archiveURL: URL,
                                     fileManager: FileManager) -> [ConversationSnapshot] {
        guard fileManager.fileExists(atPath: archiveURL.path),
              let files = try? fileManager.contentsOfDirectory(
                at: archiveURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        else { return [] }
        var out: [ConversationSnapshot] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let cid = json["conversation_id"] as? String
            let created = int64Value(json["created_at"])
            let updated = int64Value(json["updated_at"])
            let value: [String: Any]
            if let nested = json["value"] as? [String: Any] {
                value = nested
            } else {
                value = json
            }
            out.append(ConversationSnapshot(
                conversationID: cid ?? (value["conversation_id"] as? String),
                createdAtMs: created,
                updatedAtMs: updated,
                value: value))
        }
        return out
    }

    private static func loadFromSQLite(dbURL: URL, cutoffMs: Int64) -> [ConversationSnapshot] {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }
        var db: OpaquePointer?
        // immutable=1 so a live kiro-cli write doesn't block us.
        let uri = "file:\(dbURL.path)?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db
        else {
            if db != nil { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)

        var snaps: [ConversationSnapshot] = []

        // conversations_v2 (older kiro-cli)
        snaps += queryConversationsV2(db: db, cutoffMs: cutoffMs)
        // conversations (kiro-cli 2.0.1+)
        snaps += queryConversationsV1(db: db, cutoffMs: cutoffMs)
        return snaps
    }

    private static func queryConversationsV2(db: OpaquePointer,
                                             cutoffMs: Int64) -> [ConversationSnapshot] {
        let sql = """
        SELECT conversation_id, created_at, updated_at, value
        FROM conversations_v2
        WHERE updated_at >= ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoffMs)
        var out: [ConversationSnapshot] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let cid = stringColumn(stmt, 0)
            let created = sqlite3_column_int64(stmt, 1)
            let updated = sqlite3_column_int64(stmt, 2)
            guard let raw = stringColumn(stmt, 3),
                  let data = raw.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            out.append(ConversationSnapshot(
                conversationID: cid,
                createdAtMs: created,
                updatedAtMs: updated,
                value: value))
        }
        return out
    }

    private static func queryConversationsV1(db: OpaquePointer,
                                             cutoffMs: Int64) -> [ConversationSnapshot] {
        let sql = "SELECT value FROM conversations"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [ConversationSnapshot] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let raw = stringColumn(stmt, 0),
                  let data = raw.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let cid = value["conversation_id"] as? String
            let history = value["history"] as? [[String: Any]] ?? []
            guard !history.isEmpty else { continue }
            let first = (history.first?["request_metadata"] as? [String: Any])
                .flatMap { int64Value($0["request_start_timestamp_ms"]) } ?? 0
            let last = (history.last?["request_metadata"] as? [String: Any])
                .flatMap { int64Value($0["request_start_timestamp_ms"]) } ?? first
            guard last >= cutoffMs else { continue }
            out.append(ConversationSnapshot(
                conversationID: cid,
                createdAtMs: first,
                updatedAtMs: last,
                value: value))
        }
        return out
    }

    // MARK: - TUI kiro-cli sessions (~/.kiro/sessions/cli)

    /// Current TUI kiro-cli stores each session as `cli/<id>.json` (metadata +
    /// per-turn metering) next to a `<id>.jsonl` transcript; the old SQLite
    /// tables stay empty on those builds.
    private static func loadCLISessions(
        sessionsURL: URL,
        fileManager: FileManager,
        cutoff: Date,
        cutoffMs: Int64,
        calendar: Calendar) -> [(id: String, updatedMs: Int64, points: [SessionPoint])]
    {
        let cliDir = sessionsURL.appendingPathComponent("cli", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: cliDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        var out: [(id: String, updatedMs: Int64, points: [SessionPoint])] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let sid = (json["session_id"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            let updatedMs = parseISODate(json["updated_at"] as? String)
                .map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
            if updatedMs > 0, updatedMs < cutoffMs { continue }
            let points = parseCLISessionSidecar(json, cutoff: cutoff, calendar: calendar)
            guard !points.isEmpty else { continue }
            out.append((sid, updatedMs, points))
        }
        return out
    }

    /// One sidecar → per-day SessionPoints. USD is REAL (per-turn
    /// `metering_usage` credits × $0.04); tokens prefer the CLI's exact
    /// counts and fall back to context-window growth
    /// (Δ`context_usage_percentage` × window size) when they are zeroed.
    static func parseCLISessionSidecar(
        _ json: [String: Any],
        cutoff: Date,
        calendar: Calendar = .current) -> [SessionPoint]
    {
        guard let state = json["session_state"] as? [String: Any],
              let convMeta = state["conversation_metadata"] as? [String: Any],
              let turns = convMeta["user_turn_metadatas"] as? [[String: Any]],
              !turns.isEmpty
        else { return [] }

        let modelInfo = (state["rts_model_state"] as? [String: Any])?["model_info"] as? [String: Any]
        let modelID = (modelInfo?["model_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (modelID?.isEmpty == false) ? modelID! : "kiro"
        let rawWindow = Int(int64Value(modelInfo?["context_window_tokens"]))
        let contextWindow = rawWindow > 0 ? rawWindow : 200_000

        let sessionCreated = parseISODate(json["created_at"] as? String)

        var prevPct = 0.0
        var buckets: [Date: (tokens: Int, usd: Double)] = [:]
        for turn in turns {
            // Real billed credits for the turn (one entry per request).
            var credits = 0.0
            for entry in (turn["metering_usage"] as? [[String: Any]] ?? []) {
                let unit = (entry["unit"] as? String ?? "").lowercased()
                guard unit.contains("credit") else { continue }
                credits += doubleValue(entry["value"])
            }
            let usd = credits * KiroModelPrice.usdPerCredit

            // Exact token counts when the CLI populates them; else grow-of-
            // context estimate. `context_usage_percentage` is cumulative, so
            // the per-turn delta is what this turn added (clamped: compaction
            // can shrink it).
            var tokens = Int(int64Value(turn["input_token_count"]))
                + Int(int64Value(turn["output_token_count"]))
            let pct = doubleValue(turn["context_usage_percentage"])
            if tokens == 0, pct > 0 {
                let delta = max(0, pct - prevPct)
                tokens = Int((delta / 100.0 * Double(contextWindow)).rounded())
            }
            if pct > 0 { prevPct = pct }

            guard let activeAt = parseISODate(turn["end_timestamp"] as? String) ?? sessionCreated
            else { continue }
            let day = calendar.startOfDay(for: activeAt)
            guard day >= calendar.startOfDay(for: cutoff) else { continue }
            guard tokens > 0 || usd > 0 else { continue }

            var acc = buckets[day] ?? (0, 0)
            acc.tokens += tokens
            acc.usd += usd
            buckets[day] = acc
        }

        return buckets.map {
            SessionPoint(day: $0.key, tokens: $0.value.tokens, usd: $0.value.usd, model: model)
        }
    }

    /// ISO8601 with or without fractional seconds ("2026-07-15T06:20:44.636576Z").
    static func parseISODate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: raw)
    }

    private static func doubleValue(_ raw: Any?) -> Double {
        switch raw {
        case let d as Double: return d
        case let n as NSNumber: return n.doubleValue
        case let i as Int: return Double(i)
        case let s as String: return Double(s) ?? 0
        default: return 0
        }
    }

    // MARK: - Parse conversation turns

    /// Expand one conversation into per-day SessionPoints (one per model/day).
    static func parseConversation(
        data: [String: Any],
        fallbackCreatedMs: Int64,
        cutoff: Date,
        calendar: Calendar = .current) -> [SessionPoint]
    {
        let turns = data["history"] as? [[String: Any]] ?? []
        guard !turns.isEmpty else { return [] }

        // Compact summary is re-sent after compaction — seed cumulative cache.
        let summary = data["latest_summary"]
        var cumulative = textTokenEstimate(summary)
        var prevAsst = 0

        // day → model → (tokens, usd)
        var buckets: [Date: [String: (tokens: Int, usd: Double)]] = [:]

        for (i, turn) in turns.enumerated() {
            let meta = turn["request_metadata"] as? [String: Any] ?? [:]
            let model = (meta["model_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let modelName = (model?.isEmpty == false) ? model! : "kiro"

            let userTok = textTokenEstimate(turn["user"]) + imageTokenEstimate(turn["user"])
            let asstTok = textTokenEstimate(turn["assistant"])
            // Output tokens: accurate chunk count when present.
            let outTok: Int
            if let chunks = meta["time_between_chunks"] as? [Any] {
                outTok = chunks.count
            } else {
                outTok = asstTok
            }

            let cr = i > 0 ? cumulative : 0
            let cw = userTok + (i > 0 ? prevAsst : 0)
            let totalTokens = cw + cr + outTok
            let usd = KiroModelPrice.estimateUSD(
                cacheWrite: cw, cacheRead: cr, output: outTok, model: modelName)

            cumulative += userTok + asstTok
            prevAsst = asstTok

            let tsMs = int64Value(meta["request_start_timestamp_ms"])
            let activeAt: Date
            if tsMs > 0 {
                activeAt = Date(timeIntervalSince1970: Double(tsMs) / 1000.0)
            } else if fallbackCreatedMs > 0 {
                activeAt = Date(timeIntervalSince1970: Double(fallbackCreatedMs) / 1000.0)
            } else {
                continue
            }
            let day = calendar.startOfDay(for: activeAt)
            guard day >= calendar.startOfDay(for: cutoff) else { continue }
            guard totalTokens > 0 || usd > 0 else { continue }

            var models = buckets[day] ?? [:]
            var acc = models[modelName] ?? (0, 0)
            acc.tokens += totalTokens
            acc.usd += usd
            models[modelName] = acc
            buckets[day] = models
        }

        var points: [SessionPoint] = []
        for (day, models) in buckets {
            for (model, stats) in models where stats.tokens > 0 || stats.usd > 0 {
                points.append(SessionPoint(
                    day: day, tokens: stats.tokens, usd: stats.usd, model: model))
            }
        }
        return points
    }

    // MARK: - Report build

    static func buildReport(
        sessions: [SessionPoint],
        now: Date = Date(),
        windowDays: Int = chartWindowDays,
        calendar: Calendar = .current) -> KiroUsageReport
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

        var daily: [KiroDailyUsage] = []
        daily.reserveCapacity(windowDays)
        for offset in stride(from: windowDays - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: startOfToday)
            else { continue }
            let acc = buckets[day]
            var dayModels: [KiroDailyModel] = []
            if let models = acc?.models {
                for (name, stats) in models where stats.tokens > 0 || stats.usd > 0 {
                    dayModels.append(KiroDailyModel(name: name, usd: stats.usd, tokens: stats.tokens))
                }
                // Token-first ranking (matches All chart preference).
                dayModels.sort { lhs, rhs in
                    if lhs.tokens == rhs.tokens { return lhs.usd > rhs.usd }
                    return lhs.tokens > rhs.tokens
                }
                if dayModels.count > 5 { dayModels = Array(dayModels.prefix(5)) }
            }
            daily.append(KiroDailyUsage(
                date: day,
                usd: acc?.usd ?? 0,
                tokens: acc?.tokens ?? 0,
                models: dayModels))
        }

        let last30 = daily.suffix(30)
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
            $0.value.tokens == $1.value.tokens
                ? $0.value.usd < $1.value.usd
                : $0.value.tokens < $1.value.tokens
        }?.key

        return KiroUsageReport(
            todayUSD: todayBucket?.usd ?? 0,
            todayTokens: todayBucket?.tokens ?? 0,
            last30USD: last30.map(\.usd).reduce(0, +),
            last30Tokens: last30.map(\.tokens).reduce(0, +),
            daily: daily,
            topModel: topModel)
    }

    // MARK: - Text / token helpers

    /// Approximate tokens from textual content (chars ÷ 4), excluding base64 images.
    static func textTokenEstimate(_ field: Any?) -> Int {
        guard let field else { return 0 }
        if let s = field as? String {
            return max(0, s.count / charsPerToken)
        }
        if let dict = field as? [String: Any] {
            var total = 0
            for (k, v) in dict where k != "images" {
                total += textTokenEstimate(v)
            }
            return total
        }
        if let arr = field as? [Any] {
            return arr.reduce(0) { $0 + textTokenEstimate($1) }
        }
        // Numbers / bools — ignore
        if field is NSNumber { return 0 }
        return max(0, "\(field)".count / charsPerToken)
    }

    /// Rough vision tokens for images (~1600 each when dimensions unknown).
    static func imageTokenEstimate(_ field: Any?) -> Int {
        guard let dict = field as? [String: Any],
              let images = dict["images"] as? [Any], !images.isEmpty
        else { return 0 }
        return images.count * 1600
    }

    private static func stringColumn(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: cStr)
    }

    private static func int64Value(_ raw: Any?) -> Int64 {
        switch raw {
        case let i as Int: return Int64(i)
        case let i as Int64: return i
        case let n as NSNumber: return n.int64Value
        case let d as Double: return Int64(d)
        case let s as String: return Int64(s) ?? 0
        default: return 0
        }
    }
}
