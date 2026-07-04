import Foundation

/// Token cost rolled up from local Claude Code session logs. Mirrors
/// `CodexCostScanner` but reads `~/.claude/projects/<encoded-path>/<uuid>.jsonl`
/// instead of `~/.codex/sessions/**/rollout-*.jsonl`. Token counts are exact
/// (read straight from each `message.usage` block); the dollar amount is an
/// estimate (tokens × per-model Anthropic price table), so the UI prefixes
/// it with "≈" — same convention as Codex.
struct ClaudeCostSummary: Equatable {
    let todayUSD: Double
    let todayTokens: Int
    let last30USD: Double
    let last30Tokens: Int

    var isEmpty: Bool { todayTokens == 0 && last30Tokens == 0 }
}

/// One day's worth of Claude usage rolled up across every session log that
/// ran in that calendar day (local timezone). Tokens are exact sums of
/// `message.usage`; USD is the price-table estimate per-model.
/// One model's slice of a single day — powers the hover breakdown list.
struct ClaudeDailyModel: Equatable, Identifiable {
    let name: String
    let usd: Double
    let tokens: Int
    var id: String { name }
}

struct ClaudeDailyUsage: Equatable, Identifiable {
    let date: Date   // startOfDay in local tz
    let usd: Double
    let tokens: Int
    /// Per-model split for this day, highest token count first (top 5).
    let models: [ClaudeDailyModel]
    var id: Date { date }
}

/// One clock-hour of Claude usage within the trailing 24 h — powers the
/// "last 24 hours" card on the All tab. Claude logs carry per-line
/// timestamps, so hourly resolution is exact (unlike Codex's day-only logs).
struct ClaudeHourlyUsage: Equatable, Identifiable {
    let date: Date   // start of the hour in local tz
    let usd: Double
    let tokens: Int
    var id: Date { date }
}

/// Full usage report: the existing today/last30 totals plus per-day buckets
/// for the chart/heatmap and the most-used model. Built from the same scan
/// pass that produces `ClaudeCostSummary` so there's no extra I/O cost.
/// The daily window spans `ClaudeCostScanner.historyDays` (90) for the
/// combined heatmap; the `last30*` totals stay strictly 30-day.
struct ClaudeUsageReport: Equatable {
    let todayUSD: Double
    let todayTokens: Int
    let last30USD: Double
    let last30Tokens: Int
    /// `ClaudeCostScanner.historyDays` daily buckets, oldest → newest, one
    /// entry per calendar day. Days with no activity get zero entries (so
    /// the chart can show gaps).
    let daily: [ClaudeDailyUsage]
    /// 24 hour buckets for the trailing 24 h, oldest → newest, ending at the
    /// current clock hour. Defaulted so memberwise call sites that don't
    /// care about the hourly view stay source-compatible.
    var hourly: [ClaudeHourlyUsage] = []
    /// Most-used model across the 30-day window (by token count). nil when
    /// no model information was logged.
    let topModel: String?

    var isEmpty: Bool { last30Tokens == 0 }

    /// Convenience initializer for the panel's smaller "today / 30 days" rows
    /// — strips the chart-only fields.
    var asSummary: ClaudeCostSummary {
        ClaudeCostSummary(todayUSD: todayUSD, todayTokens: todayTokens,
                          last30USD: last30USD, last30Tokens: last30Tokens)
    }
}

/// Per-million-token prices (USD) for Anthropic models. Anthropic splits
/// input into fresh / cache-write / cache-read (Codex only has fresh + cached
/// read). Updated 2026-06; revisit when Anthropic revises pricing.
struct ClaudeModelPrice {
    let inputPerM: Double
    let cacheWritePerM: Double
    let cacheReadPerM: Double
    let outputPerM: Double

    /// Per-model prices mirroring CodexBar's `CostUsagePricing` (opus-4-x,
    /// sonnet-4-x, haiku-4-x). Returns nil for non-Claude models (e.g. MiniMax
    /// routed through Claude Code) so their tokens are still counted but cost
    /// $0 — exactly how CodexBar's chart behaves.
    static func price(for model: String) -> ClaudeModelPrice? {
        let m = model.lowercased()
        // Opus 4.x — $5 / $6.25 / $0.50 / $25 per-M (NOT the old Opus-3 $15/$75).
        if m.contains("opus") {
            return ClaudeModelPrice(inputPerM: 5.0, cacheWritePerM: 6.25,
                                    cacheReadPerM: 0.50, outputPerM: 25.0)
        }
        // Haiku 4.x — $1 / $1.25 / $0.10 / $5 per-M.
        if m.contains("haiku") {
            return ClaudeModelPrice(inputPerM: 1.0, cacheWritePerM: 1.25,
                                    cacheReadPerM: 0.10, outputPerM: 5.0)
        }
        // Sonnet 4.x / 3.x — $3 / $3.75 / $0.30 / $15 per-M.
        if m.contains("sonnet") {
            return ClaudeModelPrice(inputPerM: 3.0, cacheWritePerM: 3.75,
                                    cacheReadPerM: 0.30, outputPerM: 15.0)
        }
        return nil  // non-Claude model — tokens counted, cost $0
    }
}

/// Token usage recorded in one assistant message.
private struct ClaudeMessageUsage {
    let inputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let outputTokens: Int
    var totalTokens: Int { inputTokens + outputTokens }
}

/// Scans the local Claude Code session jsonls and sums token cost for today
/// and the trailing 30 days. Pure file I/O, no network. Results cached
/// briefly so the panel doesn't re-walk the entire project tree on every
/// refresh. Mirrors `CodexCostScanner` (which has identical structure).
enum ClaudeCostScanner {
    private static let cacheTTL: TimeInterval = 300
    /// Scan window for the per-day buckets (feeds the 90-day heatmap on the
    /// All tab). The `last30*` totals keep their own 30-day cutoff so the
    /// Claude tab numbers don't change with this window.
    static let historyDays = 90

    /// Actor-isolated cache so brief memoization is safe across tasks.
    private actor Cache {
        static let shared = Cache()
        private var entry: (at: Date, value: ClaudeCostSummary)?
        private var fullEntry: (at: Date, value: ClaudeUsageReport)?
        func valid(now: Date, ttl: TimeInterval) -> ClaudeCostSummary? {
            guard let entry, now.timeIntervalSince(entry.at) < ttl else { return nil }
            return entry.value
        }
        func store(_ value: ClaudeCostSummary, at: Date) { entry = (at, value) }
        func validFullReport(now: Date, ttl: TimeInterval) -> ClaudeUsageReport? {
            guard let fullEntry, now.timeIntervalSince(fullEntry.at) < ttl else { return nil }
            return fullEntry.value
        }
        func storeFull(_ value: ClaudeUsageReport, at: Date) { fullEntry = (at, value) }
    }

    static func defaultProjectsDir() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    }

    /// All project roots to scan (CodexBar parity). When `CLAUDE_CONFIG_DIR` is
    /// set it wins (comma-separated, each entry's `projects/` subdir); otherwise
    /// BOTH `~/.config/claude/projects` and `~/.claude/projects` are scanned —
    /// fixing the "reports 0 tokens" case when sessions live under `.config`.
    static func defaultProjectsRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        if let raw = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            var roots: [URL] = []
            for part in raw.split(separator: ",") {
                let p = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !p.isEmpty else { continue }
                let url = URL(fileURLWithPath: p)
                roots.append(url.lastPathComponent == "projects"
                             ? url : url.appendingPathComponent("projects", isDirectory: true))
            }
            if !roots.isEmpty { return roots }
        }
        let home = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory())
        return [
            home.appendingPathComponent(".config/claude/projects", isDirectory: true),
            home.appendingPathComponent(".claude/projects", isDirectory: true),
        ]
    }

    /// Cached, off-main scan. Returns nil only if no projects root is readable.
    static func summary(roots: [URL] = defaultProjectsRoots(), now: Date = Date()) async -> ClaudeCostSummary? {
        if let cached = await Cache.shared.valid(now: now, ttl: cacheTTL) { return cached }
        let value = await Task.detached(priority: .utility) {
            scan(roots: roots, now: now)
        }.value
        if let value { await Cache.shared.store(value, at: now) }
        return value
    }

    /// Same scan as `summary` but returns the full report (per-day buckets +
    /// top model). Used by the popover chart. The result is cached under the
    /// same key so a call to `summary` followed by `usageReport` only does
    /// the file walk once.
    static func usageReport(roots: [URL] = defaultProjectsRoots(),
                            now: Date = Date()) async -> ClaudeUsageReport? {
        if let cached = await Cache.shared.validFullReport(now: now, ttl: cacheTTL) {
            return cached
        }
        let value = await Task.detached(priority: .utility) {
            scanFull(roots: roots, now: now)
        }.value
        if let value { await Cache.shared.storeFull(value, at: now) }
        return value
    }

    // MARK: - Scanning

    static func scan(roots: [URL], now: Date) -> ClaudeCostSummary? {
        scanFull(roots: roots, now: now)?.asSummary
    }

    /// Walks every session jsonl once and produces both the aggregate totals
    /// and the per-day bucket array. Buckets are keyed by startOfDay in the
    /// local calendar so the chart bars line up with "today" / "yesterday"
    /// labels the UI uses.
    static func scanFull(roots: [URL], now: Date) -> ClaudeUsageReport? {
        let fm = FileManager.default
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let cutoff = now.addingTimeInterval(-TimeInterval(historyDays) * 86_400)
        // Separate 30-day cutoff for the totals — the scan window is wider
        // (90d, for the heatmap) but `last30*` must stay a strict 30 days.
        let last30Cutoff = now.addingTimeInterval(-30 * 86_400)

        // Collect entries across every root, then dedup by messageId:requestId
        // (the same assistant message is logged in both the parent session and
        // any subagent/sidechain file — summing twice over-counts). Keep-last
        // wins; entries without IDs are kept individually. Mirrors CodexBar.
        var keyed: [String: DayEntry] = [:]
        var unkeyed: [DayEntry] = []
        var anyRoot = false

        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            anyRoot = true
            var files: [URL] = []
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                // Fast-path skip: files untouched in 30 days hold no usable line.
                guard mtime >= cutoff else { continue }
                files.append(url)
            }
            // Sorted so keep-last dedup is deterministic across runs.
            for url in files.sorted(by: { $0.path < $1.path }) {
                for entry in scanFileWithDay(url, cutoff: cutoff, calendar: calendar) {
                    if let key = entry.key { keyed[key] = entry } else { unkeyed.append(entry) }
                }
            }
        }
        guard anyRoot else { return nil }

        var todayUSD = 0.0, todayTokens = 0
        var monthUSD = 0.0, monthTokens = 0
        // Per-day buckets indexed by startOfDay for O(1) lookup.
        var buckets: [Date: DailyAccumulator] = [:]
        // Per-hour buckets for the trailing 24 h (keyed by hour start).
        let hourCutoff = now.addingTimeInterval(-24 * 3_600)
        var hourBuckets: [Date: (usd: Double, tokens: Int)] = [:]
        // Model vote counts — most-used model across the 30-day window.
        var modelVotes: [String: Int] = [:]

        for entry in keyed.values + unkeyed {
            let entryDate = entry.date
            guard entryDate >= cutoff else { continue }
            let existing = buckets[entryDate] ?? DailyAccumulator(date: entryDate)
            existing.usd += entry.usd
            existing.tokens += entry.tokens
            var ma = existing.models[entry.model] ?? ModelAccum()
            ma.usd += entry.usd
            ma.tokens += entry.tokens
            existing.models[entry.model] = ma
            buckets[entryDate] = existing

            // Totals + top-model vote keep 30-day semantics even though the
            // bucket window is wider.
            if entryDate >= last30Cutoff {
                modelVotes[entry.model, default: 0] += entry.tokens
                monthUSD += entry.usd
                monthTokens += entry.tokens
            }
            if entryDate >= startOfToday {
                todayUSD += entry.usd
                todayTokens += entry.tokens
            }
            if entry.timestamp >= hourCutoff, entry.timestamp <= now,
               let hour = calendar.date(
                   from: calendar.dateComponents([.year, .month, .day, .hour],
                                                 from: entry.timestamp)) {
                var v = hourBuckets[hour] ?? (0, 0)
                v.usd += entry.usd
                v.tokens += entry.tokens
                hourBuckets[hour] = v
            }
        }

        // Build a contiguous array so the chart x-axis has a bar per day
        // even when there's no activity (renders as a zero-height bar).
        let daily: [ClaudeDailyUsage] = Self.makeDailyBuckets(
            buckets: buckets, endDay: startOfToday, count: historyDays, calendar: calendar)

        // Contiguous 24 hour buckets ending at the current clock hour.
        var hourly: [ClaudeHourlyUsage] = []
        if let currentHour = calendar.date(
            from: calendar.dateComponents([.year, .month, .day, .hour], from: now)) {
            for offset in stride(from: 23, through: 0, by: -1) {
                guard let hour = calendar.date(byAdding: .hour, value: -offset, to: currentHour)
                else { continue }
                let v = hourBuckets[hour] ?? (0, 0)
                hourly.append(ClaudeHourlyUsage(date: hour, usd: v.usd, tokens: v.tokens))
            }
        }

        // Top model = the one with the highest token count.
        let topModel = modelVotes.max { $0.value < $1.value }?.key
        return ClaudeUsageReport(
            todayUSD: todayUSD, todayTokens: todayTokens,
            last30USD: monthUSD, last30Tokens: monthTokens,
            daily: daily, hourly: hourly, topModel: topModel)
    }

    /// One model's running totals within a day.
    private struct ModelAccum { var usd: Double = 0; var tokens: Int = 0 }

    /// In-place accumulator so we don't box a struct on every line.
    private final class DailyAccumulator {
        let date: Date
        var usd: Double = 0
        var tokens: Int = 0
        var models: [String: ModelAccum] = [:]
        init(date: Date) { self.date = date }
    }

    /// Build a contiguous N-day bucket array (newest → oldest) so the chart
    /// has a slot for every day even when no activity was logged.
    private static func makeDailyBuckets(
        buckets: [Date: DailyAccumulator],
        endDay: Date,
        count: Int,
        calendar: Calendar
    ) -> [ClaudeDailyUsage] {
        var result: [ClaudeDailyUsage] = []
        var cursor = endDay
        for _ in 0..<count {
            let entry = buckets[cursor]
            let usd = entry?.usd ?? 0
            let tokens = entry?.tokens ?? 0
            let models: [ClaudeDailyModel] = (entry?.models ?? [:])
                // Drop the noisy "<synthetic>" placeholder and zero-token models
                // so the breakdown only lists real, non-empty usage.
                .filter { $0.key != "<synthetic>" && $0.value.tokens > 0 }
                .map { ClaudeDailyModel(name: $0.key, usd: $0.value.usd, tokens: $0.value.tokens) }
                .sorted { $0.tokens > $1.tokens }
                .prefix(5)
                .map { $0 }
            result.append(ClaudeDailyUsage(date: cursor, usd: usd, tokens: tokens, models: models))
            // Step by calendar day (not -86 400 s) so DST transitions keep
            // the cursor aligned with the startOfDay bucket keys.
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)
                ?? cursor.addingTimeInterval(-86_400)
        }
        return result.reversed()
    }

    private static func estimatedUSD(_ a: FileAggregates, price: ClaudeModelPrice) -> Double {
        let fresh = max(0, a.input - a.cacheRead)
        return (Double(fresh) * price.inputPerM
                + Double(a.cacheCreation) * price.cacheWritePerM
                + Double(a.cacheRead) * price.cacheReadPerM
                + Double(a.output) * price.outputPerM) / 1_000_000
    }

    // MARK: - Per-file aggregation

    /// Per-file cumulative usage + most-recent model seen.
    private struct FileAggregates {
        var input: Int = 0
        var cacheCreation: Int = 0
        var cacheRead: Int = 0
        var output: Int = 0
        var model: String?
        var totalTokens: Int { input + output }
        var isEmpty: Bool { input == 0 && output == 0 }
    }

    /// Walks the jsonl once and emits a per-line accumulator for the chart.
    /// Each entry already has its per-day bucket pre-computed so the caller
    /// can fold straight into a `[Date: DailyAccumulator]`.
    private static func scanFileWithDay(_ url: URL,
                                        cutoff: Date,
                                        calendar: Calendar) -> [DayEntry] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var entries: [DayEntry] = []
        var lines: [String] = []
        content.enumerateLines { line, _ in lines.append(line) }
        for line in lines {
            Self.parseLineIntoDay(line,
                                  calendar: calendar,
                                  into: &entries)
        }
        return entries
    }

    /// Per-line JSON parse + bucket — factored out so Swift's type checker
    /// doesn't have to fold the closure body + the outer for-loop in one
    /// pass (was hitting the "unable to type-check in reasonable time"
    /// diagnostic with everything inline).
    private static func parseLineIntoDay(
        _ line: String,
        calendar: Calendar,
        into entries: inout [DayEntry]
    ) {
        guard let data = line.data(using: .utf8) else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard let message = obj["message"] as? [String: Any] else { return }
        guard let usage = message["usage"] as? [String: Any] else { return }

        let input = usage["input_tokens"] as? Int ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let rawModel = (message["model"] as? String) ?? "claude-sonnet"

        // Skip Vertex AI usage (separately billed): "_vrtx_" id prefix or a
        // model with an "@version" separator. Mirrors CodexBar's filter.
        let messageId = message["id"] as? String
        let requestId = obj["requestId"] as? String
        if messageId?.contains("_vrtx_") == true || requestId?.contains("_vrtx_") == true
            || (rawModel.hasPrefix("claude-") && rawModel.contains("@")) { return }

        // Cost only for recognised Claude models; unknown models (e.g. MiniMax
        // routed via Claude Code) count tokens but cost $0 — matching CodexBar.
        // Anthropic's `input_tokens` is already the fresh (uncached) count, so
        // it is priced directly (no cacheRead subtraction).
        let usdLine: Double
        if let price = ClaudeModelPrice.price(for: rawModel) {
            usdLine = (Double(input) * price.inputPerM
                      + Double(cacheCreation) * price.cacheWritePerM
                      + Double(cacheRead) * price.cacheReadPerM
                      + Double(output) * price.outputPerM) / 1_000_000
        } else {
            usdLine = 0
        }

        // Bucket by the line's actual timestamp so a long-running session
        // spread across multiple days lands tokens on the correct bars.
        let timestampStr = obj["timestamp"] as? String
        let parsedDate = parseISODate(timestampStr) ?? Date()
        let day = calendar.startOfDay(for: parsedDate)
        // Dedup key: the same assistant message logged in multiple files shares
        // messageId + requestId. nil when either is absent (then it's counted
        // individually).
        let key: String? = (messageId != nil && requestId != nil) ? "\(messageId!):\(requestId!)" : nil
        // Total tokens INCLUDE cache (read + creation) — they dominate Claude
        // usage (~99%); excluding them under-counts ~70× and lets a non-Claude
        // model win the "top model" vote. Mirrors CodexBar's token total.
        entries.append(DayEntry(date: day, timestamp: parsedDate, usd: usdLine,
                                tokens: input + cacheCreation + cacheRead + output,
                                model: rawModel, key: key))
    }

    /// One assistant turn worth of per-day accounting. Model is tracked so
    /// the caller can pick the most-used model for the chart subtitle.
    private struct DayEntry {
        let date: Date
        /// Precise line timestamp (the day bucket above discards the time) —
        /// used for the trailing-24 h hourly buckets.
        let timestamp: Date
        let usd: Double
        let tokens: Int
        let model: String
        /// `messageId:requestId` for cross-file dedup; nil when unavailable.
        let key: String?
    }

    /// Legacy file scan (kept for `summary()` callers that don't need
    /// per-day buckets). Walks the file once and returns the highest
    /// cumulative token snapshot — old behaviour matches Codex parity tests.
    private static func scanFile(_ url: URL) -> FileAggregates {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return FileAggregates()
        }
        var agg = FileAggregates()
        content.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            guard let message = obj["message"] as? [String: Any] else { return }
            if let usage = message["usage"] as? [String: Any] {
                agg.input += usage["input_tokens"] as? Int ?? 0
                agg.cacheCreation += usage["cache_creation_input_tokens"] as? Int ?? 0
                agg.cacheRead += usage["cache_read_input_tokens"] as? Int ?? 0
                agg.output += usage["output_tokens"] as? Int ?? 0
            }
            if let model = message["model"] as? String, model != "<synthetic>" {
                agg.model = model
            }
        }
        return agg
    }

    private static func parseISODate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}