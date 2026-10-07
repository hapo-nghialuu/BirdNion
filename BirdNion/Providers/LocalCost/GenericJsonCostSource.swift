import Foundation

/// Shared USD estimate across the extra local sources: Claude-family models
/// price through `ClaudeModelPrice`, Gemini-family through
/// `GeminiModelPrice`, everything else counts tokens at $0.
enum LocalCostPricing {
    static func estimate(
        model: String, input: Int, cacheRead: Int, cacheWrite: Int, output: Int
    ) -> Double {
        let m = model.lowercased()
        if m.contains("claude"), let price = ClaudeModelPrice.price(for: m) {
            return (Double(input + cacheWrite) * price.inputPerM
                + Double(cacheRead) * price.cacheReadPerM
                + Double(output) * price.outputPerM) / 1_000_000
        }
        if m.contains("gemini"), let price = GeminiModelPrice.price(for: m) {
            return (Double(input + cacheWrite) * price.inputPerM
                + Double(cacheRead) * price.cachedPerM
                + Double(output) * price.outputPerM) / 1_000_000
        }
        return 0
    }
}

/// Token split extracted from one usage record.
struct LocalUsageTokens: Sendable {
    var input = 0
    var cacheRead = 0
    var cacheWrite = 0
    var output = 0
    var explicitTotal: Int?

    var total: Int {
        explicitTotal ?? (input + cacheRead + cacheWrite + output)
    }
}

/// Declarative spec for JSON/JSONL log formats whose usage records are
/// nested dicts of token counters (Amp threads, Droid settings, Kimi wire,
/// Qwen chats, Cursor bubbles). The walker finds any dict under
/// `usageContainerKeys`, classifies its numeric leaves into
/// input/cache/output buckets, and lifts model + timestamp hints from the
/// enclosing record (deep-first match).
struct JsonLogSourceSpec: Sendable {
    /// Dict keys whose object value is a usage record.
    let usageContainerKeys: [String]
    /// Extra keys inside a usage dict that already are the final total.
    let explicitTotalKeys: [String]
    /// Keys carrying the model name; deep search, first hit wins.
    let modelKeys: [String]
    /// Keys carrying a timestamp; deep search, first hit wins.
    let timestampKeys: [String]

    static let `default` = JsonLogSourceSpec(
        usageContainerKeys: ["usage", "usageMetadata", "token_usage", "tokenUsage",
                             "sessionUsage", "token_usage_details"],
        explicitTotalKeys: ["total", "totalTokens", "totalTokenCount", "total_tokens"],
        modelKeys: ["model", "modelName", "model_name", "modelID", "modelId"],
        timestampKeys: ["timestamp", "time", "created", "createdAt", "created_at",
                        "updatedAt", "lastUpdated", "ts"])
}

enum GenericJsonCostSource {

    /// Turns extracted from one parsed JSON object (a whole file, one JSONL
    /// line, or one DB value). `fallbackDate` applies when no timestamp hint
    /// is found; `cutoff` drops older turns.
    static func turns(
        in object: Any,
        spec: JsonLogSourceSpec = .default,
        fallbackDate: Date,
        cutoff: Date,
        dedupePrefix: String
    ) -> [LocalTurnRecord] {
        var out: [LocalTurnRecord] = []
        var ordinal = 0
        collectUsageRecords(object, spec: spec) { usageDict, context in
            defer { ordinal += 1 }
            let tokens = splitTokens(usageDict, spec: spec)
            guard tokens.total > 0 else { return }
            let date = deepFirst(context, keys: spec.timestampKeys, as: LocalCostParsing.parseTimestamp)
                ?? fallbackDate
            guard date >= cutoff else { return }
            let model = deepFirst(context, keys: spec.modelKeys) { $0 as? String } ?? "unknown"
            out.append(LocalTurnRecord(
                date: date, model: model, tokens: tokens.total,
                usd: LocalCostPricing.estimate(
                    model: model, input: tokens.input, cacheRead: tokens.cacheRead,
                    cacheWrite: tokens.cacheWrite, output: tokens.output),
                dedupeKey: "\(dedupePrefix):\(ordinal)"))
        }
        return out
    }

    /// Reads turns from every matching file under `roots`.
    static func turns(
        roots: [URL],
        extensions: Set<String>,
        fileFilter: ((URL) -> Bool)? = nil,
        spec: JsonLogSourceSpec = .default,
        cutoff: Date,
        dedupePrefix: String
    ) -> [LocalTurnRecord] {
        roots.flatMap { root -> [LocalTurnRecord] in
            LocalCostParsing.files(
                under: root, extensions: extensions, modifiedSince: cutoff
            ).flatMap { file -> [LocalTurnRecord] in
                if let fileFilter, !fileFilter(file) { return [] }
                let mtime = (try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? cutoff
                let prefix = "\(dedupePrefix):\(file.path)"
                if file.pathExtension.lowercased() == "jsonl" {
                    return LocalCostParsing.jsonLines(url: file).enumerated().flatMap { index, line in
                        turns(in: line, spec: spec, fallbackDate: mtime, cutoff: cutoff,
                              dedupePrefix: "\(prefix):\(index)")
                    }
                }
                guard let data = try? Data(contentsOf: file),
                      let object = try? JSONSerialization.jsonObject(with: data)
                else { return [] }
                return turns(in: object, spec: spec, fallbackDate: mtime, cutoff: cutoff,
                             dedupePrefix: prefix)
            }
        }
    }

    // MARK: - Walker

    /// Visits every dict stored under a usage-container key, with the
    /// enclosing record as context for model/timestamp hints.
    private static func collectUsageRecords(
        _ object: Any,
        spec: JsonLogSourceSpec,
        context: [String: Any]? = nil,
        visit: ([String: Any], [String: Any]) -> Void
    ) {
        switch object {
        case let dict as [String: Any]:
            var emitted = false
            for key in spec.usageContainerKeys {
                if let usage = dict[key] as? [String: Any], !usage.isEmpty {
                    visit(usage, context ?? dict)
                    emitted = true
                }
            }
            guard !emitted else { return }
            for (key, value) in dict where !spec.usageContainerKeys.contains(key) {
                collectUsageRecords(value, spec: spec, context: dict, visit: visit)
            }
        case let array as [Any]:
            for element in array {
                collectUsageRecords(element, spec: spec, context: context, visit: visit)
            }
        default:
            break
        }
    }

    /// Classifies numeric leaves of a usage dict: cache-creation/write,
    /// cache-read, input/prompt side, output/reasoning side. Unclassifiable
    /// counters count as output-priced usage.
    static func splitTokens(_ usage: [String: Any], spec: JsonLogSourceSpec) -> LocalUsageTokens {
        var tokens = LocalUsageTokens()
        for (key, value) in usage {
            if let total = LocalCostParsing.int(value), spec.explicitTotalKeys.contains(key) {
                tokens.explicitTotal = total
                continue
            }
            guard let count = LocalCostParsing.int(value) else {
                // Nested usage objects (rare) still contribute their leaves.
                if let nested = value as? [String: Any] {
                    let inner = splitTokens(nested, spec: spec)
                    tokens.input += inner.input
                    tokens.cacheRead += inner.cacheRead
                    tokens.cacheWrite += inner.cacheWrite
                    tokens.output += inner.output
                }
                continue
            }
            let k = key.lowercased()
            if k.contains("cache") && (k.contains("creation") || k.contains("write")) {
                tokens.cacheWrite += count
            } else if k.contains("cache") || k.contains("cached") {
                tokens.cacheRead += count
            } else if k.contains("input") || k.contains("prompt") {
                tokens.input += count
            } else {
                // output/candidates/completion/reasoning/thoughts/thinking
                // and unclassifiable counters.
                tokens.output += count
            }
        }
        return tokens
    }

    /// Depth-first search of `keys` inside an arbitrary JSON object,
    /// returning the first value `extract` accepts.
    static func deepFirst<T>(
        _ object: Any, keys: [String], as extract: (Any) -> T?
    ) -> T? {
        switch object {
        case let dict as [String: Any]:
            for key in keys {
                if let value = dict[key], let result = extract(value) { return result }
            }
            for value in dict.values {
                if let result = deepFirst(value, keys: keys, as: extract) { return result }
            }
            return nil
        case let array as [Any]:
            for element in array {
                if let result = deepFirst(element, keys: keys, as: extract) { return result }
            }
            return nil
        default:
            return nil
        }
    }
}
