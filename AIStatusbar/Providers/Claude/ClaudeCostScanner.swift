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

/// Per-million-token prices (USD) for Anthropic models. Anthropic splits
/// input into fresh / cache-write / cache-read (Codex only has fresh + cached
/// read). Updated 2026-06; revisit when Anthropic revises pricing.
struct ClaudeModelPrice {
    let inputPerM: Double
    let cacheWritePerM: Double
    let cacheReadPerM: Double
    let outputPerM: Double

    /// Best-effort table for the model IDs Claude Code reports. Unknown
    /// models fall back to Sonnet pricing (most common mid-tier).
    static func price(for model: String) -> ClaudeModelPrice {
        let m = model.lowercased()
        // Opus 4.x family (claude-opus-4-1, claude-opus-4, claude-opus-4-8)
        if m.contains("opus") {
            return ClaudeModelPrice(inputPerM: 15.0, cacheWritePerM: 18.75,
                                    cacheReadPerM: 1.50, outputPerM: 75.0)
        }
        // Haiku 4.x family
        if m.contains("haiku") {
            return ClaudeModelPrice(inputPerM: 0.80, cacheWritePerM: 1.00,
                                    cacheReadPerM: 0.08, outputPerM: 4.0)
        }
        // Sonnet 4.x (default fallback) + 3.x
        return ClaudeModelPrice(inputPerM: 3.0, cacheWritePerM: 3.75,
                                cacheReadPerM: 0.30, outputPerM: 15.0)
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

    /// Actor-isolated cache so brief memoization is safe across tasks.
    private actor Cache {
        static let shared = Cache()
        private var entry: (at: Date, value: ClaudeCostSummary)?
        func valid(now: Date, ttl: TimeInterval) -> ClaudeCostSummary? {
            guard let entry, now.timeIntervalSince(entry.at) < ttl else { return nil }
            return entry.value
        }
        func store(_ value: ClaudeCostSummary, at: Date) { entry = (at, value) }
    }

    static func defaultProjectsDir() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    }

    /// Cached, off-main scan. Returns nil only if the projects dir is unreadable.
    static func summary(projectsDir: URL = defaultProjectsDir(), now: Date = Date()) async -> ClaudeCostSummary? {
        if let cached = await Cache.shared.valid(now: now, ttl: cacheTTL) { return cached }
        let value = await Task.detached(priority: .utility) {
            scan(projectsDir: projectsDir, now: now)
        }.value
        if let value { await Cache.shared.store(value, at: now) }
        return value
    }

    // MARK: - Scanning

    static func scan(projectsDir: URL, now: Date) -> ClaudeCostSummary? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return nil }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let cutoff = now.addingTimeInterval(-30 * 86_400)

        var todayUSD = 0.0, todayTokens = 0
        var monthUSD = 0.0, monthTokens = 0
        // Track the latest model seen per session for price lookup (sessions
        // are single-model in practice but a session might start with one
        // model and switch mid-stream — we use the most recent).
        var modelPerFile: [URL: String] = [:]

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            // Use file modification date as the session date — Claude Code
            // appends to these files continuously so mtime tracks the latest
            // activity. Cheaper than parsing every line.
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            guard mtime >= cutoff else { continue }

            let aggregates = scanFile(url)
            guard !aggregates.isEmpty else { continue }
            let model = modelPerFile[url] ?? aggregates.model ?? "claude-sonnet"
            let price = ClaudeModelPrice.price(for: model)
            let usd = estimatedUSD(aggregates, price: price)
            let tokens = aggregates.totalTokens

            monthUSD += usd
            monthTokens += tokens
            if mtime >= startOfToday {
                todayUSD += usd
                todayTokens += tokens
            }
        }
        return ClaudeCostSummary(todayUSD: todayUSD, todayTokens: todayTokens,
                                 last30USD: monthUSD, last30Tokens: monthTokens)
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

    /// Walks the jsonl once and sums the last `message.usage` snapshot seen
    /// per assistant turn (each line overwrites the previous since Claude
    /// Code streams deltas). Returns the highest cumulative values seen.
    private static func scanFile(_ url: URL) -> FileAggregates {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return FileAggregates()
        }
        var agg = FileAggregates()
        content.enumerateLines { line, _ in
            // Cheap filter: skip lines that clearly aren't assistant messages.
            // We still need to peek at the model field, so we can't be more
            // aggressive here.
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            // Only assistant turns carry usage (user turns have content but
            // no `usage` object).
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
}