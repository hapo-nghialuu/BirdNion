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
        countingRevision: 1,
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
        let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? cutoff
        if file.pathExtension.lowercased() == "jsonl" {
            return LocalCostParsing.jsonLines(url: file).enumerated().compactMap { index, record in
                turn(record: record, session: file.deletingPathExtension().lastPathComponent,
                     ordinal: index, mtime: mtime, cutoff: cutoff)
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
                 mtime: mtime, cutoff: cutoff)
        }
    }

    private static func turn(
        record: [String: Any],
        session: String,
        ordinal: Int,
        mtime: Date,
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
        let total = explicitTotal ?? (input + output + cached + thoughts + tool)
        guard total > 0 else { return nil }
        let date = LocalCostParsing.timestamp(in: record, fallback: mtime)
        guard date >= cutoff else { return nil }
        let model = (record["model"] as? String) ?? (record["model_name"] as? String) ?? "unknown"
        let usd = GeminiModelPrice.cost(
            model: model, input: input, output: output + thoughts + tool, cached: cached)
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

/// Per-million-token USD prices for Gemini models (Google rate card,
/// ≤200k tier). Unknown models still count tokens but cost $0 — same
/// convention as `ClaudeModelPrice`.
struct GeminiModelPrice {
    let inputPerM: Double
    let outputPerM: Double
    let cachedPerM: Double

    static func cost(model: String, input: Int, output: Int, cached: Int) -> Double {
        guard let price = price(for: model) else { return 0 }
        return (Double(input) * price.inputPerM
            + Double(output) * price.outputPerM
            + Double(cached) * price.cachedPerM) / 1_000_000
    }

    static func price(for model: String) -> GeminiModelPrice? {
        let m = model.lowercased()
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
}
