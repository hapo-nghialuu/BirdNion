import Foundation

/// Token cost rolled up from the local Codex session rollouts.
///
/// Token counts are exact (read straight from `~/.codex/sessions/**/rollout-*.jsonl`).
/// The dollar amount is an estimate: tokens × a per-model price table, so it is
/// surfaced as "≈" in the UI.
struct CodexCostSummary: Equatable {
    let todayUSD: Double
    let todayTokens: Int
    let last30USD: Double
    let last30Tokens: Int

    var isEmpty: Bool { todayTokens == 0 && last30Tokens == 0 }
}

/// Per-million-token prices (USD). `cachedInput` applies to the cached portion of
/// the input, billed cheaper than fresh input.
struct CodexModelPrice {
    let inputPerM: Double
    let cachedInputPerM: Double
    let outputPerM: Double

    /// Best-effort table for the models Codex commonly reports. Unknown models
    /// fall back to `default`. Update as OpenAI pricing changes.
    static func price(for model: String) -> CodexModelPrice {
        let m = model.lowercased()
        if m.contains("mini") { return CodexModelPrice(inputPerM: 0.25, cachedInputPerM: 0.025, outputPerM: 2.0) }
        if m.contains("nano") { return CodexModelPrice(inputPerM: 0.05, cachedInputPerM: 0.005, outputPerM: 0.40) }
        if m.hasPrefix("gpt-5") || m.contains("codex") {
            return CodexModelPrice(inputPerM: 1.25, cachedInputPerM: 0.125, outputPerM: 10.0)
        }
        return CodexModelPrice(inputPerM: 1.25, cachedInputPerM: 0.125, outputPerM: 10.0)
    }
}

/// Final cumulative token usage for one session.
private struct SessionUsage {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    var totalTokens: Int { inputTokens + outputTokens }
}

/// Scans the local Codex session rollouts and sums token cost for today and the
/// trailing 30 days. Pure file I/O, no network. Results are cached briefly.
enum CodexCostScanner {
    private static let cacheTTL: TimeInterval = 300

    /// Actor-isolated cache so the brief memoization is safe across tasks.
    private actor Cache {
        static let shared = Cache()
        private var entry: (at: Date, value: CodexCostSummary)?
        func valid(now: Date, ttl: TimeInterval) -> CodexCostSummary? {
            guard let entry, now.timeIntervalSince(entry.at) < ttl else { return nil }
            return entry.value
        }
        func store(_ value: CodexCostSummary, at: Date) { entry = (at, value) }
    }

    static func defaultSessionsDir() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    }

    /// Cached, off-main scan. Returns nil only if the sessions dir is unreadable.
    static func summary(sessionsDir: URL = defaultSessionsDir(), now: Date = Date()) async -> CodexCostSummary? {
        if let cached = await Cache.shared.valid(now: now, ttl: cacheTTL) { return cached }
        let value = await Task.detached(priority: .utility) { scan(sessionsDir: sessionsDir, now: now) }.value
        if let value { await Cache.shared.store(value, at: now) }
        return value
    }

    // MARK: - Scanning

    static func scan(sessionsDir: URL, now: Date) -> CodexCostSummary? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return nil }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let cutoff = now.addingTimeInterval(-30 * 86_400)

        var todayUSD = 0.0, todayTokens = 0
        var monthUSD = 0.0, monthTokens = 0

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-"),
                  let date = sessionDate(from: url.lastPathComponent),
                  date >= cutoff else { continue }
            guard let usage = lastUsage(in: url) else { continue }

            let price = CodexModelPrice.price(for: model(in: url) ?? "")
            let usd = estimatedUSD(usage, price: price)
            let tokens = usage.totalTokens

            monthUSD += usd
            monthTokens += tokens
            if date >= startOfToday {
                todayUSD += usd
                todayTokens += tokens
            }
        }
        return CodexCostSummary(todayUSD: todayUSD, todayTokens: todayTokens,
                                last30USD: monthUSD, last30Tokens: monthTokens)
    }

    private static func estimatedUSD(_ u: SessionUsage, price: CodexModelPrice) -> Double {
        let freshInput = max(0, u.inputTokens - u.cachedInputTokens)
        return (Double(freshInput) * price.inputPerM
                + Double(u.cachedInputTokens) * price.cachedInputPerM
                + Double(u.outputTokens) * price.outputPerM) / 1_000_000
    }

    /// Parse the session start date from "rollout-2026-06-23T15-57-40-...".
    static func sessionDate(from filename: String) -> Date? {
        // Strip the "rollout-" prefix and take the timestamp up to the UUID.
        let body = filename.dropFirst("rollout-".count)
        let stamp = String(body.prefix(19)) // 2026-06-23T15-57-40
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter.date(from: stamp)
    }

    /// The last cumulative `total_token_usage` in the file (its running total).
    /// Reads only matching lines to avoid parsing every chat message.
    private static func lastUsage(in url: URL) -> SessionUsage? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var result: SessionUsage?
        content.enumerateLines { line, _ in
            guard line.contains("total_token_usage"),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let usage = extractTotalUsage(obj) else { return }
            result = usage
        }
        return result
    }

    private static func extractTotalUsage(_ obj: [String: Any]) -> SessionUsage? {
        guard let payload = obj["payload"] as? [String: Any],
              let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any] else { return nil }
        let input = total["input_tokens"] as? Int ?? 0
        let cached = total["cached_input_tokens"] as? Int ?? 0
        let output = total["output_tokens"] as? Int ?? 0
        guard input > 0 || output > 0 else { return nil }
        return SessionUsage(inputTokens: input, cachedInputTokens: cached, outputTokens: output)
    }

    /// First model name seen in the file (sessions are single-model in practice).
    private static func model(in url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var found: String?
        content.enumerateLines { line, stop in
            guard line.contains("\"model\""),
                  let range = line.range(of: #""model"\s*:\s*"([^"]+)""#, options: .regularExpression) else { return }
            let segment = line[range]
            if let q = segment.range(of: #""([^"]+)"$"#, options: .regularExpression) {
                found = String(segment[q]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                stop = true
            }
        }
        return found
    }
}
