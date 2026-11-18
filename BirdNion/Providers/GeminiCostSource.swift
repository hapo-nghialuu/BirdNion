import Foundation

/// Local cost source: Gemini CLI chat logs under
/// `~/.gemini/tmp/<project>/chats/*.json|*.jsonl` (same files ccusage reads
/// via `GEMINI_DATA_DIR`). Token counts are exact from each record; USD is a
/// per-model price-table estimate (reasoning/tool tokens priced as output,
/// matching ccusage).
enum GeminiCostSource {

    static let descriptor = LocalCostSource(
        source: .gemini,
        displayName: "Gemini CLI",
        countingRevision: 3,
        roots: { GeminiCostSource.dataRoots() },
        turnReader: { roots, cutoff in
            GeminiCostSource.turns(roots: roots, cutoff: cutoff)
        })

    private static func dataRoots() -> [URL] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/tmp")
        return FileManager.default.fileExists(atPath: dir.path) ? [dir] : []
    }

    private static func turns(roots: [URL], cutoff: Date) -> [LocalTurnRecord] {
        roots.flatMap { root in
            LocalCostParsing.files(
                under: root,
                extensions: ["json", "jsonl"],
                parentDir: "chats",
                modifiedSince: cutoff
            ).flatMap { file in
                records(in: file, cutoff: cutoff)
            }
        }
    }

    private static func records(in file: URL, cutoff: Date) -> [LocalTurnRecord] {
        if file.pathExtension.lowercased() == "jsonl" {
            return LocalCostParsing.jsonLines(url: file).enumerated().compactMap { index, record in
                turn(record: record, session: file.deletingPathExtension().lastPathComponent,
                     ordinal: index, cutoff: cutoff)
            }
        }
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        let session = (object["sessionId"] as? String) ?? (object["session_id"] as? String)
            ?? file.deletingPathExtension().lastPathComponent
        let messages = object["messages"] as? [[String: Any]] ?? []
        return messages.enumerated().compactMap { index, message in
            turn(record: message, session: session, ordinal: index,
                 cutoff: cutoff)
        }
    }

    /// `input`/`prompt` already includes the cached tokens, so the total is
    /// not topped up with `cached` and only the non-cached part is priced as
    /// fresh input. Records without a timestamp are dropped.
    static func turn(
        record: [String: Any],
        session: String,
        ordinal: Int,
        cutoff: Date
    ) -> LocalTurnRecord? {
        guard let tokens = LocalCostParsing.dict(record, keys: ["tokens", "usage", "stats", "tokenUsage"])
        else { return nil }
        let input = firstInt(tokens, ["input", "input_tokens", "prompt", "promptTokens"]) ?? 0
        let output = firstInt(tokens, ["output", "output_tokens", "candidates", "candidatesTokens"]) ?? 0
        let cached = firstInt(tokens, ["cached", "cached_tokens", "cachedContent", "cache_read"]) ?? 0
        let thoughts = firstInt(tokens, ["thoughts", "thought", "reasoning"]) ?? 0
        let tool = firstInt(tokens, ["tool", "tool_tokens"]) ?? 0
        let explicitTotal = firstInt(tokens, ["total", "total_tokens", "totalTokens"])
        let total = explicitTotal ?? (input + output + thoughts + tool)
        guard total > 0 else { return nil }
        guard let date = LocalCostParsing.timestamp(in: record), date >= cutoff else { return nil }
        let model = (record["model"] as? String) ?? (record["model_name"] as? String) ?? "unknown"
        let usd = GeminiModelPrice.cost(
            model: model, input: max(0, input - cached), output: output + thoughts + tool, cached: cached,
            date: date)
        return LocalTurnRecord(
            date: date, model: model, tokens: total, usd: usd,
            dedupeKey: "gemini:\(session):\(ordinal):\(model)")
    }

    private static func firstInt(_ dict: [String: Any], _ keys: [String]) -> Int? {
        for key in keys {
            if let value = LocalCostParsing.int(dict[key]) { return value }
        }
        return nil
    }
}

/// Per-million-token USD prices for Gemini models (Google paid-tier rate
/// card). Unknown models still count tokens but cost $0 — same convention as
/// `ClaudeModelPrice`. Several current cards change on a fixed date, so a
/// turn is priced at the card in force on the day it happened.
struct GeminiModelPrice {
    let inputPerM: Double
    let outputPerM: Double
    let cachedPerM: Double

    /// Gemini 4 Carbon/Argon double their card from this day.
    static let gemini4PriceRiseDate = utcDate(year: 2026, month: 12, day: 1)
    /// Gemini 3.6/3.8 Flash double their card from this day.
    static let gemini3FlashPriceRiseDate = utcDate(year: 2027, month: 1, day: 1)

    static func cost(model: String, input: Int, output: Int, cached: Int,
                     date: Date = Date()) -> Double {
        guard let price = price(for: model, on: date, promptTokens: input + cached) else { return 0 }
        return (Double(input) * price.inputPerM
            + Double(output) * price.outputPerM
            + Double(cached) * price.cachedPerM) / 1_000_000
    }

    /// - Parameters:
    ///   - date: when the turn happened; selects the dated card.
    ///   - promptTokens: whole prompt size; Gemini 3.1 Pro bills prompts over
    ///     200K tokens at its long-context card.
    static func price(for model: String, on date: Date = Date(),
                      promptTokens: Int = 0) -> GeminiModelPrice? {
        let m = model.lowercased()
        if m.hasPrefix("gemini-4-carbon") || m.hasPrefix("gemini-4-argon") {
            return date < gemini4PriceRiseDate
                ? GeminiModelPrice(inputPerM: 2.00, outputPerM: 10.00, cachedPerM: 0.10)
                : GeminiModelPrice(inputPerM: 4.00, outputPerM: 20.00, cachedPerM: 0.20)
        }
        if m.hasPrefix("gemini-4-hydrogen") {
            return GeminiModelPrice(inputPerM: 1.50, outputPerM: 7.50, cachedPerM: 0.075)
        }
        if m.hasPrefix("gemini-3.8-flash") || m.hasPrefix("gemini-3.6-flash") {
            return date < gemini3FlashPriceRiseDate
                ? GeminiModelPrice(inputPerM: 0.75, outputPerM: 3.75, cachedPerM: 0.075)
                : GeminiModelPrice(inputPerM: 1.50, outputPerM: 7.50, cachedPerM: 0.15)
        }
        if m.hasPrefix("gemini-3.5-flash-lite") {
            return GeminiModelPrice(inputPerM: 0.30, outputPerM: 2.50, cachedPerM: 0.03)
        }
        if m.hasPrefix("gemini-3.1-flash-lite") {
            return GeminiModelPrice(inputPerM: 0.25, outputPerM: 1.50, cachedPerM: 0.025)
        }
        if m.hasPrefix("gemini-3.1-pro") {
            return promptTokens > 200_000
                ? GeminiModelPrice(inputPerM: 4.00, outputPerM: 18.00, cachedPerM: 0.40)
                : GeminiModelPrice(inputPerM: 2.00, outputPerM: 12.00, cachedPerM: 0.20)
        }
        if m.hasPrefix("gemini-3-flash") {
            return GeminiModelPrice(inputPerM: 0.50, outputPerM: 3.00, cachedPerM: 0.05)
        }
        if m.hasPrefix("gemini-2.5-flash-lite") || m.hasPrefix("gemini-flash-lite") {
            return GeminiModelPrice(inputPerM: 0.10, outputPerM: 0.40, cachedPerM: 0.025)
        }
        if m.hasPrefix("gemini-2.5-flash") || m.hasPrefix("gemini-flash-") {
            return GeminiModelPrice(inputPerM: 0.30, outputPerM: 2.50, cachedPerM: 0.075)
        }
        if m.hasPrefix("gemini-3") {
            return GeminiModelPrice(inputPerM: 2.00, outputPerM: 12.00, cachedPerM: 0.20)
        }
        if m.hasPrefix("gemini-2.5-pro") || m.hasPrefix("gemini-pro") || m.hasPrefix("gemini-2.0-pro") {
            return GeminiModelPrice(inputPerM: 1.25, outputPerM: 10.00, cachedPerM: 0.31)
        }
        if m.hasPrefix("gemini-2.0-flash") {
            return GeminiModelPrice(inputPerM: 0.10, outputPerM: 0.40, cachedPerM: 0.025)
        }
        if m.hasPrefix("gemini-1.5-pro") {
            return GeminiModelPrice(inputPerM: 1.25, outputPerM: 5.00, cachedPerM: 0.31)
        }
        if m.hasPrefix("gemini-1.5-flash") {
            return GeminiModelPrice(inputPerM: 0.075, outputPerM: 0.30, cachedPerM: 0.02)
        }
        return nil
    }

    private static func utcDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantFuture
    }
}
